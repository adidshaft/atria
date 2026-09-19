import XCTest
@testable import Atria

/// Detected-workout review improvements (2026-07-17): the multi-candidate
/// generator, visible/reversible dismissal, and the honest history surface.
final class AtriaDetectedActivityReviewTests: XCTestCase {
    private let rest = 55
    private let maxHR = 190

    private func aggregateSignature(
        _ candidates: [AggregateWorkoutCandidate]
    ) -> [String] {
        candidates.map {
            [
                $0.id.uuidString,
                $0.source,
                String($0.start.timeIntervalSince1970.bitPattern),
                String($0.end.timeIntervalSince1970.bitPattern),
                String($0.samples),
                String($0.avgHR),
                String($0.peakHR),
                $0.readiness.status,
                $0.readiness.reason
            ].joined(separator: "|")
        }
    }

    private struct PreservedActiveJournal: Decodable {
        struct Sample: Decodable {
            let t: TimeInterval
            let bpm: Int
        }

        let startedAt: TimeInterval
        let updatedAt: TimeInterval
        let label: String
        let samples: [Sample]
        let rawHRNotifications: Int
        let acceptedHRSamples: Int
        let zeroHRSamples: Int
        let heldArtifacts: Int
        let droppedArtifacts: Int
        let rawHRGaps: Int
        let acceptedHRGaps: Int
        let maxRawHRGap: TimeInterval
        let maxAcceptedHRGap: TimeInterval
    }

