import CryptoKit
import Foundation

/// A value whose absence is explicit. Cold facts must never turn missing raw
/// evidence into an empty or zero measurement.
struct AtriaColdSessionAvailability<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case available
        case knownEmpty
        case missing
        case unsupported
    }

    let state: State
    let value: Value?
    let reason: String?

    static func available(_ value: Value) -> Self {
        .init(state: .available, value: value, reason: nil)
    }

    static func knownEmpty(_ reason: String) -> Self {
        .init(state: .knownEmpty, value: nil, reason: reason)
    }

    static func missing(_ reason: String) -> Self {
        .init(state: .missing, value: nil, reason: reason)
    }

    static func unsupported(_ reason: String) -> Self {
        .init(state: .unsupported, value: nil, reason: reason)
    }

    var isWellFormed: Bool {
        switch state {
        case .available:
            return value != nil && reason == nil
        case .knownEmpty, .missing, .unsupported:
            return value == nil && !(reason?.isEmpty ?? true)
        }
    }
}

enum AtriaColdSessionRetentionPolicy {
    static let hotFullFidelityDays = 30
    static let decodedColdFullFidelityDays = 90

    enum Tier: String, Codable, Equatable, Sendable {
        case hotFullFidelity
        case decodedColdFullFidelity
        case compactFacts
    }

    static func tier(ageDays: Double) -> Tier {
        if ageDays <= Double(hotFullFidelityDays) { return .hotFullFidelity }
        if ageDays <= Double(decodedColdFullFidelityDays) { return .decodedColdFullFidelity }
        return .compactFacts
    }

    static func compactCutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(decodedColdFullFidelityDays) * 86_400)
    }
}

/// Immutable, raw-independent facts for one SavedSession older than 90 days.
/// The model intentionally has no API that reconstructs SavedSession.Point or
/// RRPoint values. Timeline readers return aggregate buckets with provenance.
struct AtriaColdSessionFact: Codable, Equatable, Sendable {
    static let currentSchema = 1

    struct Source: Codable, Equatable, Sendable {
        let sessionID: UUID
        let canonicalSHA256: String
        let canonicalByteCount: Int
        let start: Date
        let end: Date
    }

    struct Timeline: Codable, Equatable, Sendable {
        let label: String
        let kind: String?
        let eventTimeZoneIdentifier: String?
        let durationSeconds: Double
        let biologicalSex: String?
        let excludedIntervalCount: Int
    }

    /// One absolute minute. Sample distribution supports honest historical
    /// charts and percentiles. Interval distributions preserve the exact load
    /// inputs used by zones, TRIMP, Edwards load, and calorie integration.
    struct HeartRateMinute: Codable, Equatable, Sendable {
        let minuteStart: Date
        let sampleCount: Int
        let sumBPM: Int64
        let minimumBPM: Int?
        let maximumBPM: Int?
        let samplesByBPM: [Int: Int]
        /// Seconds attributed to the later sample's BPM, matching zone/calorie
        /// integration. Intervals are split at minute boundaries.
        let terminalBPMSeconds: [Int: Double]
        /// Key = previous BPM + current BPM (twice trapezoidal mean BPM).
        let transitionHalfBPMSeconds: [Int: Double]
        let coveredLoadSeconds: Double
        let droppedGapSeconds: Double
    }

    struct HeartRateFacts: Codable, Equatable, Sendable {
        let sampleCount: Int
        let sumBPM: Int64
        let minimumBPM: Int
        let maximumBPM: Int
        let restingStableP10: Int
        let sleepCandidateRestingP05: Int
        let loadEligible: Bool
        let loadExclusionReason: String?
        let minutes: [HeartRateMinute]

