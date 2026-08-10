import XCTest
@testable import Atria

final class AtriaHRVQualificationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func session(dayOffset: Int,
                         source: AtriaRRSourceProvenance?,
                         hour: Int = 23,
                         sufficientRR: Bool = true) -> SavedSession {
        let day = calendar.date(byAdding: .day,
                                value: dayOffset,
                                to: Date(timeIntervalSince1970: 1_800_000_000))!
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        let rrPoints: [SavedSession.RRPoint] = sufficientRR
            ? stride(from: 1.0, through: 16 * 60.0, by: 1.0).map { offset in
                SavedSession.RRPoint(t: offset,
                                     ms: Int(offset).isMultiple(of: 2) ? 980 : 1_020,
                                     source: source)
            }
            : [SavedSession.RRPoint(t: 1, ms: 1_000, source: source)]
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(6 * 60 * 60),
                            label: "Overnight HRV fixture",
                            points: [SavedSession.Point(t: 0, bpm: 52),
                                     SavedSession.Point(t: 6 * 60 * 60, bpm: 52)],
                            hrv: 42,
                            rrPoints: rrPoints)
    }

    private func confirmedMainSleep(for session: SavedSession,
                                    start: Date? = nil,
                                    end: Date? = nil,
                                    id: String = UUID().uuidString,
                                    persistedHRV: Int? = nil,
                                    persistedHRVWindowCount: Int? = nil) -> UserConfirmedSleep {
        let sleepStart = start ?? session.start
        let sleepEnd = end ?? session.end
        return UserConfirmedSleep(id: id,
                                  createdAt: sleepEnd,
                                  start: sleepStart,
                                  end: sleepEnd,
                                  source: "manual_sleep",
                                  confidence: "user_confirmed_hr_only",
                                  sessions: 1,
                                  samples: session.points.count,
                                  avgHR: session.avg,
                                  peakHR: session.peak,
                                  restingHR: session.restingStable,
                                  hrv: persistedHRV,
                                  hrvWindowCount: persistedHRVWindowCount,
                                  duration: sleepEnd.timeIntervalSince(sleepStart),
                                  span: sleepEnd.timeIntervalSince(sleepStart),
                                  reason: "test",
                                  motionSource: "user_review",
                                  motionValidated: false,
                                  stageSegments: nil,
                                  eventTimeZoneIdentifier: "UTC")
    }

    private func rebuiltBaseline(sessions: [SavedSession],
                                 confirmedSleeps: [UserConfirmedSleep]) -> PersonalBaseline {
        SessionStore.rebuildBaseline(from: sessions,
                                     previousBaseline: PersonalBaseline(restingHR: 52),
                                     profile: AthleteProfile(age: 30,
                                                             measuredMaxHR: 190,
                                                             maxHRSource: .measured,
                                                             updated: nil,
                                                             hasCompletedOnboarding: true),
                                     confirmedSleeps: confirmedSleeps)
    }

    func testOnlyQualifiedStandardRRInsideConfirmedMainSleepAccruesDistinctHRVDay() {
        let standard = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        let legacy = session(dayOffset: 1, source: nil)
        let standardSleep = confirmedMainSleep(for: standard)
        let legacySleep = confirmedMainSleep(for: legacy)
        let baseline = rebuiltBaseline(sessions: [standard, legacy],
                                       confirmedSleeps: [standardSleep, legacySleep])

        XCTAssertEqual(standard.localRMSSD, 42)
        XCTAssertNil(legacy.localRMSSD)
        XCTAssertEqual(baseline.freshHRVSampleCount(now: legacy.end), 1)
        XCTAssertEqual(baseline.hrvSampleCount, 1)
    }

    func testMultipleQualifiedWindowsOnOneDayCountOnce() {
        let first = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        let second = session(dayOffset: 0, source: .standardHeartRateMeasurement2A37)
        let sleep = confirmedMainSleep(for: first)
        let baseline = rebuiltBaseline(sessions: [first, second], confirmedSleeps: [sleep])

        XCTAssertEqual(baseline.freshHRVSampleCount(now: second.end), 1)
    }

    func testPersistedHRVCannotBypassInsufficientRREvidence() {
        let sparse = session(dayOffset: 0,
                             source: .standardHeartRateMeasurement2A37,
                             sufficientRR: false)

        XCTAssertTrue(sparse.hasQualifiedStandardRRProvenance)
        XCTAssertNil(sparse.localRMSSD)
        XCTAssertEqual(sparse.localHRVWindowCount, 0)
    }

    func testPersistedConfirmedSleepHRVIsClearedWithoutQualifiedRawRR() throws {
        let legacy = session(dayOffset: 0, source: nil)
        let persisted = confirmedMainSleep(for: legacy,
                                           id: "legacy-confirmed-sleep",
                                           persistedHRV: 77,
                                           persistedHRVWindowCount: 4)

        let requalified = SessionStore.requalifiedConfirmedSleepHRVRecords(
            [persisted],
            sessions: [legacy]
        )

        let updated = try XCTUnwrap(requalified.first)
        XCTAssertEqual(updated.id, persisted.id)
        XCTAssertEqual(updated.start, persisted.start)
        XCTAssertEqual(updated.end, persisted.end)
        XCTAssertEqual(updated.duration, persisted.duration)
        XCTAssertEqual(updated.source, persisted.source)
        XCTAssertNil(updated.hrv)
        XCTAssertEqual(updated.hrvWindowCount, 0)
    }

    func testPersistedConfirmedSleepHRVIsReplacedFromExactQualifiedRRWindow() throws {
        let standard = session(dayOffset: 0,
                               source: .standardHeartRateMeasurement2A37)
        let persisted = confirmedMainSleep(for: standard,
                                           id: "qualified-confirmed-sleep",
                                           persistedHRV: 99,
                                           persistedHRVWindowCount: 9)

        let updated = try XCTUnwrap(
            SessionStore.requalifiedConfirmedSleepHRVRecords(
                [persisted],
                sessions: [standard]
            ).first
        )

        XCTAssertEqual(updated.hrv, standard.localRMSSD(in: persisted.start,
                                                        end: persisted.end))
        XCTAssertEqual(updated.hrvWindowCount,
                       standard.localHRVWindowCount(in: persisted.start,
                                                   end: persisted.end))
        XCTAssertNotEqual(updated.hrv, 99)
    }

    func testRecoveredHistoricalRRFillsOvernightSleepOnWakeDay() throws {
        let recovered = session(dayOffset: 0,
                                source: .verifiedWhoop4HistoricalV24)
        let sleep = confirmedMainSleep(for: recovered,
                                       id: "recovered-overnight-sleep")

        XCTAssertNotEqual(calendar.startOfDay(for: sleep.start),
                          calendar.startOfDay(for: sleep.end),
                          "the fixture must cross midnight so readiness belongs to the wake day")

        let updated = try XCTUnwrap(
            SessionStore.requalifiedConfirmedSleepHRVRecords(
                [sleep],
                sessions: [recovered]
            ).first
        )

        XCTAssertGreaterThanOrEqual(updated.hrvWindowCount ?? 0, 3)
        XCTAssertEqual(updated.hrv,
                       recovered.localRMSSD(in: sleep.start, end: sleep.end))
        XCTAssertNotNil(updated.hrv)
    }

    func testConfirmedSleepAggregatesQualifiedWindowsAcrossReconnectSessions() throws {
        let first = session(dayOffset: 0,
                            source: .standardHeartRateMeasurement2A37)
        let sleepStart = first.start
        let sessions = (0..<3).map { index -> SavedSession in
            let start = sleepStart.addingTimeInterval(Double(index) * 6 * 60)
            let rrPoints = stride(from: 1.0, through: 6 * 60.0, by: 1.0).map { offset in
                SavedSession.RRPoint(
                    t: offset,
                    ms: Int(offset).isMultiple(of: 2) ? 980 : 1_020,
                    source: .standardHeartRateMeasurement2A37
                )
            }
            return SavedSession(
                id: UUID(),
                start: start,
                end: start.addingTimeInterval(6 * 60),
                label: "Reconnect-bounded overnight HRV fixture",
                points: [SavedSession.Point(t: 0, bpm: 52)],
                rrPoints: rrPoints
            )
        }
        let sleepEnd = sleepStart.addingTimeInterval(6 * 60 * 60)

        XCTAssertTrue(sessions.allSatisfy {
            $0.localRMSSD(in: sleepStart, end: sleepEnd) == nil
        }, "no individual reconnect chunk should meet the three-window publication gate")

        let metrics = SessionStore.confirmedSleepWindowMetrics(
            from: sessions,
            start: sleepStart,
            end: sleepEnd,
            rest: 52
        )

        XCTAssertEqual(metrics.hrvWindowCount, 3)
        XCTAssertEqual(metrics.hrv, 40)

        let persisted = confirmedMainSleep(
            for: sessions[0],
            start: sleepStart,
            end: sleepEnd,
            id: "split-session-confirmed-sleep"
        )
        let requalified = try XCTUnwrap(
            SessionStore.requalifiedConfirmedSleepHRVRecords(
                [persisted],
                sessions: sessions
            ).first
        )
        XCTAssertEqual(requalified.hrvWindowCount, 3)
        XCTAssertEqual(requalified.hrv, 40)
    }

    func testConfirmedSleepDoesNotPromoteAmbiguousReconnectWindows() {
        let qualified = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        let ambiguous = session(dayOffset: 0, source: nil)
        let metrics = SessionStore.confirmedSleepWindowMetrics(
            from: [qualified, ambiguous],
            start: qualified.start,
            end: qualified.end,
            rest: 52
        )

        XCTAssertEqual(metrics.hrvWindowCount, qualified.localHRVWindowCount)
        XCTAssertEqual(metrics.hrv,
                       qualified.localRMSSD(in: qualified.start, end: qualified.end))
    }

    func testRecoveredHistoricalRRFeedsLocalButNotReferenceValidatedHRVSource() throws {
        let recovered = session(dayOffset: 0,
                                source: .verifiedWhoop4HistoricalV24)

        let local = try XCTUnwrap(SessionStore.latestLocalRMSSDSource(in: [recovered]))
        XCTAssertEqual(local.sessionID, recovered.id)
        XCTAssertEqual(local.value, recovered.localRMSSD)
        XCTAssertNil(SessionStore.latestReferenceValidatedHRVSource(in: [recovered]))
    }

    func testQualifiedDaytimeRRDoesNotAdvanceOvernightTrustCount() {
        let daytime = session(dayOffset: 0,
                              source: .standardHeartRateMeasurement2A37,
                              hour: 13)
        let baseline = rebuiltBaseline(sessions: [daytime], confirmedSleeps: [])

        XCTAssertEqual(daytime.localRMSSD, 42)
        XCTAssertFalse(daytime.isOvernightHRVWindow(calendar: calendar))
        XCTAssertEqual(baseline.freshHRVSampleCount(now: daytime.end), 0)
    }

    func testClockOvernightQualifiedRRWithoutConfirmedSleepDoesNotAdvanceHRVDay() {
        let overnight = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        let baseline = rebuiltBaseline(sessions: [overnight], confirmedSleeps: [])

        XCTAssertTrue(overnight.isOvernightHRVWindow(calendar: calendar))
        XCTAssertEqual(overnight.localRMSSD, 42)
        XCTAssertEqual(baseline.hrvSampleCount, 0)
        XCTAssertEqual(baseline.freshHRVSampleCount(now: overnight.end), 0)
    }

    func testConfirmedMainSleepSeedsRestingBaselineAfterRawSessionRetirement() {
        let retired = session(dayOffset: 0,
                              source: .standardHeartRateMeasurement2A37)
        let sleep = confirmedMainSleep(for: retired,
                                       id: "retained-confirmed-main-sleep")
        let unrelatedSurvivingSession = session(dayOffset: 1,
                                                source: .standardHeartRateMeasurement2A37,
                                                hour: 13)

        let baseline = SessionStore.rebuildBaseline(
            from: [unrelatedSurvivingSession],
            previousBaseline: PersonalBaseline(),
            profile: AthleteProfile(age: 30,
                                    measuredMaxHR: 190,
                                    maxHRSource: .measured,
                                    updated: nil,
                                    hasCompletedOnboarding: true),
            confirmedSleeps: [sleep]
        )

        XCTAssertEqual(baseline.restingInt, sleep.restingHR)
        XCTAssertEqual(baseline.restingSampleCount, 1)
        XCTAssertEqual(baseline.sessions, 1)
        XCTAssertNil(baseline.hrvInt,
                     "a retained sleep RHR must not promote an unqualified HRV scalar")
    }

    func testConfirmedNapCannotSeedRestingBaselineAfterRawSessionRetirement() {
        let retired = session(dayOffset: 0,
                              source: .standardHeartRateMeasurement2A37)
        let nap = UserConfirmedSleep(
            id: "retained-confirmed-nap",
            createdAt: retired.end,
            start: retired.start,
            end: retired.start.addingTimeInterval(45 * 60),
            source: "nap_candidate",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: retired.points.count,
            avgHR: retired.avg,
            peakHR: retired.peak,
            restingHR: retired.restingStable,
            hrv: nil,
            hrvWindowCount: 0,
            duration: 45 * 60,
            span: 45 * 60,
            reason: "test",
            motionSource: "user_review",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )
        var baseline = PersonalBaseline()

        let seeded = SessionStore.seedBaselineFromConfirmedSleeps(
            &baseline,
            confirmedSleeps: [nap]
        )

        XCTAssertEqual(seeded, 0)
        XCTAssertNil(baseline.restingInt)
        XCTAssertEqual(baseline.restingSampleCount, 0)
    }

    func testConfirmedSleepBaselineMergeFillsEveryMissingQualifiedDayAndIsIdempotent() {
        let firstSession = session(dayOffset: 0,
                                   source: .standardHeartRateMeasurement2A37)
        let secondSession = session(dayOffset: 1,
                                    source: .standardHeartRateMeasurement2A37)
        let thirdSession = session(dayOffset: 2,
                                   source: .standardHeartRateMeasurement2A37)
        let sleeps = [
            confirmedMainSleep(for: firstSession,
                               id: "sleep-day-0",
                               persistedHRV: 44,
                               persistedHRVWindowCount: 3),
            confirmedMainSleep(for: secondSession,
                               id: "sleep-day-1",
                               persistedHRV: 48,
                               persistedHRVWindowCount: 4),
            confirmedMainSleep(for: thirdSession,
                               id: "sleep-day-2",
                               persistedHRV: 52,
                               persistedHRVWindowCount: 5),
        ]
        var baseline = PersonalBaseline()
        baseline.learn(fromResting: 58,
                       hrv: 0,
                       at: firstSession.end,
                       overnight: false)

        XCTAssertTrue(SessionStore.baselineNeedsConfirmedSleepMerge(
            baseline,
            confirmedSleeps: sleeps,
            calendar: calendar
        ))
        XCTAssertEqual(SessionStore.seedBaselineFromConfirmedSleeps(
            &baseline,
            confirmedSleeps: sleeps,
            calendar: calendar
        ), 3)
        XCTAssertEqual(baseline.restingSampleCount, 3)
        XCTAssertEqual(baseline.hrvSampleCount, 3)
        XCTAssertEqual(baseline.freshHRVSampleCount(now: thirdSession.end), 3)
        XCTAssertFalse(SessionStore.baselineNeedsConfirmedSleepMerge(
            baseline,
            confirmedSleeps: sleeps,
            calendar: calendar
        ))
        XCTAssertEqual(SessionStore.seedBaselineFromConfirmedSleeps(
            &baseline,
            confirmedSleeps: sleeps,
            calendar: calendar
        ), 0)
        XCTAssertEqual(baseline.restingSampleCount, 3)
        XCTAssertEqual(baseline.hrvSampleCount, 3)
    }

    func testQualifiedRRMustFallInsideConfirmedMainSleepWindow() {
        let overnight = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        // The qualified RR fixture occupies only the first 16 minutes. This
        // confirmed main sleep starts an hour later, so session overlap alone
        // must not launder the out-of-window RR into overnight HRV.
        let sleep = confirmedMainSleep(for: overnight,
                                       start: overnight.start.addingTimeInterval(60 * 60),
                                       end: overnight.end)
        let baseline = rebuiltBaseline(sessions: [overnight], confirmedSleeps: [sleep])

        XCTAssertNil(SessionStore.confirmedMainSleepHRVEvidence(
            for: overnight,
            confirmedSleeps: [sleep]
        ))
        XCTAssertEqual(baseline.freshHRVSampleCount(now: overnight.end), 0)
    }

    func testShortConfirmedRestCannotQualifyAsMainSleepHRV() {
        let overnight = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        let shortRest = confirmedMainSleep(for: overnight,
                                           end: overnight.start.addingTimeInterval(2 * 60 * 60))

        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(shortRest))
        XCTAssertNil(SessionStore.confirmedMainSleepHRVEvidence(
            for: overnight,
            confirmedSleeps: [shortRest]
        ))
        XCTAssertEqual(rebuiltBaseline(sessions: [overnight], confirmedSleeps: [shortRest])
            .freshHRVSampleCount(now: overnight.end), 0)
    }

    func testLegacyClockOnlyBaselineDecodesWithoutTrustedHRV() throws {
        let overnight = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        let legacy = PersonalBaseline(restingHR: 52,
                                      hrvEMA: 42,
                                      sessions: 1,
                                      updated: overnight.end,
                                      samples: [
                                        .init(date: overnight.end,
                                              restingHR: 52,
                                              rmssd: 42,
                                              overnight: true)
                                      ])
        let encoded = try JSONEncoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "hrvQualificationVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(PersonalBaseline.self, from: legacyData)

        XCTAssertEqual(decoded.restingInt, 52)
        XCTAssertNil(decoded.hrvInt)
        XCTAssertEqual(decoded.hrvSampleCount, 0)
        XCTAssertEqual(decoded.freshHRVSampleCount(now: overnight.end), 0)
        XCTAssertFalse(decoded.hasTrustedHRVBaseline(now: overnight.end))
    }

    // MARK: - Recovery HRV window selection (last SWS before waking)

    private typealias RecoverySelection = AtriaRecoveryHRVWindowSelection

    /// Builds an HRVSnapshot that clears every readiness gate (window ≥300s,
    /// RR gap ≤3s, confidence ≥0.75, beats, successive differences) so the
    /// selector's preference — not qualification — is what the tests exercise.
    private func readyRecoverySnapshot(kept: Int,
                                       confidence: Double,
                                       end: Date,
                                       gap: TimeInterval = 1) -> HRVSnapshot {
        HRVSnapshot(rmssd: 42,
                    sdnn: 55,
                    pnn50: 12,
                    lnRMSSD: log(42),
                    confidence: confidence,
                    kept: kept,
                    raw: kept,
                    rejectedOutOfRange: 0,
                    rejectedDeltaOver20Percent: 0,
                    rejectedHRMismatch: 0,
                    interpolated: 0,
                    successiveDifferenceCount: kept - 1,
                    windowSeconds: 300,
                    maxRRGapSeconds: gap,
                    respiratoryRate: 14,
                    measurementStart: end.addingTimeInterval(-300),
                    measurementEnd: end,
                    analyzedAt: end,
                    provenance: .sleepRRWindow)
    }

    func testRecoveryWindowPrefersLastDeepSegmentBeforeWaking() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)

        // Two deep segments; the LAST deep window before waking is [420,455].
        let segments = [
            SleepStageSegment(id: "d1", start: at(60), end: at(95), stage: .deep),
            SleepStageSegment(id: "l1", start: at(95), end: at(400), stage: .light),
            SleepStageSegment(id: "d2", start: at(420), end: at(455), stage: .deep),
            SleepStageSegment(id: "w1", start: at(455), end: at(480), stage: .awake)
        ]
        XCTAssertEqual(
            RecoverySelection.lastDeepSegmentBeforeWaking(stageSegments: segments,
                                                          wakeEvent: wake)?.id,
            "d2"
        )

        // Highest-quality window overall, but during light sleep (fallback pick).
        let remCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: readyRecoverySnapshot(kept: 250, confidence: 0.95, end: at(205)))
        // High-quality window over the EARLY deep segment.
        let earlyDeepCandidate = RecoverySelection.Candidate(
            start: at(58), end: at(63),
            snapshot: readyRecoverySnapshot(kept: 240, confidence: 0.92, end: at(63)))
        // Lower-quality (still ready) window inside the LAST deep segment.
        let lastDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: readyRecoverySnapshot(kept: 160, confidence: 0.80, end: at(435)))
        let candidates = [remCandidate, earlyDeepCandidate, lastDeepCandidate]

        // With motion-validated staging the last-deep window wins even though it
        // is the lowest raw quality of the three.
        let selected = RecoverySelection.selectRecoveryWindow(candidates: candidates,
                                                              stageSegments: segments,
                                                              wakeEvent: wake)
        XCTAssertEqual(selected, lastDeepCandidate)
    }

    func testRecoveryWindowFallsBackToQualityRuleWithoutStaging() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)

        let remCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: readyRecoverySnapshot(kept: 250, confidence: 0.95, end: at(205)))
        let earlyDeepCandidate = RecoverySelection.Candidate(
            start: at(58), end: at(63),
            snapshot: readyRecoverySnapshot(kept: 240, confidence: 0.92, end: at(63)))
        let lastDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: readyRecoverySnapshot(kept: 160, confidence: 0.80, end: at(435)))
        let candidates = [remCandidate, earlyDeepCandidate, lastDeepCandidate]

        // HR-only night (no staging) -> current best-quality rule (most kept).
        let selected = RecoverySelection.selectRecoveryWindow(candidates: candidates,
                                                              stageSegments: [],
                                                              wakeEvent: wake)
        XCTAssertEqual(selected, remCandidate)
    }

    func testRecoveryWindowFallsBackWhenNoReadyWindowCoversDeepSegment() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)
        let segments = [
            SleepStageSegment(id: "d2", start: at(420), end: at(455), stage: .deep),
            SleepStageSegment(id: "w1", start: at(455), end: at(480), stage: .awake)
        ]

        let remCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: readyRecoverySnapshot(kept: 250, confidence: 0.95, end: at(205)))
        // The only window over the deep segment fails the RR-gap gate (>3s), so
        // qualification stays hard and selection falls back to the best ready
        // window overall.
        let unreadyDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: readyRecoverySnapshot(kept: 200, confidence: 0.90, end: at(435), gap: 5))
        XCTAssertFalse(unreadyDeepCandidate.isReady)

        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [remCandidate, unreadyDeepCandidate],
            stageSegments: segments,
            wakeEvent: wake)
        XCTAssertEqual(selected, remCandidate)
    }
}