    private var july27Gate5EvidenceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "evidence/2026-07-27-gate5-physical-positive/final-run/settled-plus-10m/active-journal-reconstructed.json"
            )
    }

    private var july27Gate5SessionsURL: URL {
        july27Gate5EvidenceURL
            .deletingLastPathComponent()
            .appendingPathComponent("sessions.json")
    }

    private var july27Gate5ConfirmedWorkoutsURL: URL {
        july27Gate5EvidenceURL
            .deletingLastPathComponent()
            .appendingPathComponent("confirmed-workouts.json")
    }

    private func july27Gate5ActiveJournal() throws -> SavedSession {
        let journal = try JSONDecoder().decode(
            PreservedActiveJournal.self,
            from: Data(contentsOf: july27Gate5EvidenceURL)
        )
        let start = Date(timeIntervalSinceReferenceDate: journal.startedAt)
        return SavedSession(
            id: UUID(),
            start: start,
            end: Date(timeIntervalSinceReferenceDate: journal.updatedAt),
            label: journal.label,
            points: journal.samples.map {
                .init(t: $0.t - journal.startedAt, bpm: $0.bpm)
            },
            hrRaw2A37: journal.rawHRNotifications,
            hrAccepted: journal.acceptedHRSamples,
            hrZero: journal.zeroHRSamples,
            hrArtifactHeld: journal.heldArtifacts,
            hrArtifactDropped: journal.droppedArtifacts,
            hrRawGaps: journal.rawHRGaps,
            hrAcceptedGaps: journal.acceptedHRGaps,
            hrMaxRawGap: journal.maxRawHRGap,
            hrMaxAcceptedGap: journal.maxAcceptedHRGap
        )
    }

    /// Compact reconstruction of the exact durable July 17 artifact. The
    /// original pull was an ignored 20 MB runtime directory and is intentionally
    /// not a test dependency: clean clones must retain this regression.
    private func july18PulledConfirmedWorkouts() -> [UserConfirmedWorkout] {
        var workout = UserConfirmedWorkout(
            id: "1784307060-1784310660-live_workout_window",
            createdAt: Date(timeIntervalSinceReferenceDate: 806_003_460),
            start: Date(timeIntervalSinceReferenceDate: 805_999_860),
            end: Date(timeIntervalSinceReferenceDate: 806_003_460),
            label: "Strength",
            source: "live_workout_window",
            confidence: "live_window_manual_confirmed",
            sessions: 1,
            samples: 920,
            avgHR: 136,
            peakHR: 164,
            p95HR: 160,
            p99HR: 163,
            thresholdHR: 122,
            streamCoveragePercent: 24,
            observedDuration: 881.8056229352951,
            reason: "stream_gaps"
        )
        workout.activityType = "Strength"
        return [workout]
    }

    private func july18PulledSessions() -> [SavedSession] {
        let start = Date(timeIntervalSinceReferenceDate: 805_999_860)
        let observedDuration = 881.8056229352951
        let points = (0..<920).map { index in
            let fraction = Double(index) / 919
            let bpm: Int
            switch index {
            case 918: bpm = 160
            case 919: bpm = 164
            default: bpm = 136
            }
            return SavedSession.Point(
                t: observedDuration * fraction,
                bpm: bpm
            )
        }
        return [
            SavedSession(
                id: UUID(uuidString: "E2FD84ED-9E22-4AD8-9571-EFCE58E6BFD5")!,
                start: start,
                end: start.addingTimeInterval(observedDuration),
                label: "Strength",
                points: points
            )
        ]
    }

    /// Clean 35-minute effort at `start`: ramp 90->150 over 3 min, 28 min
    /// sustained ~150 bpm, 4 min cool-down; RR agrees with reported HR
    /// throughout (same recipe as testRealWorkoutCandidateSurvivesHardening).
    private func cleanEffortSession(start: Date, label: String) -> SavedSession {
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        func appendPhase(duration: TimeInterval, bpmAt: (TimeInterval) -> Int) {
            let phaseEnd = cursor + duration
            while cursor < phaseEnd {
                let bpm = bpmAt(cursor - (phaseEnd - duration))
                points.append(SavedSession.Point(t: cursor, bpm: bpm))
                rrPoints.append(SavedSession.RRPoint(
                    t: cursor,
                    ms: Int((60_000.0 / Double(bpm)).rounded()),
                    source: .standardHeartRateMeasurement2A37
                ))
                cursor += 2
            }
        }
        appendPhase(duration: 3 * 60) { t in 90 + Int((t / (3 * 60)) * 60) }
        appendPhase(duration: 28 * 60) { _ in 150 }
        appendPhase(duration: 4 * 60) { t in max(90, 150 - Int((t / (4 * 60)) * 60)) }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(cursor),
                            label: label,
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 2)
    }

    /// Physical 2026-07-31 shape (IST evening): 75 minutes of genuine
    /// intervals to a ~155 peak, then 3.5 hours of ordinary mildly-elevated
    /// (~90-95 bpm) non-exertion in the same continuous session. RR agrees
    /// with HR throughout, so the whole-session window is detector-ready and
    /// previously surfaced as one 4h45m+ candidate ending only at the
    /// session boundary (sleep-onset HR decay on device).
    private func eveningLiftThenElevatedEvening(start: Date) -> SavedSession {
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        var cursor: TimeInterval = 0
        func appendPhase(duration: TimeInterval, bpmAt: (TimeInterval) -> Int) {
            let phaseStart = cursor
            while cursor < phaseStart + duration {
                let bpm = bpmAt(cursor - phaseStart)
                points.append(SavedSession.Point(t: cursor, bpm: bpm))
                rrPoints.append(SavedSession.RRPoint(
                    t: cursor,
                    ms: Int((60_000.0 / Double(bpm)).rounded()),
                    source: .standardHeartRateMeasurement2A37
                ))
                cursor += 2
            }
        }
        appendPhase(duration: 5 * 60) { t in 95 + Int((t / (5 * 60)) * 55) }
        for block in 0..<4 {
            appendPhase(duration: 12 * 60) { _ in block == 3 ? 155 : 148 }
            appendPhase(duration: 3 * 60) { _ in 112 }
        }
        appendPhase(duration: 10 * 60) { _ in 145 }
        appendPhase(duration: 3.5 * 3_600) { t in Int(t) % 120 < 60 ? 90 : 95 }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(cursor),
                            label: "Evening wear",
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 2)
    }

    /// End-bound regression (2026-07-31 physical case): the candidate must
    /// close within ~15 minutes of the last real sustained bout — never hours
    /// later when an ordinary elevated evening keeps whole-session HR above
    /// resting until sleep onset.
    func testEveningEffortCandidateEndsNearLastSustainedBoutNotAtSleepOnset() throws {
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        let session = eveningLiftThenElevatedEvening(start: start)
        // The final 10-minute 145 bpm block ends exactly 75 minutes in.
        let lastBoutEnd = start.addingTimeInterval(75 * 60)

        let candidate = try XCTUnwrap(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))

        XCTAssertLessThanOrEqual(candidate.end.timeIntervalSince(lastBoutEnd), 15 * 60,
                                 "the candidate must close within ~15 min of the last real bout, not at sleep onset hours later")
        XCTAssertGreaterThanOrEqual(candidate.end, lastBoutEnd,
                                    "the recovery tail must never cut into the real effort")
        XCTAssertLessThan(candidate.duration, 2 * 3_600,
                          "a 75-minute effort must never present as a multi-hour candidate")
        XCTAssertGreaterThan(candidate.avgHR, 120,
                             "trimmed display stats must describe the effort, not the mild evening tail")

        let listed = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertFalse(listed.isEmpty)
        for offered in listed {
            XCTAssertLessThanOrEqual(offered.end.timeIntervalSince(lastBoutEnd), 15 * 60,
                                     "every offered window shares the same honest end bound")
        }
    }

    /// A clean, RR-agreeing Strength-shaped effort that sits three bpm below
    /// the HRR50 workout band. It is intentionally review-worthy but not ready:
    /// enough sustained borderline evidence to offer for review, never enough
    /// evidence to earn medium confidence or count as a workout.
    private func strengthLikeReviewSession(start: Date) -> SavedSession {
        let duration: TimeInterval = 25 * 60
        let points = stride(from: 0.0, to: duration, by: 2.0).map {
            SavedSession.Point(t: $0, bpm: 120)
        }
        let rrPoints = stride(from: 0.0, to: duration, by: 24.0).map {
            SavedSession.RRPoint(t: $0,
                                 ms: 500,
                                 source: .standardHeartRateMeasurement2A37)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(duration),
                            label: "Strength",
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 2)
    }

    func testAggregateLaunchSingleFlightSharesIdenticalConcurrentCorpus()
        async
    {
        let session = cleanEffortSession(
            start: Date(timeIntervalSince1970: 1_801_000_000),
            label: "Single-flight effort"
        )
        let excludedStart = session.end.addingTimeInterval(60)
        let excludedDuration: TimeInterval = 7 * 3_600
        let historyExcludedJournal = SavedSession(
            id: UUID(),
            start: excludedStart,
            end: excludedStart.addingTimeInterval(excludedDuration),
            label: "History active journal",
            points: [
                .init(t: 0, bpm: 70),
                .init(t: excludedDuration, bpm: 72)
            ]
        )
        let reviewExcludedJournal = SavedSession(
            id: UUID(),
            start: excludedStart,
            end: excludedStart.addingTimeInterval(excludedDuration),
            label: "Review active journal",
            points: [
                .init(t: 0, bpm: 71),
                .init(t: excludedDuration, bpm: 73)
            ]
        )
        let historySessions = [session, historyExcludedJournal]
        let reviewSessions = [session, reviewExcludedJournal]
        let restingHR = rest
        let profileMaxHR = maxHR
        SessionStore.resetWorkoutAggregateSingleFlightForTesting()

        async let historyPass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: historySessions,
                rest: restingHR,
                maxHR: profileMaxHR
            )
        }.value
        async let reviewPass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: reviewSessions,
                rest: restingHR,
                maxHR: profileMaxHR
            )
        }.value
        let (history, review) = await (historyPass, reviewPass)

        XCTAssertEqual(
            aggregateSignature(history),
            aggregateSignature(review),
            "shared launch work must preserve byte-for-byte result fields"
        )
        let counters = SessionStore
            .workoutAggregateSingleFlightCountersForTesting()
        XCTAssertEqual(counters.executions, 1)
        XCTAssertEqual(counters.sharedResults, 1)
    }

    func testAggregateSingleFlightKeySeparatesCalibrationInputs() {
        let session = cleanEffortSession(
            start: Date(timeIntervalSince1970: 1_801_100_000),
            label: "Calibration-key effort"
        )
        let sessions = [session]
        SessionStore.resetWorkoutAggregateSingleFlightForTesting()

        let baseline = SessionStore.aggregateWorkoutCandidatesForTesting(
            in: sessions,
            rest: rest,
            maxHR: maxHR,
            thresholdFraction: 0.50
        )
        let repeated = SessionStore.aggregateWorkoutCandidatesForTesting(
            in: sessions,
            rest: rest,
            maxHR: maxHR,
            thresholdFraction: 0.50
        )
        _ = SessionStore.aggregateWorkoutCandidatesForTesting(
            in: sessions,
            rest: rest,
            maxHR: maxHR,
            thresholdFraction: 0.55
        )

        XCTAssertEqual(
            aggregateSignature(baseline),
            aggregateSignature(repeated)
        )
        let counters = SessionStore
            .workoutAggregateSingleFlightCountersForTesting()
        XCTAssertEqual(counters.executions, 2)
        XCTAssertEqual(counters.sharedResults, 1)
    }

    func testHistorySupersetAndWorkoutReviewHorizonShareCommonClusterWithoutOverlap()
        async
    {
        var configuredCalendar = Calendar(identifier: .gregorian)
        configuredCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let calendar = configuredCalendar
        let now = Date(timeIntervalSince1970: 1_801_500_000)
        let old = cleanEffortSession(
            start: now.addingTimeInterval(-72 * 3_600),
            label: "History-only old effort"
        )
        let recent = cleanEffortSession(
            start: now.addingTimeInterval(-2 * 3_600),
            label: "Common recent effort"
        )
        let historySessions = [old, recent]
        let reviewSessions = SessionStore.workoutReviewSessionsWithinHorizon(
            historySessions,
            now: now
        )
        let restingHR = rest
        let profileMaxHR = maxHR
        SessionStore.resetWorkoutAggregateSingleFlightForTesting()

        async let historyPass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: historySessions,
                rest: restingHR,
                maxHR: profileMaxHR,
                calendar: calendar
            )
        }.value
        async let reviewPass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: reviewSessions,
                rest: restingHR,
                maxHR: profileMaxHR,
                calendar: calendar
            )
        }.value
        let (history, review) = await (historyPass, reviewPass)

        let historyRecent = history.filter { $0.start >= recent.start }
        let historyOld = history.filter { $0.end <= old.end }
        XCTAssertFalse(historyOld.isEmpty,
                       "cluster sharing must retain History-only detections")
        XCTAssertEqual(
            aggregateSignature(historyRecent),
            aggregateSignature(review),
            "the exact common cluster must return the shared result unchanged"
        )
        // The host app can independently warm unrelated aggregate keys while
        // XCTest is running. Scope deterministic counters to these random
        // session identities instead of asserting process-global totals.
        let recentCounters = SessionStore
            .workoutAggregateClusterSingleFlightCountersForTesting(
                sessionID: recent.id
            )
        XCTAssertEqual(recentCounters.executions, 1,
                       "the exact common cluster executes only once")
        XCTAssertEqual(recentCounters.sharedResults, 1,
                       "History and UI must rendezvous on the common cluster")
        let oldCounters = SessionStore
            .workoutAggregateClusterSingleFlightCountersForTesting(
                sessionID: old.id
            )
        XCTAssertEqual(oldCounters.executions, 1,
                       "the History-only cluster still executes")
        XCTAssertEqual(oldCounters.sharedResults, 0,
                       "the horizon slice must not fabricate old work")
    }

    func testAggregateClusterCanonicalizesEqualStartSessionsBeforeSharing()
        async
    {
        var configuredCalendar = Calendar(identifier: .gregorian)
        configuredCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let calendar = configuredCalendar
        let start = Date(timeIntervalSince1970: 1_801_600_000)
        let template = cleanEffortSession(start: start, label: "Template")
        let first = SavedSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            start: start,
            end: template.end,
            label: "Equal start A",
            points: template.points,
            rrPoints: template.rrPoints,
            hrRaw2A37: template.points.count,
            hrAccepted: template.points.count,
            hrZero: 0,
            hrArtifactHeld: 0,
            hrArtifactDropped: 0,
            hrAcceptedGaps: 0,
            hrMaxAcceptedGap: 2
        )
        let second = SavedSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            start: start,
            end: start.addingTimeInterval(70 * 60),
            label: "Equal start B",
            points: template.points,
            rrPoints: template.rrPoints,
            hrRaw2A37: template.points.count,
            hrAccepted: template.points.count,
            hrZero: 0,
            hrArtifactHeld: 0,
            hrArtifactDropped: 0,
            hrAcceptedGaps: 0,
            hrMaxAcceptedGap: 2
        )
        // This chunk begins 31 minutes after `first` ends, but overlaps
        // `second`. A start-only sort can leave the shorter equal-start chunk
        // last and incorrectly split membership; the total order must put the
        // longer chunk last before clustering this continuation.
        let continuationStart = start.addingTimeInterval(66 * 60)
        let continuationTemplate = cleanEffortSession(
            start: continuationStart,
            label: "Continuation template"
        )
        let continuation = SavedSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            start: continuationStart,
            end: continuationTemplate.end,
            label: "Equal start continuation",
            points: continuationTemplate.points,
            rrPoints: continuationTemplate.rrPoints,
            hrRaw2A37: continuationTemplate.points.count,
            hrAccepted: continuationTemplate.points.count,
            hrZero: 0,
            hrArtifactHeld: 0,
            hrArtifactDropped: 0,
            hrAcceptedGaps: 0,
            hrMaxAcceptedGap: 2
        )
        let restingHR = rest
        let profileMaxHR = maxHR
        SessionStore.resetWorkoutAggregateSingleFlightForTesting()

        async let forwardPass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: [second, first, continuation],
                rest: restingHR,
                maxHR: profileMaxHR,
                calendar: calendar
            )
        }.value
        async let reversePass = Task.detached(priority: .utility) {
            SessionStore.aggregateWorkoutCandidatesForTesting(
                in: [first, second, continuation],
                rest: restingHR,
                maxHR: profileMaxHR,
                calendar: calendar
            )
        }.value
        let (forward, reverse) = await (forwardPass, reversePass)

        XCTAssertEqual(aggregateSignature(forward), aggregateSignature(reverse))
        let clusterCounters = SessionStore
            .workoutAggregateClusterSingleFlightCountersForTesting(
                sessionID: first.id
            )
        XCTAssertEqual(clusterCounters.executions, 1)
        XCTAssertEqual(clusterCounters.sharedResults, 1)
    }

    /// Models the July 27 physical acceptance run: a long, continuously
    /// recorded low-HR journal contains one short intermittent walk effort.
    /// The effort clears HRR50 for >5 minutes with a >3-minute continuous
    /// bout, but begins between the legacy five-minute window anchors.
    private func shortEffortInsideLongJournal(start: Date) -> SavedSession {
        let duration: TimeInterval = 74 * 60
        let effortStart: TimeInterval = 50 * 60 + 23
        let effortEnd = effortStart + 12 * 60 + 25
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        for t in stride(from: 0.0, through: duration, by: 1.0) {
            let effortOffset = t - effortStart
            let bpm: Int
            switch effortOffset {
            case 0..<60:
                bpm = 112
            case 60..<300:
                bpm = 132
            case 300..<360:
                bpm = 116
            case 360..<460:
                bpm = 134
            case 460..<(effortEnd - effortStart):
                bpm = 118
            default:
                bpm = 88
            }
            points.append(.init(t: t, bpm: bpm))
            if Int(t) % 24 == 0 {
                rrPoints.append(.init(t: t,
                                      ms: Int((60_000.0 / Double(bpm)).rounded()),
                                      source: .standardHeartRateMeasurement2A37))
            }
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(duration),
                            label: "Live journal",
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 1)
    }

    private func allDayJournal(start: Date,
                               duration: TimeInterval = 3 * 60 * 60,
                               efforts: [(start: TimeInterval, duration: TimeInterval)] = [])
        -> SavedSession {
        var points: [SavedSession.Point] = []
        var rrPoints: [SavedSession.RRPoint] = []
        for t in stride(from: 0.0, through: duration, by: 1.0) {
            let active = efforts.contains { t >= $0.start && t < $0.start + $0.duration }
            let bpm = active ? 132 : 88
            points.append(.init(t: t, bpm: bpm))
            if Int(t) % 24 == 0 {
                rrPoints.append(.init(t: t,
                                      ms: Int((60_000.0 / Double(bpm)).rounded()),
                                      source: .standardHeartRateMeasurement2A37))
            }
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(duration),
                            label: "All-day live journal",
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: 0,
                            hrAcceptedGaps: 0,
                            hrMaxAcceptedGap: 1)
    }

    /// Mirrors the preserved July 21 gym capture: ~30.6 minutes wall time,
    /// ~14.25 minutes observed HR split by one radio gap, clean agreeing RR,
    /// and a sustained strength-level distribution (not a lone optical peak).
    private func july21GappedGymSession(start: Date,
                                        sparseSpikeOnly: Bool = false,
                                        contactCompromised: Bool = false) -> SavedSession {
        let wallDuration: TimeInterval = 1_839
        let secondSegmentStart: TimeInterval = 1_414
        var sampleTimes = Array(stride(from: 0.0, through: 430.0, by: 1.0))
        sampleTimes.append(contentsOf: stride(from: secondSegmentStart,
                                              through: wallDuration,
                                              by: 1.0))
        let points = sampleTimes.enumerated().map { index, t in
            let bpm = sparseSpikeOnly ? (index == 300 ? 180 : 80) : (index == 300 ? 180 : 135)
            return SavedSession.Point(t: t, bpm: bpm)
        }
        let rrPoints = sampleTimes.enumerated().compactMap { index, t -> SavedSession.RRPoint? in
            guard index % 24 == 0 else { return nil }
            let bpm = points[index].bpm
            return SavedSession.RRPoint(t: t,
                                        ms: Int((60_000.0 / Double(bpm)).rounded()),
                                        source: .standardHeartRateMeasurement2A37)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(wallDuration),
                            label: "Strength",
                            points: points,
                            rrPoints: rrPoints,
                            hrRaw2A37: points.count,
                            hrAccepted: points.count,
                            hrZero: 0,
                            hrArtifactHeld: 0,
                            hrArtifactDropped: contactCompromised ? points.count : 0,
                            hrAcceptedGaps: 1,
                            hrMaxAcceptedGap: secondSegmentStart - 430)
    }

    private func confirmedWorkout(covering session: SavedSession) -> UserConfirmedWorkout {
        UserConfirmedWorkout(id: "confirmed-\(UUID().uuidString)",
                             createdAt: session.end,
                             start: session.start,
                             end: session.end,
                             label: session.label,
                             source: "test",
                             confidence: "medium",
                             sessions: 1,
                             samples: session.points.count,
                             avgHR: 140,
                             peakHR: 150,
                             p95HR: 150,
                             p99HR: 150,
                             thresholdHR: 122,
                             streamCoveragePercent: 100,
                             observedDuration: session.duration,
                             reason: "test")
    }

    // MARK: - Multi-candidate generator

    @MainActor
    func testJuly17StrengthArtifactKeepsHonestCoverageAndReviewSuppressionIsReversible() throws {
        let exactID = "1784307060-1784310660-live_workout_window"
        let workout = try XCTUnwrap(july18PulledConfirmedWorkouts().first { $0.id == exactID })

        XCTAssertEqual(workout.start.timeIntervalSinceReferenceDate, 805_999_860, accuracy: 0.001)
        XCTAssertEqual(workout.end.timeIntervalSinceReferenceDate, 806_003_460, accuracy: 0.001)
        XCTAssertEqual(workout.duration, 3_600, accuracy: 0.001)
        XCTAssertEqual(workout.label, "Strength")
        XCTAssertEqual(workout.activityType, "Strength")
        XCTAssertEqual(workout.source, "live_workout_window")
        XCTAssertEqual(workout.confidence, "live_window_manual_confirmed")
        XCTAssertEqual(workout.reason, "stream_gaps")
        XCTAssertEqual(workout.samples, 920)
        XCTAssertEqual(workout.avgHR, 136)
        XCTAssertEqual(workout.peakHR, 164)
        XCTAssertEqual(workout.p95HR, 160)
        XCTAssertEqual(workout.p99HR, 163)
        XCTAssertEqual(workout.observedDuration, 881.8056229352951, accuracy: 0.001)
        XCTAssertEqual(workout.streamCoveragePercent, 24)
        XCTAssertEqual(workout.streamCoveragePercent,
                       Int((workout.observedDuration / workout.duration * 100).rounded(.down)),
                       "coverage must remain the observed fraction of the real one-hour window")

        let sessions = july18PulledSessions().filter {
            $0.start < workout.end && $0.end > workout.start
        }
        XCTAssertEqual(sessions.map(\.id.uuidString),
                       ["E2FD84ED-9E22-4AD8-9571-EFCE58E6BFD5"])
        let samplesInsideWorkout = sessions.reduce(into: 0) { count, session in
            count += session.points.filter {
                let date = session.start.addingTimeInterval($0.t)
                return date >= workout.start && date <= workout.end
            }.count
        }
        XCTAssertEqual(samplesInsideWorkout, workout.samples,
                       "the persisted 920-sample claim must reproduce from the pulled session")

        let beforeConfirmation = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [],
            rest: 60,
            maxHR: 190
        )
        XCTAssertLessThan(workout.observedDuration, 15 * 60)
        XCTAssertLessThan(workout.streamCoveragePercent, 40)
        XCTAssertTrue(beforeConfirmation.isEmpty,
                      "the historical 24%-covered, 14m42s stream must remain below automatic review gates")

        XCTAssertTrue(SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [workout],
            rest: 60,
            maxHR: 190
        ).isEmpty, "the exact confirmed Strength window must not be offered twice")

        let previousDismissals = AtriaDismissedWorkoutCandidateStore.load()
        // Isolate capacity as well as overlap: other tests intentionally write
        // far-future tombstones, and the bounded newest-64 store would otherwise
        // evict this real 2026 window before durability can be asserted.
        AtriaDismissedWorkoutCandidateStore.save([])
        defer { AtriaDismissedWorkoutCandidateStore.save(previousDismissals) }

        let store = SessionStore()
        XCTAssertTrue(store.dismissWorkoutCandidate(start: workout.start, end: workout.end))
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: workout.start, end: workout.end)
        }, "dismissal must survive a store reload as a durable window tombstone")
        XCTAssertTrue(SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [],
            dismissedCandidates: store.dismissedWorkoutCandidatesForUI,
            rest: 60,
            maxHR: 190
        ).isEmpty)

        XCTAssertTrue(store.restoreDismissedWorkoutCandidate(start: workout.start,
                                                              end: workout.end))
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: workout.start, end: workout.end)
        })
        XCTAssertTrue(SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [],
            dismissedCandidates: store.dismissedWorkoutCandidatesForUI,
            rest: 60,
            maxHR: 190
        ).isEmpty,
                      "restore removes only the tombstone; it must not fabricate the missing HR coverage")
    }

    func testTwoSeparateEffortsBothSurfaceNewestFirstWhileSinglePathStillReturnsOne() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let morningRun = cleanEffortSession(start: base, label: "Morning run")
        let eveningGym = cleanEffortSession(start: base.addingTimeInterval(10 * 3600),
                                            label: "Evening gym")

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [morningRun, eveningGym],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )

        XCTAssertEqual(candidates.count, 2,
                       "a day with two unconfirmed efforts must offer both, not only the single best")
        XCTAssertGreaterThan(candidates[0].end, candidates[1].end, "newest window first")
        XCTAssertTrue(AtriaDismissedWorkoutCandidate(start: eveningGym.start, end: eveningGym.end)
            .overlaps(start: candidates[0].start, end: candidates[0].end),
                      "the newest offer covers the evening effort")
        XCTAssertTrue(AtriaDismissedWorkoutCandidate(start: morningRun.start, end: morningRun.end)
            .overlaps(start: candidates[1].start, end: candidates[1].end),
                      "the older offer covers the morning effort")
        for candidate in candidates {
            XCTAssertEqual(candidate.kind, .activityCandidate,
                           "an HR-only window is an activity candidate, never a found workout")
            XCTAssertGreaterThan(candidate.avgHR, 0)
            XCTAssertGreaterThan(candidate.peakHR, 0)
            XCTAssertGreaterThan(candidate.streamCoveragePercent, 0)
            XCTAssertFalse(candidate.reason.isEmpty)
            XCTAssertEqual(candidate.confidence, .medium,
                           "only detector-ready HR windows earn medium review confidence")
        }

        // The single-candidate path is unchanged: exactly one best window,
        // and it is one of the windows the list offers.
        let single = SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [morningRun, eveningGym],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertNotNil(single)
        XCTAssertTrue(candidates.contains { $0.id == single?.id },
                      "the list variant must agree with the single-best summary about qualifying windows")
    }

    func testStrengthLikeNonReadyEffortSurfacesWithLowConfidenceAcrossReviewBuilders() throws {
        let start = Date(timeIntervalSince1970: 1_800_100_000)
        let session = strengthLikeReviewSession(start: start)
        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertFalse(readiness.ready)
        XCTAssertTrue(readiness.strengthCandidate)
        XCTAssertTrue(readiness.reviewWorthyCandidate)
        XCTAssertEqual(session.detectedActivity(rest: rest, maxHR: maxHR)?.confidence, .low,
                       "the direct detector is the confidence authority for a non-ready effort")

        let single = try XCTUnwrap(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))
        XCTAssertEqual(single.kind, .activityCandidate)
        XCTAssertEqual(single.confidence, .low,
                       "the Home/notification cache must not promote a Strength-like near miss to medium")

        let listed = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertFalse(listed.isEmpty, "a review-worthy Strength-like effort must remain visible")
        XCTAssertTrue(listed.allSatisfy { $0.kind == .activityCandidate && $0.confidence == .low },
                      "every Health-history projection of the non-ready effort must keep low confidence")
    }

    func testShortQualifiedEffortInsideLongJournalUsesBoundedReviewWindow() throws {
        let journalStart = Date(timeIntervalSince1970: 1_800_120_000)
        let session = shortEffortInsideLongJournal(start: journalStart)
        let candidate = try XCTUnwrap(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))

        let physicalEffortStart = journalStart.addingTimeInterval(50 * 60 + 23)
        XCTAssertEqual(candidate.confidence, .medium,
                       "a window that clears the production HRR50 gate is detector-ready")
        XCTAssertGreaterThanOrEqual(candidate.start, physicalEffortStart)
        XCTAssertLessThanOrEqual(candidate.start.timeIntervalSince(physicalEffortStart), 3 * 60)
        XCTAssertLessThanOrEqual(candidate.duration, 20 * 60,
                                 "the review must not expand one short effort to the full live journal")
    }

    func testHistoryUsesBoundedAuthorityForThreeHourJournalEvenWhenReviewCacheIsNil() throws {
        let start = Date(timeIntervalSince1970: 1_800_180_000)
        let effortStart: TimeInterval = 80 * 60 + 23
        let session = allDayJournal(start: start,
                                    efforts: [(effortStart, 12 * 60 + 25)])
        let detections = SessionStore.makeHistoryDetections(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR,
            calendar: .current
        )
        let activity = try XCTUnwrap(detections.first { $0.kind == .activityCandidate })

        XCTAssertLessThanOrEqual(activity.duration, 30 * 60,
                                 "the bounded replay may choose its 30-minute window, never the journal")
        XCTAssertGreaterThanOrEqual(
            activity.start,
            start.addingTimeInterval(effortStart - 30),
            "window anchoring may include only a few pre-effort seconds"
        )
        XCTAssertFalse(detections.contains {
            ($0.kind == .activityCandidate || $0.kind == .workout)
                && $0.duration >= 2.5 * 60 * 60
        }, "History must never project the all-day live journal as one workout")

        let visibleWithoutCache = AtriaActivityReviewProjection.visibleDetections(
            detections,
            workoutReview: nil,
            confirmedWorkouts: [],
            interval: DateInterval(start: start, end: session.end)
        )
        XCTAssertEqual(visibleWithoutCache.map(\.id), [activity.id],
                       "a nil Home cache must still leave only the bounded History authority")
        XCTAssertEqual(
            SessionStore.makeHistoryDetections(sessions: [session],
                                               confirmedWorkouts: [],
                                               rest: rest,
                                               maxHR: maxHR,
                                               calendar: .current).first?.id,
            activity.id,
            "bounded History identity must be stable across rebuilds"
        )
    }

    func testHistoryRoutesSeparatedEffortsAsSeparateBoundedReviews() {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let first = cleanEffortSession(start: start, label: "Morning effort")
        let second = cleanEffortSession(start: start.addingTimeInterval(2 * 60 * 60),
                                        label: "Evening effort")
        let detections = SessionStore.makeHistoryDetections(
            sessions: [first, second],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR,
            calendar: .current
        ).filter { $0.kind == .activityCandidate || $0.kind == .workout }

        XCTAssertEqual(detections.count, 2)
        XCTAssertTrue(detections.allSatisfy { $0.duration <= first.duration })
        XCTAssertTrue(detections.contains { $0.start >= second.start && $0.end <= second.end })
        XCTAssertTrue(detections.contains { $0.start >= first.start && $0.end <= first.end })
    }

    func testQuietAllDayJournalDoesNotBecomeActivity() {
        let start = Date(timeIntervalSince1970: 1_800_240_000)
        let session = allDayJournal(start: start)
        let detections = SessionStore.makeHistoryDetections(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR,
            calendar: .current
        )

        XCTAssertFalse(detections.contains {
            $0.kind == .activityCandidate || $0.kind == .workout
        })
    }

    func testHistoryPreservesRawRestAndSleepDetections() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let daytimeStart = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 1, day: 18, hour: 12)
        ))
        let overnightStart = try XCTUnwrap(calendar.date(
            from: DateComponents(year: 2027, month: 1, day: 18, hour: 22)
        ))
        let restSession = allDayJournal(start: daytimeStart, duration: 2 * 60 * 60)
        let sleepSession = allDayJournal(start: overnightStart, duration: 4 * 60 * 60)

        let detections = SessionStore.makeHistoryDetections(
            sessions: [restSession, sleepSession],
            confirmedWorkouts: [],
            rest: 75,
            maxHR: maxHR,
            calendar: calendar
        )

        let restDetection = try XCTUnwrap(detections.first { $0.kind == .restCandidate })
        let sleepDetection = try XCTUnwrap(detections.first { $0.kind == .sleepCandidate })
        XCTAssertEqual(restDetection.id, restSession.id)
        XCTAssertEqual(sleepDetection.id, sleepSession.id)
        XCTAssertEqual(restDetection.start, restSession.start)
        XCTAssertEqual(sleepDetection.end, sleepSession.end)
    }

    func testHistoryPreservesStandaloneAndConfirmedAndDismissedLifecycle() throws {
        let start = Date(timeIntervalSince1970: 1_800_260_000)
        let session = cleanEffortSession(start: start, label: "Standalone effort")
        let standalone = try XCTUnwrap(SessionStore.makeHistoryDetections(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR,
            calendar: .current
        ).first { $0.kind == .activityCandidate })

        XCTAssertTrue(SessionStore.makeHistoryDetections(
            sessions: [session],
            confirmedWorkouts: [confirmedWorkout(covering: session)],
            rest: rest,
            maxHR: maxHR,
            calendar: .current
        ).allSatisfy { $0.kind != .activityCandidate && $0.kind != .workout })

        let dismissed = SessionStore.activityDetectionsForUI(
            [standalone],
            dismissedCandidates: [
                AtriaDismissedWorkoutCandidate(start: standalone.start, end: standalone.end)
            ]
        )
        XCTAssertTrue(dismissed.isEmpty,
                      "dismissal remains a presentation lifecycle choice after central bounding")
    }

    func testPreservedJuly27PhysicalWalkProducesBoundedReadyReview() throws {
        // The replayed artifacts live under the gitignored `evidence/` tree
        // (private device data, tracked only when explicitly staged). On a
        // checkout without them this test failed with "no such file" on every
        // run and was mistaken for a detection regression (2026-09-02). A
        // missing artifact is a skip, not a failure; the assertions below are
        // unchanged wherever the evidence exists.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: july27Gate5EvidenceURL.path),
                          "July-27 gate-5 evidence is not present on this machine")
        let session = try july27Gate5ActiveJournal()
        var sessions = try JSONDecoder().decode(
            [SavedSession].self,
            from: Data(contentsOf: july27Gate5SessionsURL)
        )
        sessions.append(session)
        let confirmed = try JSONDecoder().decode(
            [UserConfirmedWorkout].self,
            from: Data(contentsOf: july27Gate5ConfirmedWorkoutsURL)
        )
        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: confirmed,
            rest: 59,
            maxHR: 190
        )
        let actualStart = Date(timeIntervalSince1970: 1_785_149_903)
        let actualEnd = actualStart.addingTimeInterval(12 * 60 + 25)
        let candidate = try XCTUnwrap(candidates.first {
            min($0.end, actualEnd).timeIntervalSince(max($0.start, actualStart)) > 0
        })

        XCTAssertEqual(candidate.confidence, .medium,
                       "the preserved walk clears HRR50 in a bounded window")
        XCTAssertGreaterThanOrEqual(candidate.start, actualStart)
        XCTAssertLessThanOrEqual(candidate.start, actualEnd)
        XCTAssertLessThanOrEqual(candidate.duration, 20 * 60,
                                 "one physical walk must not become a 74-minute review")
    }

    func testPreservedJuly21GappedGymEffortSurfacesReviewOnly() throws {
        let session = july21GappedGymSession(start: Date(timeIntervalSince1970: 1_800_150_000))
        let readiness = session.workoutReadiness(rest: rest, maxHR: maxHR)

        XCTAssertEqual(readiness.streamCoveragePercent, 47, accuracy: 1)
        XCTAssertGreaterThanOrEqual(readiness.observedDuration, 12 * 60)
        XCTAssertLessThan(readiness.observedDuration, 15 * 60)
        XCTAssertFalse(readiness.ready, "a 47% stream must never clear automatic readiness")
        XCTAssertFalse(readiness.strengthCandidate, "the normal 15-minute gate remains unchanged")
        XCTAssertTrue(readiness.gappedStrengthReviewCandidate)
        XCTAssertTrue(readiness.reviewWorthyCandidate)

        let detection = try XCTUnwrap(session.detectedActivity(rest: rest, maxHR: maxHR))
        XCTAssertEqual(detection.kind, .activityCandidate)
        XCTAssertEqual(detection.confidence, .low)
        XCTAssertTrue(detection.reason.contains("low-confidence review only"))
    }

    func testGappedFallbackRejectsSparseSpikeAndCompromisedContact() {
        let start = Date(timeIntervalSince1970: 1_800_160_000)
        let sparseSpike = july21GappedGymSession(start: start, sparseSpikeOnly: true)
        let compromised = july21GappedGymSession(start: start.addingTimeInterval(4_000),
                                                  contactCompromised: true)

        let sparseReadiness = sparseSpike.workoutReadiness(rest: rest, maxHR: maxHR)
        XCTAssertFalse(sparseReadiness.gappedStrengthReviewCandidate,
                       "an isolated high peak without a strong HR distribution must stay hidden")
        XCTAssertNil(sparseSpike.detectedActivity(rest: rest, maxHR: maxHR))

        let compromisedReadiness = compromised.workoutReadiness(rest: rest, maxHR: maxHR)
        XCTAssertTrue(compromisedReadiness.contactCompromised)
        XCTAssertFalse(compromisedReadiness.gappedStrengthReviewCandidate)
        XCTAssertNil(compromised.detectedActivity(rest: rest, maxHR: maxHR))
    }

    func testGappedFallbackRejectsFlatStressOrDrivingPlateau() {
        let start = Date(timeIntervalSince1970: 1_800_170_000)
        let source = july21GappedGymSession(start: start)
        let flatPoints = source.points.map { SavedSession.Point(t: $0.t, bpm: 135) }
        let flatRR = source.rrPoints?.map {
            SavedSession.RRPoint(t: $0.t,
                                 ms: 444,
                                 source: .standardHeartRateMeasurement2A37)
        }
        let plateau = SavedSession(id: UUID(),
                                   start: source.start,
                                   end: source.end,
                                   label: "Unclassified",
                                   points: flatPoints,
                                   rrPoints: flatRR,
                                   hrRaw2A37: flatPoints.count,
                                   hrAccepted: flatPoints.count,
                                   hrZero: 0,
                                   hrArtifactHeld: 0,
                                   hrArtifactDropped: 0,
                                   hrAcceptedGaps: 1,
                                   hrMaxAcceptedGap: source.hrMaxAcceptedGapValue)

        let readiness = plateau.workoutReadiness(rest: rest, maxHR: maxHR)
        XCTAssertGreaterThan(readiness.p95HR, readiness.thresholdHR,
                             "fixture sanity: the plateau has high sustained HR")
        XCTAssertFalse(readiness.gappedStrengthReviewCandidate,
                       "a flat high-HR plateau lacks the dynamic effort distribution required by the fallback")
        XCTAssertNil(plateau.detectedActivity(rest: rest, maxHR: maxHR))
    }

    func testNoHeartRateStrengthWindowNeverSurfacesForAutomaticReview() {
        let start = Date(timeIntervalSince1970: 1_800_200_000)
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(30 * 60),
                                   label: "Strength",
                                   points: [])

        XCTAssertNil(session.detectedActivity(rest: rest, maxHR: maxHR))
        XCTAssertNil(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))
        XCTAssertTrue(SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ).isEmpty, "metadata-only/no-HR Strength must stay user-confirmed only")
    }

    func testSparseRecoveredMotionDoesNotPoisonQualifiedHROnlyReview() throws {
        let start = Date(timeIntervalSince1970: 1_800_300_000)
        var session = cleanEffortSession(start: start, label: "Sparse R10 effort")
        session.recoveredMotionEpochs = [
            AtriaRecoveredMotionEpoch(start: start.addingTimeInterval(5 * 60),
                                      end: start.addingTimeInterval(5 * 60 + 30),
                                      rows: 30,
                                      validatedRows: 30,
                                      stillnessRatio: 0.25,
                                      movementIntensity: 0.20,
                                      p95VectorDelta: 0.15,
                                      maximumGapSeconds: 1,
                                      measurementValidated: true,
                                      lowMotionQualified: false,
                                      reason: "test_sparse_recovered_motion")
        ]

        let assessment = SessionStore.recoveredActivityAssessment(
            in: [session],
            start: session.start,
            end: session.end,
            restingHR: rest
        )
        XCTAssertTrue(assessment.hasRecoveredEpochs)
        XCTAssertFalse(assessment.evidenceSufficient)

        let single = try XCTUnwrap(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))
        XCTAssertEqual(single.kind, .activityCandidate)
        XCTAssertEqual(single.confidence, .medium,
                       "sparse motion must neither veto nor promote the HR-only evidence")
        XCTAssertNil(single.suggestedActivityType)
        XCTAssertTrue(single.reason.contains("recovered motion incomplete; HR-only review"))

        let listed = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(listed.count, 1)
        XCTAssertNil(listed.first?.suggestedActivityType)
        XCTAssertTrue(listed.first?.reason.contains("recovered motion incomplete; HR-only review") == true)
    }

    func testSufficientRecoveredMotionContradictionStillSuppressesReview() {
        let start = Date(timeIntervalSince1970: 1_800_400_000)
        var session = cleanEffortSession(start: start, label: "Contradicted effort")
        session.recoveredMotionEpochs = stride(from: 0, to: 2_100, by: 120).map { offset in
            AtriaRecoveredMotionEpoch(start: start.addingTimeInterval(TimeInterval(offset)),
                                      end: start.addingTimeInterval(TimeInterval(offset + 120)),
                                      rows: 120,
                                      validatedRows: 120,
                                      stillnessRatio: 0.99,
                                      movementIntensity: 0.01,
                                      p95VectorDelta: 0.01,
                                      maximumGapSeconds: 1,
                                      measurementValidated: true,
                                      lowMotionQualified: true,
                                      reason: "test_dense_still_recovered_motion")
        }

        let assessment = SessionStore.recoveredActivityAssessment(
            in: [session],
            start: session.start,
            end: session.end,
            restingHR: rest
        )
        XCTAssertTrue(assessment.evidenceSufficient)
        XCTAssertFalse(assessment.activitySupported)
        XCTAssertNil(SessionStore.makeWorkoutReviewCandidateForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ))
        XCTAssertTrue(SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        ).isEmpty)
    }

    func testConfirmedAndDismissedWindowsAreExcludedFromCandidateList() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let morningRun = cleanEffortSession(start: base, label: "Morning run")
        let eveningGym = cleanEffortSession(start: base.addingTimeInterval(10 * 3600),
                                            label: "Evening gym")
        let sessions = [morningRun, eveningGym]

        let afterConfirm = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [confirmedWorkout(covering: morningRun)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(afterConfirm.map(\.end), [eveningGym.end],
                       "a confirmed window must drop out while the other effort stays offered")

        let afterDismiss = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [],
            dismissedCandidates: [AtriaDismissedWorkoutCandidate(start: eveningGym.start,
                                                                 end: eveningGym.end)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertEqual(afterDismiss.map(\.end), [morningRun.end],
                       "a dismissed window must drop out while the other effort stays offered")

        let afterBoth = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: sessions,
            confirmedWorkouts: [confirmedWorkout(covering: morningRun)],
            dismissedCandidates: [AtriaDismissedWorkoutCandidate(start: eveningGym.start,
                                                                 end: eveningGym.end)],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertTrue(afterBoth.isEmpty)
    }

    func testOverlappingWindowsCollapseToOneOfferPerPhysicalEffort() {
        // One physical effort recorded as two chunks two minutes apart: the
        // replay evaluates each chunk AND the stitched aggregates. The list
        // must offer that effort once, never as several overlapping rows.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let chunk1 = cleanEffortSession(start: base, label: "Run chunk")
        let chunk2 = cleanEffortSession(start: chunk1.end.addingTimeInterval(2 * 60),
                                        label: "Run chunk")

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [chunk1, chunk2],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )

        XCTAssertFalse(candidates.isEmpty)
        for (index, lhs) in candidates.enumerated() {
            for rhs in candidates.dropFirst(index + 1) {
                let window = AtriaDismissedWorkoutCandidate(start: lhs.start, end: lhs.end)
                XCTAssertFalse(window.overlaps(start: rhs.start, end: rhs.end),
                               "offered windows must never overlap each other")
            }
        }
        XCTAssertEqual(candidates.count, 1,
                       "two chunks of one effort collapse to the single strongest window")
    }

    func testContactCompromisedWindowNeverEntersTheList() {
        // Same artifact-night construction as
        // testArtifactContactGapNightProducesNoWorkoutCandidate.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var points: [SavedSession.Point] = []
        var cursor: TimeInterval = 0
        while cursor < 20 * 60 {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        var spacingToggle = false
        let artifactEnd = cursor + 22 * 60
        while cursor < artifactEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 120))
            cursor += spacingToggle ? 12 : 5
            spacingToggle.toggle()
        }
        let tailEnd = cursor + 18 * 60
        while cursor < tailEnd {
            points.append(SavedSession.Point(t: cursor, bpm: 55))
            cursor += 5
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(cursor),
                                   label: "Sleep",
                                   points: points,
                                   rrPoints: nil,
                                   hrRaw2A37: 1_000,
                                   hrAccepted: 600,
                                   hrZero: 300,
                                   hrArtifactHeld: 100,
                                   hrArtifactDropped: 100,
                                   hrAcceptedGaps: 4,
                                   hrMaxAcceptedGap: 150)
        XCTAssertTrue(session.hrContactCompromised)

        let candidates = SessionStore.makeWorkoutReviewCandidatesForCache(
            sessions: [session],
            confirmedWorkouts: [],
            rest: rest,
            maxHR: maxHR
        )
        XCTAssertTrue(candidates.isEmpty,
                      "the multi-candidate list must not weaken the contact-artifact fail-closed branch")
    }

    // MARK: - Dismissal visibility + restore round trip

    @MainActor
    func testDismissRestoreRoundTripMakesTheWindowOfferableAgain() {
        let store = SessionStore()
        // Unique far-future window so parallel test state can never collide.
        let start = Date(timeIntervalSince1970: 2_270_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(40 * 60)
        defer {
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        XCTAssertTrue(store.dismissWorkoutCandidate(start: start, end: end))
        XCTAssertTrue(store.dismissedWorkoutCandidatesForUI.contains {
            $0.overlaps(start: start, end: end)
        }, "a dismissal must be visible so it can be undone")
        XCTAssertTrue(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        })

        XCTAssertTrue(store.restoreDismissedWorkoutCandidate(start: start, end: end))
        XCTAssertFalse(store.dismissedWorkoutCandidatesForUI.contains {
            $0.overlaps(start: start, end: end)
        })
        XCTAssertFalse(AtriaDismissedWorkoutCandidateStore.load().contains {
            $0.overlaps(start: start, end: end)
        }, "restore must remove the durable tombstone so the generator can re-offer the window")
        XCTAssertFalse(store.restoreDismissedWorkoutCandidate(start: start, end: end),
                       "restoring an already-restored window reports no change")
    }

    @MainActor
    func testRestoreClearsHomeBannerIDSuppressionForTheSameWindow() {
        let store = SessionStore()
        let start = Date(timeIntervalSince1970: 2_280_000_000 + Double.random(in: 0..<100_000))
        let end = start.addingTimeInterval(35 * 60)
        let idsKey = "atria.workoutReview.dismissedIDs"
        let legacyIDKey = "atria.workoutReview.dismissedID"
        let defaults = UserDefaults.standard
        let previousIDs = defaults.stringArray(forKey: idsKey)
        let previousLegacy = defaults.string(forKey: legacyIDKey)
        defer {
            if let previousIDs {
                defaults.set(previousIDs, forKey: idsKey)
            } else {
                defaults.removeObject(forKey: idsKey)
            }
            if let previousLegacy {
                defaults.set(previousLegacy, forKey: legacyIDKey)
            } else {
                defaults.removeObject(forKey: legacyIDKey)
            }
            let unrelated = AtriaDismissedWorkoutCandidateStore.load().filter {
                !$0.overlaps(start: start, end: end)
            }
            AtriaDismissedWorkoutCandidateStore.save(unrelated)
        }

        let matchingID = "\(Int(start.timeIntervalSince1970.rounded()))-\(Int(end.timeIntervalSince1970.rounded()))-single_session"
        let unrelatedID = "100-200-single_session"
        defaults.set([matchingID, unrelatedID], forKey: idsKey)
        defaults.set(matchingID, forKey: legacyIDKey)

        XCTAssertTrue(store.dismissWorkoutCandidate(start: start, end: end))
        XCTAssertTrue(store.restoreDismissedWorkoutCandidate(start: start, end: end))

        XCTAssertEqual(defaults.stringArray(forKey: idsKey), [unrelatedID],
                       "restore must clear the Home banner's ID suppression for the restored window only")
        XCTAssertNil(defaults.string(forKey: legacyIDKey))
    }

    func testWorkoutReviewDismissedIDPurgeKeepsUnparsableAndUnrelatedIDs() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(30 * 60)
        let overlapping = "\(Int(start.timeIntervalSince1970) + 60)-\(Int(end.timeIntervalSince1970) - 60)-aggregate_chunks"
        let unrelated = "\(Int(start.timeIntervalSince1970) - 7_200)-\(Int(start.timeIntervalSince1970) - 3_600)-single_session"
        let malformed = "debug-saved-workout-review"

        let kept = SessionStore.workoutReviewDismissedIDs([overlapping, unrelated, malformed],
                                                          removingOverlapWithStart: start,
                                                          end: end)
        XCTAssertEqual(kept, [unrelated, malformed],
                       "purge drops only IDs whose encoded window overlaps; unparsable IDs stay (fail closed)")
    }

    // MARK: - Honest copy + wiring source scans

    private func projectSource(_ relativePath: String) throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func testDetectedActivitiesHistorySurfaceKeepsHonestCopy() throws {
        let source = try projectSource("Atria/AtriaHistorySection.swift")
        let reviewSource = try projectSource("Atria/AtriaHomeView.swift")

        let sectionStart = try XCTUnwrap(source.range(of: "struct AtriaDetectedActivitiesSection: View"))
        let sectionEnd = try XCTUnwrap(source.range(of: "// MARK: - Full history",
                                                    range: sectionStart.upperBound..<source.endIndex))
        let section = String(source[sectionStart.lowerBound..<sectionEnd.lowerBound])

        XCTAssertTrue(section.contains("Text(\"Activity candidate\")"),
                      "an HR-only window is an activity candidate, never a found workout")
        XCTAssertFalse(source.contains("Workout found"),
                       "the history surface must never claim a workout was found from HR alone")
        XCTAssertTrue(reviewSource.contains("Label(\"Review effort\", systemImage: \"waveform.path.ecg\")"),
                      "opening an HR-only candidate must keep neutral review copy")
        XCTAssertFalse(reviewSource.contains("Label(\"Workout found\", systemImage: \"waveform.path.ecg\")"),
                       "the review flow must not upgrade an HR-only effort into a found workout")
        XCTAssertTrue(section.contains("Coverage \\(candidate.streamCoveragePercent)% · Avg \\(candidate.avgHR) · Peak \\(candidate.peakHR) bpm"),
                      "rows show the real evidence: coverage, average and peak HR")
        // 2026-09-02: the tier is a label and the reason rides beside it; the
        // old medium sentence restated the Confirm button beneath it.
        XCTAssertTrue(section.contains("Text(candidate.confidence == .medium ? \"Medium confidence\" : \"Low confidence\")"),
                      "rows state their confidence tier")
        XCTAssertTrue(section.contains("Text(Self.reasonText(candidate.reason))"),
                      "rows say why, using the pipeline's own reason code")
        XCTAssertFalse(section.contains("confirm the activity type"),
                       "the instruction lives on the Confirm button, not in prose")
        XCTAssertTrue(section.contains(".accessibilityElement(children: .combine)"),
                      "confidence and evidence must be included in the row's accessibility output")
        for fabricated in ["strain", "calorie", "kcal", "steps"] {
            XCTAssertFalse(section.lowercased().contains(fabricated),
                           "no synthesized \(fabricated) for HR-only windows")
        }
        XCTAssertTrue(section.contains("store?.dismissWorkoutCandidate(start: candidate.start"),
                      "dismiss goes through the durable store tombstone")
        XCTAssertTrue(section.contains("store?.restoreDismissedWorkoutCandidate(start: window.start"),
                      "dismissals are visible and reversible from the same surface")
        XCTAssertTrue(section.contains("Dismissed detections"))
        XCTAssertTrue(section.contains("SessionStore.workoutReviewCandidateReviewRequestedNotification"),
                      "review routes into the existing guided flow instead of a parallel save path")

        // The projection host must keep the narrow observation contract.
        XCTAssertTrue(source.contains("store.$dashboardRevision"),
                      "the projection store observes only dashboardRevision, never the whole SessionStore")
        XCTAssertTrue(source.contains("candidates: store.workoutReviewCandidatesForUI(rest: rest,"),
                      "rendered candidates come from the fail-closed review cache accessor")
    }

    func testHomeShellRoutesHistoryReviewRequestsIntoExistingGuidedFlow() throws {
        let homeSource = try projectSource("Atria/AtriaHomeView.swift")
        XCTAssertTrue(homeSource.contains("SessionStore.workoutReviewCandidateReviewRequestedNotification"),
                      "the Home shell must listen for history review requests")
        // 2026-08-14 pin migration: the App Review restructure routed the
        // notification into handleWorkoutReviewCandidateNotification. The
        // invariants are unchanged and now scanned in that handler.
        let receiveStart = try XCTUnwrap(homeSource.range(of: "for: SessionStore.workoutReviewCandidateReviewRequestedNotification"))
        XCTAssertTrue(String(homeSource[receiveStart.upperBound...].prefix(200))
            .contains("handleWorkoutReviewCandidateNotification(note)"),
                      "the Home shell must route history review requests into the shared handler")
        let handlerStart = try XCTUnwrap(homeSource.range(of: "private func handleWorkoutReviewCandidateNotification"))
        let handler = String(homeSource[handlerStart.lowerBound...].prefix(900))
        XCTAssertTrue(handler.contains("guard workoutSession == nil"),
                      "review presentation must fail closed during a live workout")
        XCTAssertTrue(handler.contains("presentWorkoutReview(candidate: candidate)"),
                      "history rows open the SAME AtriaWorkoutReviewDraft flow as the Home banner")

        let healthSource = try projectSource("Atria/AtriaHealthScreen.swift")
        XCTAssertTrue(healthSource.contains("AtriaDetectedActivitiesHost(store: store"),
                      "the detected activities surface is mounted with History in the Trends scope")
    }

    func testMultiCandidateGeneratorPinsActivityCandidateKind() throws {
        let sessionsSource = try projectSource("Atria/Sessions.swift")
        XCTAssertTrue(sessionsSource.contains("nonisolated static func makeWorkoutReviewCandidatesForCache"),
                      "the list variant must exist alongside the single-best path")
        let helperStart = try XCTUnwrap(sessionsSource.range(of: "private nonisolated static func workoutReviewCandidate(fromQualifiedWindow"))
        let helper = String(sessionsSource[helperStart.lowerBound...].prefix(4_000))
        XCTAssertTrue(helper.contains("kind: .activityCandidate"),
                      "every listed window stays an activity candidate until the user confirms its type")
        XCTAssertTrue(sessionsSource.contains("func restoreDismissedWorkoutCandidate(start: Date, end: Date) -> Bool"))
        XCTAssertTrue(sessionsSource.contains("var dismissedWorkoutCandidatesForUI: [AtriaDismissedWorkoutCandidate]"))
    }
}