        func maxHeartRateZoneSeconds(maxHR: Int,
                                     within interval: DateInterval? = nil)
            -> AtriaColdSessionAvailability<[String: Double]> {
            guard Self.supports(interval) else {
                return .unsupported("compact load facts require minute-aligned interval boundaries")
            }
            guard maxHR > 0 else { return .unsupported("maximum heart rate must be positive") }
            guard loadEligible else {
                return .knownEmpty("session is excluded from cardiovascular load")
            }
            var result: [String: Double] = [:]
            for minute in minutes where Self.includes(minute.minuteStart, in: interval) {
                for (bpm, seconds) in minute.terminalBPMSeconds where seconds > 0 {
                    let raw = AtriaAnalytics.Strain.maxHeartRateZoneRawValue(for: bpm, maxHR: maxHR)
                    let name = ["rest", "warmup", "fatBurn", "aerobic", "anaerobic", "max"][raw]
                    result[name, default: 0] += seconds
                }
            }
            return .available(result)
        }

        func trimp(rest: Int,
                   maxHR: Int,
                   biologicalSex: AthleteProfile.BiologicalSex,
                   within interval: DateInterval? = nil) -> AtriaColdSessionAvailability<Double> {
            guard Self.supports(interval) else {
                return .unsupported("compact load facts require minute-aligned interval boundaries")
            }
            guard maxHR > rest else {
                return .unsupported("maximum heart rate must exceed resting heart rate")
            }
            guard loadEligible else {
                return .knownEmpty("session is excluded from cardiovascular load")
            }
            let span = Double(maxHR - rest)
            let coefficient = AtriaAnalytics.Strain.banisterCoefficient(for: biologicalSex)
            var total = 0.0
            for minute in minutes where Self.includes(minute.minuteStart, in: interval) {
                for (twiceMeanBPM, seconds) in minute.transitionHalfBPMSeconds where seconds > 0 {
                    let meanBPM = Double(twiceMeanBPM) / 2
                    let reserve = min(max((meanBPM - Double(rest)) / span, 0), 1)
                    total += seconds / 60 * reserve * 0.64 * exp(coefficient * reserve)
                }
            }
            return .available(total)
        }

        func activeCalories(rest: Int,
                            profile: AthleteProfile,
                            within interval: DateInterval? = nil) -> AtriaColdSessionAvailability<Double> {
            guard Self.supports(interval) else {
                return .unsupported("compact load facts require minute-aligned interval boundaries")
            }
            guard loadEligible else {
                return .knownEmpty("session is excluded from cardiovascular load")
            }
            guard rest > 0, profile.hasEnergyProfile else {
                return .unsupported("athlete age, weight, and biological sex are required")
            }
            let resting = Self.energyKcalPerMinute(heartRate: rest, profile: profile)
            var total = 0.0
            for minute in minutes where Self.includes(minute.minuteStart, in: interval) {
                for (bpm, seconds) in minute.terminalBPMSeconds where seconds > 0 {
                    let gross = Self.energyKcalPerMinute(heartRate: bpm, profile: profile)
                    total += max(0, gross - resting) * seconds / 60
                }
            }
            return .available(total)
        }

        private static func includes(_ minuteStart: Date, in interval: DateInterval?) -> Bool {
            guard let interval else { return true }
            return minuteStart >= interval.start && minuteStart < interval.end
        }

        private static func supports(_ interval: DateInterval?) -> Bool {
            guard let interval else { return true }
            guard interval.end > interval.start else { return false }
            func isMinuteAligned(_ date: Date) -> Bool {
                let remainder = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
                return abs(remainder) < 0.000_001 || abs(abs(remainder) - 60) < 0.000_001
            }
            return isMinuteAligned(interval.start) && isMinuteAligned(interval.end)
        }

        private static func energyKcalPerMinute(heartRate: Int, profile: AthleteProfile) -> Double {
            let hr = Double(heartRate)
            let weight = profile.weightKg
            let age = Double(profile.age)
            switch profile.biologicalSex {
            case .male:
                return max(0, (-55.0969 + 0.6309 * hr + 0.1988 * weight + 0.2017 * age) / 4.184)
            case .female:
                return max(0, (-20.4022 + 0.4472 * hr - 0.1263 * weight + 0.0740 * age) / 4.184)
            case .unspecified:
                return 0
            }
        }
    }

    struct RREpoch: Codable, Equatable, Sendable {
        let epochStart: Date
        let epochEnd: Date
        let recordCount: Int
        let acceptedBeatCount: Int
        let rejectedBeatCount: Int
        let sumNNMilliseconds: Int64
        let sumNNSquaredMilliseconds: Double
        let adjacentDifferenceCount: Int
        let sumAdjacentDifferenceSquaredMilliseconds: Double
        let adjacentDifferenceOver50Count: Int
        let firstNNMilliseconds: Int?
        let lastNNMilliseconds: Int?
        let maximumGapSeconds: Double
    }

    struct RRFacts: Codable, Equatable, Sendable {
        let recordCount: Int
        let sourceCounts: [String: Int]
        let persistedRMSSD: AtriaColdSessionAvailability<Int>
        let persistedSDNN: AtriaColdSessionAvailability<Double>
        let persistedRespiratoryRate: AtriaColdSessionAvailability<Double>
        let referenceValidated: Bool
        let epochs: [RREpoch]
    }

    struct MotionFacts: Codable, Equatable, Sendable {
        let evidenceSource: String
        let evidenceValidated: Bool
        let hintCount: Int
        let hintKinds: String?
        let recoveredEpochCount: Int
        let imuSampleCount: Int?
        let imuFrameCount: Int?
        let stillnessRatio: Double?
        let movementIntensity: Double?
        let activityBursts: Int?
        let validationState: String?
    }

    struct StepFacts: Codable, Equatable, Sendable {
        let count: Int
        let agreement: Double?
        let state: String?
    }

    struct Reference: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Equatable, Sendable {
            case sleep
            case workout
            case activity
        }

        let kind: Kind
        let identifier: String
        let start: Date
        let end: Date
        let label: String?
        let source: String
    }

    struct ReferenceFacts: Codable, Equatable, Sendable {
        let sleeps: AtriaColdSessionAvailability<[Reference]>
        let workouts: AtriaColdSessionAvailability<[Reference]>
        let activities: AtriaColdSessionAvailability<[Reference]>
    }

    let schema: Int
    let createdAt: Date
    let source: Source
    let timeline: Timeline
    let heartRate: AtriaColdSessionAvailability<HeartRateFacts>
    let rr: AtriaColdSessionAvailability<RRFacts>
    let motion: AtriaColdSessionAvailability<MotionFacts>
    let steps: AtriaColdSessionAvailability<StepFacts>
    let references: ReferenceFacts
    let persistedActiveCalories: AtriaColdSessionAvailability<Double>
    let persistedCaloriesConfidence: AtriaColdSessionAvailability<String>

    enum ValidationError: Error, Equatable {
        case unsupportedSchema
        case invalidSource
        case malformedAvailability
        case invalidHeartRateFacts
        case invalidRRFacts
        case invalidReference
    }

    func validate() throws {
        guard schema == Self.currentSchema else { throw ValidationError.unsupportedSchema }
        guard source.end >= source.start,
              source.canonicalByteCount > 0,
              Self.isSHA256(source.canonicalSHA256) else { throw ValidationError.invalidSource }
        let availabilityValid = heartRate.isWellFormed && rr.isWellFormed && motion.isWellFormed
            && steps.isWellFormed && persistedActiveCalories.isWellFormed
            && persistedCaloriesConfidence.isWellFormed && references.sleeps.isWellFormed
            && references.workouts.isWellFormed && references.activities.isWellFormed
        guard availabilityValid else { throw ValidationError.malformedAvailability }
        if let facts = heartRate.value {
            guard facts.sampleCount > 0,
                  facts.sumBPM > 0,
                  facts.minimumBPM > 0,
                  facts.maximumBPM >= facts.minimumBPM,
                  facts.minutes.reduce(0, { $0 + $1.sampleCount }) == facts.sampleCount,
                  facts.minutes.reduce(Int64(0), { $0 + $1.sumBPM }) == facts.sumBPM,
                  facts.minutes.allSatisfy({ minute in
                      minute.sampleCount >= 0 && minute.sumBPM >= 0
                          && minute.coveredLoadSeconds >= 0 && minute.droppedGapSeconds >= 0
                  }) else { throw ValidationError.invalidHeartRateFacts }
        }
        if let facts = rr.value {
            guard facts.recordCount >= 0,
                  facts.epochs.reduce(0, { $0 + $1.recordCount }) == facts.recordCount,
                  facts.epochs.allSatisfy({ epoch in
                      epoch.epochEnd > epoch.epochStart && epoch.recordCount >= 0
                          && epoch.acceptedBeatCount >= 0 && epoch.rejectedBeatCount >= 0
                          && epoch.acceptedBeatCount + epoch.rejectedBeatCount == epoch.recordCount
                  }) else { throw ValidationError.invalidRRFacts }
        }
        let allReferences = (references.sleeps.value ?? [])
            + (references.workouts.value ?? []) + (references.activities.value ?? [])
        guard allReferences.allSatisfy({ !$0.identifier.isEmpty && $0.end > $0.start }) else {
            throw ValidationError.invalidReference
        }
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy(
            CharacterSet(charactersIn: "0123456789abcdef").contains
        )
    }
}

struct AtriaColdSessionFactBuilder {
    struct Context: @unchecked Sendable {
        let confirmedSleeps: [UserConfirmedSleep]
        let confirmedWorkouts: [UserConfirmedWorkout]
        let activityReferences: AtriaColdSessionAvailability<[AtriaColdSessionFact.Reference]>

        init(confirmedSleeps: [UserConfirmedSleep] = [],
             confirmedWorkouts: [UserConfirmedWorkout] = [],
             activityReferences: AtriaColdSessionAvailability<[AtriaColdSessionFact.Reference]> =
                .unsupported("durable activity-to-session identities are not available yet")) {
            self.confirmedSleeps = confirmedSleeps
            self.confirmedWorkouts = confirmedWorkouts
            self.activityReferences = activityReferences
        }
    }

    private struct HRMinuteAccumulator {
        var sampleCount = 0
        var sumBPM: Int64 = 0
        var minimumBPM: Int?
        var maximumBPM: Int?
        var samplesByBPM: [Int: Int] = [:]
        var terminalBPMSeconds: [Int: Double] = [:]
        var transitionHalfBPMSeconds: [Int: Double] = [:]
        var coveredLoadSeconds = 0.0
        var droppedGapSeconds = 0.0
    }

    private struct RREpochAccumulator {
        var recordCount = 0
        var accepted: [(date: Date, ms: Int)] = []
    }

    static func build(session: SavedSession,
                      context: Context = .init(),
                      createdAt: Date = Date()) throws -> AtriaColdSessionFact {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonical = try encoder.encode(session)
        let source = AtriaColdSessionFact.Source(
            sessionID: session.id,
            canonicalSHA256: sha256(canonical),
            canonicalByteCount: canonical.count,
            start: session.start,
            end: session.end
        )
        let heartRate = makeHeartRate(session)
        let rr = makeRR(session)
        let motion = makeMotion(session)
        let steps: AtriaColdSessionAvailability<AtriaColdSessionFact.StepFacts>
        if let count = session.strapStepResearchCount {
            steps = .available(.init(count: max(0, count),
                                     agreement: session.strapStepResearchAgreement,
                                     state: session.strapStepResearchState))
        } else {
            steps = .missing("session predates or lacks decoded strap-step evidence")
        }
        let fact = AtriaColdSessionFact(
            schema: AtriaColdSessionFact.currentSchema,
            createdAt: createdAt,
            source: source,
            timeline: .init(label: session.label,
                            kind: session.kind,
                            eventTimeZoneIdentifier: session.eventTimeZoneIdentifier,
                            durationSeconds: max(0, session.duration),
                            biologicalSex: session.biologicalSex?.rawValue,
                            excludedIntervalCount: session.excludedIntervals?.count ?? 0),
            heartRate: heartRate,
            rr: rr,
            motion: motion,
            steps: steps,
            references: makeReferences(session, context: context),
            persistedActiveCalories: optionalValue(session.activeCalories,
                                                   missing: "active calories were not persisted"),
            persistedCaloriesConfidence: optionalValue(session.caloriesConfidence,
                                                        missing: "calorie confidence was not persisted")
        )
        try fact.validate()
        return fact
    }

    static func canonicalDigest(of session: SavedSession) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return sha256(try encoder.encode(session))
    }

    private static func makeHeartRate(_ session: SavedSession)
        -> AtriaColdSessionAvailability<AtriaColdSessionFact.HeartRateFacts> {
        let valid = session.points.compactMap { point -> (date: Date, bpm: Int)? in
            guard (35...240).contains(point.bpm), point.t.isFinite else { return nil }
            return (session.start.addingTimeInterval(max(0, point.t)), point.bpm)
        }.sorted { $0.date < $1.date }
        guard !valid.isEmpty else { return .knownEmpty("session contains no valid heart-rate samples") }

        var minutes: [Date: HRMinuteAccumulator] = [:]
        for sample in valid {
            let minute = minuteStart(sample.date)
            var row = minutes[minute] ?? HRMinuteAccumulator()
            row.sampleCount += 1
            row.sumBPM += Int64(sample.bpm)
            row.minimumBPM = min(row.minimumBPM ?? sample.bpm, sample.bpm)
            row.maximumBPM = max(row.maximumBPM ?? sample.bpm, sample.bpm)
            row.samplesByBPM[sample.bpm, default: 0] += 1
            minutes[minute] = row
        }

        let samples = valid.map { HRSample(t: $0.date, bpm: $0.bpm) }
        let segments = AtriaAnalytics.Strain.contiguousSegments(samples,
                                                                 excluding: session.excludedIntervals)
        for segment in segments {
            for pair in zip(segment, segment.dropFirst()) {
                let delta = pair.1.t.timeIntervalSince(pair.0.t)
                guard delta > 0 else { continue }
                guard delta <= AtriaAnalytics.Strain.maximumLoadEvidenceGap else {
                    let minute = minuteStart(pair.1.t)
                    var row = minutes[minute] ?? HRMinuteAccumulator()
                    row.droppedGapSeconds += delta
                    minutes[minute] = row
                    continue
                }
                allocateLoadInterval(start: pair.0.t,
                                     end: pair.1.t,
                                     terminalBPM: pair.1.bpm,
                                     twiceMeanBPM: pair.0.bpm + pair.1.bpm,
                                     into: &minutes)
            }
        }

        let bpms = valid.map(\.bpm).sorted()
        let isExcluded = session.isBreathwork || session.sleepWakeResearchState == "sleep_research"
        let rows = minutes.keys.sorted().map { minute -> AtriaColdSessionFact.HeartRateMinute in
            let row = minutes[minute]!
            return .init(minuteStart: minute,
                         sampleCount: row.sampleCount,
                         sumBPM: row.sumBPM,
                         minimumBPM: row.minimumBPM,
                         maximumBPM: row.maximumBPM,
                         samplesByBPM: row.samplesByBPM,
                         terminalBPMSeconds: row.terminalBPMSeconds,
                         transitionHalfBPMSeconds: row.transitionHalfBPMSeconds,
                         coveredLoadSeconds: row.coveredLoadSeconds,
                         droppedGapSeconds: row.droppedGapSeconds)
        }
        return .available(.init(sampleCount: bpms.count,
                                sumBPM: bpms.reduce(Int64(0)) { $0 + Int64($1) },
                                minimumBPM: bpms.first!,
                                maximumBPM: bpms.last!,
                                restingStableP10: percentile(bpms, 0.10),
                                sleepCandidateRestingP05: percentile(bpms, 0.05),
                                loadEligible: !isExcluded,
                                loadExclusionReason: isExcluded ? "breathwork_or_sleep_research" : nil,
                                minutes: rows))
    }

    private static func allocateLoadInterval(start: Date,
                                             end: Date,
                                             terminalBPM: Int,
                                             twiceMeanBPM: Int,
                                             into minutes: inout [Date: HRMinuteAccumulator]) {
        var cursor = start
        while cursor < end {
            let minute = minuteStart(cursor)
            let boundary = minute.addingTimeInterval(60)
            let pieceEnd = min(end, boundary)
            let seconds = pieceEnd.timeIntervalSince(cursor)
            guard seconds > 0 else { break }
            var row = minutes[minute] ?? HRMinuteAccumulator()
            row.terminalBPMSeconds[terminalBPM, default: 0] += seconds
            row.transitionHalfBPMSeconds[twiceMeanBPM, default: 0] += seconds
            row.coveredLoadSeconds += seconds
            minutes[minute] = row
            cursor = pieceEnd
        }
    }

    private static func makeRR(_ session: SavedSession)
        -> AtriaColdSessionAvailability<AtriaColdSessionFact.RRFacts> {
        guard let points = session.rrPoints else {
            return .missing("legacy session has no rrPoints field")
        }
        guard !points.isEmpty else { return .knownEmpty("session recorded no RR intervals") }
        var sourceCounts: [String: Int] = [:]
        var epochs: [Date: RREpochAccumulator] = [:]
        for point in points where point.t.isFinite {
            let source = point.source?.rawValue ?? "missing_provenance"
            sourceCounts[source, default: 0] += 1
            let date = session.start.addingTimeInterval(max(0, point.t))
            let epochStart = fiveMinuteStart(date)
            var epoch = epochs[epochStart] ?? RREpochAccumulator()
            epoch.recordCount += 1
            if (300...2000).contains(point.ms) { epoch.accepted.append((date, point.ms)) }
            epochs[epochStart] = epoch
        }
        let rows = epochs.keys.sorted().map { start -> AtriaColdSessionFact.RREpoch in
            let epoch = epochs[start]!
            let accepted = epoch.accepted.sorted { $0.date < $1.date }
            var differenceCount = 0
            var squaredDifference = 0.0
            var over50 = 0
            var maximumGap = 0.0
            for pair in zip(accepted, accepted.dropFirst()) {
                let gap = pair.1.date.timeIntervalSince(pair.0.date)
                maximumGap = max(maximumGap, gap)
                guard gap > 0, gap <= HRVSnapshot.maxReadyRRGapSeconds else { continue }
                let difference = pair.1.ms - pair.0.ms
                differenceCount += 1
                squaredDifference += Double(difference * difference)
                if abs(difference) > 50 { over50 += 1 }
            }
            return .init(epochStart: start,
                         epochEnd: start.addingTimeInterval(300),
                         recordCount: epoch.recordCount,
                         acceptedBeatCount: accepted.count,
                         rejectedBeatCount: epoch.recordCount - accepted.count,
                         sumNNMilliseconds: accepted.reduce(Int64(0)) { $0 + Int64($1.ms) },
                         sumNNSquaredMilliseconds: accepted.reduce(0) { $0 + Double($1.ms * $1.ms) },
                         adjacentDifferenceCount: differenceCount,
                         sumAdjacentDifferenceSquaredMilliseconds: squaredDifference,
                         adjacentDifferenceOver50Count: over50,
                         firstNNMilliseconds: accepted.first?.ms,
                         lastNNMilliseconds: accepted.last?.ms,
                         maximumGapSeconds: maximumGap)
        }
        return .available(.init(recordCount: rows.reduce(0) { $0 + $1.recordCount },
                                sourceCounts: sourceCounts,
                                persistedRMSSD: optionalValue(session.hrv,
                                                              missing: "RMSSD was not persisted or qualified"),
                                persistedSDNN: optionalValue(session.hrvSDNN,
                                                             missing: "SDNN was not persisted or qualified"),
                                persistedRespiratoryRate: optionalValue(session.respiratoryRate,
                                                                        missing: "respiratory rate was not persisted or qualified"),
                                referenceValidated: session.hrvReferenceValidated == true,
                                epochs: rows))
    }

    private static func makeMotion(_ session: SavedSession)
        -> AtriaColdSessionAvailability<AtriaColdSessionFact.MotionFacts> {
        let hasMotion = (session.motionHintCount ?? 0) > 0
            || (session.imuSampleCount ?? 0) > 0
            || !(session.recoveredMotionEpochs?.isEmpty ?? true)
        guard hasMotion else {
            return .missing("no decoded or diagnostic motion evidence is attached to this session")
        }
        return .available(.init(evidenceSource: session.motionEvidenceSource ?? "missing",
                                evidenceValidated: session.motionEvidenceValidated == true,
                                hintCount: session.motionHintCount ?? 0,
                                hintKinds: session.motionHintKinds,
                                recoveredEpochCount: session.recoveredMotionEpochs?.count ?? 0,
                                imuSampleCount: session.imuSampleCount,
                                imuFrameCount: session.imuFrameCount,
                                stillnessRatio: session.imuStillnessRatio,
                                movementIntensity: session.imuMovementIntensity,
                                activityBursts: session.imuActivityBursts,
                                validationState: session.imuValidationState))
    }

    private static func makeReferences(_ session: SavedSession,
                                       context: Context) -> AtriaColdSessionFact.ReferenceFacts {
        let sleeps = context.confirmedSleeps.filter { $0.start < session.end && $0.end > session.start }
            .map { sleep in
                AtriaColdSessionFact.Reference(kind: .sleep, identifier: sleep.id,
                                               start: sleep.start, end: sleep.end,
                                               label: nil, source: sleep.source)
            }
        let workouts = context.confirmedWorkouts.filter { $0.start < session.end && $0.end > session.start }
            .map { workout in
                AtriaColdSessionFact.Reference(kind: .workout, identifier: workout.id,
                                               start: workout.start, end: workout.end,
                                               label: workout.label, source: workout.source)
            }
        let activityState: AtriaColdSessionAvailability<[AtriaColdSessionFact.Reference]>
        if let activities = context.activityReferences.value {
            let matches = activities.filter { $0.start < session.end && $0.end > session.start }
            activityState = matches.isEmpty
                ? .knownEmpty("durable activity catalog has no overlapping record")
                : .available(matches)
        } else {
            activityState = context.activityReferences
        }
        return .init(sleeps: sleeps.isEmpty
                        ? .knownEmpty("confirmed sleep catalog has no overlapping record")
                        : .available(sleeps),
                     workouts: workouts.isEmpty
                        ? .knownEmpty("confirmed workout catalog has no overlapping record")
                        : .available(workouts),
                     activities: activityState)
    }

    private static func optionalValue<T>(_ value: T?, missing: String)
        -> AtriaColdSessionAvailability<T> where T: Codable & Equatable & Sendable {
        value.map(AtriaColdSessionAvailability.available) ?? .missing(missing)
    }

    private static func percentile(_ sorted: [Int], _ percentile: Double) -> Int {
        let index = min(sorted.count - 1,
                        max(0, Int((Double(sorted.count - 1) * percentile).rounded(.down))))
        return sorted[index]
    }

    private static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private static func fiveMinuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 300) * 300)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
