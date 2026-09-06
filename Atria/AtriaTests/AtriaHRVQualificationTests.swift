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

    /// A trend-eligible session: >= 8 HR points (so it is not filtered as
    /// insignificant) plus 16 min of qualified 2A37 RR (so its whole-session
    /// `localRMSSD` qualifies at 42 — the value the OLD trend would have shown).
    private func trendEligibleQualifiedSession(hour: Int) -> SavedSession {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
        let rrPoints = stride(from: 1.0, through: 16 * 60.0, by: 1.0).map { offset in
            SavedSession.RRPoint(t: offset,
                                 ms: Int(offset).isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        }
        let hrPoints = stride(from: 0.0, through: 6 * 60 * 60, by: 20 * 60).map {
            SavedSession.Point(t: $0, bpm: 55)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(6 * 60 * 60),
                            label: "trend HRV fixture",
                            points: hrPoints,
                            hrv: 42,
                            rrPoints: rrPoints)
    }

    func testOverviewTrendHRVExcludesDaytimeLocalRMSSDWithoutConfirmedSleep() {
        // Screenshot-3 defect: the HRV nightly trend borrowed a daytime/live
        // whole-session localRMSSD (e.g. a 50 ms Aug-11 point) when the confirmed
        // nightly authority had no qualified same-cycle HRV. The trend must gate
        // on confirmed-main-sleep exact-window evidence, identical to the rollup.
        let daytime = trendEligibleQualifiedSession(hour: 13)
        XCTAssertEqual(daytime.localRMSSD, 42,
                       "the whole-session scalar still qualifies — that is exactly why the trend must not use it")

        let withoutConfirmedSleep = SessionStore.makeOverviewTrendPoints(
            sessions: [daytime],
            rest: 60,
            maxHR: 190,
            confirmedSleeps: [],
            now: daytime.end.addingTimeInterval(3_600),
            calendar: calendar
        )
        XCTAssertEqual(withoutConfirmedSleep.count, 1,
                       "the day still produces a trend point (load/RHR), just without HRV")
        XCTAssertNil(withoutConfirmedSleep.first?.hrv,
                     "a daytime localRMSSD without a confirmed main sleep must not appear as nightly HRV")

        // With a confirmed main sleep covering the session, the qualified
        // same-cycle RMSSD is the trend point — surfaces stay in agreement.
        let sleep = confirmedMainSleep(for: daytime, id: "trend-confirmed-main")
        let withConfirmedSleep = SessionStore.makeOverviewTrendPoints(
            sessions: [daytime],
            rest: 60,
            maxHR: 190,
            confirmedSleeps: [sleep],
            now: daytime.end.addingTimeInterval(3_600),
            calendar: calendar
        )
        // 40 (not the whole-session 42): the value now comes from the
        // confirmed-main-sleep windowed RMSSD — the exact-window evidence — which
        // is the point of the gate. The alternating 980/1020 ms RR yields a
        // consecutive-difference RMSSD of 40.
        XCTAssertEqual(withConfirmedSleep.first?.hrv, 40,
                       "a confirmed-main-sleep RMSSD must appear as the nightly HRV trend point")
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

    // MARK: - Pair-based window qualification (2026-08-29)

    private func rrFixtureSession(rrPoints: [SavedSession.RRPoint],
                                  duration: TimeInterval) -> SavedSession {
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        let start = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: day)!
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(duration),
                            label: "Pair qualification fixture",
                            points: [SavedSession.Point(t: 0, bpm: 52),
                                     SavedSession.Point(t: duration, bpm: 52)],
                            rrPoints: rrPoints)
    }

    /// The device-measured dropout shape: ~1 Hz RR where the link loses a few
    /// beats every ~25 s, leaving a 6 s hole (>3 s, so no pair may span it).
    /// 19-beat runs restart their 980/1020 alternation, so a difference taken
    /// across a hole would be 0 ms and measurably deflate the ±40 ms RMSSD.
    private func dropoutShapedRRPoints(throughSecond limit: Int) -> [SavedSession.RRPoint] {
        var rrPoints: [SavedSession.RRPoint] = []
        for second in 1...limit {
            let indexInBlock = (second - 1) % 25
            guard indexInBlock < 19 else { continue }
            rrPoints.append(SavedSession.RRPoint(
                t: Double(second),
                ms: indexInBlock.isMultiple(of: 2) ? 980 : 1_020,
                source: .standardHeartRateMeasurement2A37
            ))
        }
        return rrPoints
    }

    func testDropoutShapedRRStreamStillQualifiesWindows() {
        // 72% valid-pair coverage over 25 minutes: under full-window
        // continuity this produced ZERO windows on nearly every real night;
        // pair-based qualification must trust it.
        let session = rrFixtureSession(
            rrPoints: dropoutShapedRRPoints(throughSecond: 1_500),
            duration: 1_500
        )

        XCTAssertGreaterThanOrEqual(session.localHRVWindowCount, 3)
        XCTAssertEqual(session.localRMSSD, 40,
                       "every valid adjacent-beat difference is ±40 ms; a hole-straddling 0 ms difference would drag this below 40")
    }

    func testWindowBelowValidPairCoverageFloorProducesNoWindow() {
        // 200 s of clean beats, silence, then two trailing beats that stretch
        // the span past one window position: ~201 s of valid pairs is below
        // the 210 s (70% of 300 s) floor, so the window may not qualify.
        var rrPoints = (1...200).map { second in
            SavedSession.RRPoint(t: Double(second),
                                 ms: second.isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        }
        rrPoints.append(SavedSession.RRPoint(
            t: 301, ms: 1_000, source: .standardHeartRateMeasurement2A37))
        rrPoints.append(SavedSession.RRPoint(
            t: 302, ms: 1_000, source: .standardHeartRateMeasurement2A37))
        let session = rrFixtureSession(rrPoints: rrPoints, duration: 310)

        XCTAssertEqual(session.localHRVWindowCount, 0)
        XCTAssertNil(session.localRMSSD)
    }

    func testWindowBelowMinimumBeatCountProducesNoWindow() {
        // 100 slow beats (3 s apart) cover 297 s of valid pairs — coverage
        // passes, but 100 kept beats is under the 150-beat window minimum. The
        // trailing cluster keeps the session above the session-level RR floor
        // without ever forming a qualifying window of its own.
        var rrPoints = (1...100).map { index in
            SavedSession.RRPoint(t: Double(index) * 3,
                                 ms: index.isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        }
        rrPoints.append(contentsOf: (400...460).map { second in
            SavedSession.RRPoint(t: Double(second),
                                 ms: second.isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        })
        let session = rrFixtureSession(rrPoints: rrPoints, duration: 470)

        XCTAssertEqual(session.localHRVWindowCount, 0)
        XCTAssertNil(session.localRMSSD)
    }

    func testDifferencesNeverStraddleADropoutHole() throws {
        // One 10 s hole with a 200 ms value step across it. Straddling the
        // hole would add a single large difference; the correct RMSSD comes
        // only from the 279 real adjacent-beat pairs.
        var samples: [(t: Double, ms: Double)] = []
        for second in 0...290 where !(140...149).contains(second) {
            let ms: Double
            switch second {
            case 139: ms = 900
            case 150: ms = 1_100
            default: ms = second.isMultiple(of: 2) ? 980 : 1_020
            }
            samples.append((t: Double(second), ms: ms))
        }

        var squaredSum = 0.0
        var pairCount = 0
        var straddleSquaredSum = 0.0
        var straddleCount = 0
        for index in 1..<samples.count {
            let diff = samples[index].ms - samples[index - 1].ms
            straddleSquaredSum += diff * diff
            straddleCount += 1
            guard samples[index].t - samples[index - 1].t <= 3 else { continue }
            squaredSum += diff * diff
            pairCount += 1
        }
        let expected = sqrt(squaredSum / Double(pairCount))
        let straddled = sqrt(straddleSquaredSum / Double(straddleCount))
        XCTAssertGreaterThan(abs(straddled - expected), 0.5,
                             "the fixture must make a straddling difference numerically visible")

        let lnRMSSD = try XCTUnwrap(SavedSession.qualifiedLnRMSSD(samples))
        XCTAssertEqual(exp(lnRMSSD), expected, accuracy: 0.000_001)
    }

    func testCleanContinuousWindowMatchesFullContinuityQualification() throws {
        // Regression parity: a fully gap-free five-minute window must produce
        // exactly what the previous all-pairs-continuous path produced.
        let samples = (0...300).map { index in
            (t: Double(index), ms: index.isMultiple(of: 2) ? 980.0 : 1_020.0)
        }

        let lnRMSSD = try XCTUnwrap(SavedSession.qualifiedLnRMSSD(samples))
        XCTAssertEqual(exp(lnRMSSD), 40, accuracy: 0.000_001)
    }

    func testOverlappingWindowsCannotInflateEvidenceWithoutDistinctCoverage() {
        // ~620 s of the dropout pattern places three half-stride windows that
        // each qualify, but together they stand on only ~432 s of distinct
        // valid-pair time — the same physiology counted through overlapping
        // frames. The 600 s distinct floor must thin them below the
        // three-window trust threshold.
        let short = rrFixtureSession(
            rrPoints: dropoutShapedRRPoints(throughSecond: 620),
            duration: 620
        )
        XCTAssertEqual(short.localHRVWindowCount, 2)
        XCTAssertNil(short.localRMSSD)

        // The same pattern continued past 900 s carries over 600 s of
        // distinct pair time, so the trust threshold is honestly reachable.
        let long = rrFixtureSession(
            rrPoints: dropoutShapedRRPoints(throughSecond: 1_000),
            duration: 1_000
        )
        XCTAssertGreaterThanOrEqual(long.localHRVWindowCount, 3)
        XCTAssertEqual(long.localRMSSD, 40)
    }

    func testVersionOnePersistedBaselineFailsClosedUntilRequalification() throws {
        let overnight = session(dayOffset: 0,
                                source: .standardHeartRateMeasurement2A37)
        // A baseline persisted by the previous full-continuity qualification
        // (version 1) carries window counts and RMSSDs that are not comparable
        // to pair-based values; its HRV must fail closed on decode while the
        // resting history is retained.
        let versionOne = PersonalBaseline(restingHR: 52,
                                          hrvEMA: 42,
                                          sessions: 1,
                                          updated: overnight.end,
                                          samples: [
                                            .init(date: overnight.end,
                                                  restingHR: 52,
                                                  rmssd: 42,
                                                  overnight: true)
                                          ],
                                          hrvQualificationVersion: 1)
        let decoded = try JSONDecoder().decode(
            PersonalBaseline.self,
            from: JSONEncoder().encode(versionOne)
        )

        XCTAssertEqual(decoded.restingInt, 52)
        XCTAssertNil(decoded.hrvInt)
        XCTAssertEqual(decoded.hrvSampleCount, 0)
        XCTAssertEqual(decoded.freshHRVSampleCount(now: overnight.end), 0)

        // The rebuild path recomputes HRV from raw RR through the current
        // pair-based windowing and restores trust at the current version.
        let rebuilt = rebuiltBaseline(
            sessions: [overnight],
            confirmedSleeps: [confirmedMainSleep(for: overnight)]
        )
        XCTAssertEqual(rebuilt.hrvQualificationVersion,
                       PersonalBaseline.currentHRVQualificationVersion)
        XCTAssertEqual(rebuilt.freshHRVSampleCount(now: overnight.end), 1)
    }

    // MARK: - Recovery HRV window selection (last SWS before waking)

    private typealias RecoverySelection = AtriaRecoveryHRVWindowSelection

    /// Builds an HRVSnapshot that clears the snapshot's intrinsic readiness
    /// gates (window ≥300s, RR gap ≤3s, confidence ≥0.75, cadence-scaled
    /// beats, successive differences). The selector separately preserves the
    /// saved-window minimum of 240 kept beats.
    private func intrinsicallyReadyRecoverySnapshot(kept: Int,
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

    func testRecoveryWindowPrefersFullyContainedQualifiedWindowInLastValidatedDeepSegment() {
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
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 250, confidence: 0.95, end: at(205)))
        // High-quality window over the EARLY deep segment.
        let earlyDeepCandidate = RecoverySelection.Candidate(
            start: at(65), end: at(70),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 245, confidence: 0.92, end: at(70)))
        // Lower-quality (but saved-window-qualified) candidate is fully inside
        // the LAST deep segment.
        let lastDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 240, confidence: 0.80, end: at(435)))
        let candidates = [remCandidate, earlyDeepCandidate, lastDeepCandidate]

        XCTAssertTrue(RecoverySelection.isFullyContained(lastDeepCandidate,
                                                         in: segments[2]))
        // With motion/integrity-validated staging the last-deep window wins even
        // though it is the lowest raw quality of the three.
        let selected = RecoverySelection.selectRecoveryWindow(candidates: candidates,
                                                              stageSegments: segments,
                                                              stageAuthorityIsMotionAndIntegrityValidated: true,
                                                              wakeEvent: wake)
        XCTAssertEqual(selected, lastDeepCandidate)
    }

    func testRecoveryWindowRejectsOneSecondPartialDeepOverlap() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)
        let deep = SleepStageSegment(id: "d2",
                                     start: at(420),
                                     end: at(455),
                                     stage: .deep)

        let fallbackCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 260, confidence: 0.95, end: at(205)))
        let partialStart = deep.end.addingTimeInterval(-1)
        let partialEnd = partialStart.addingTimeInterval(300)
        let oneSecondOverlapCandidate = RecoverySelection.Candidate(
            start: partialStart,
            end: partialEnd,
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 240, confidence: 0.80, end: partialEnd))

        XCTAssertTrue(oneSecondOverlapCandidate.isReady)
        XCTAssertFalse(RecoverySelection.isFullyContained(oneSecondOverlapCandidate,
                                                          in: deep))
        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [fallbackCandidate, oneSecondOverlapCandidate],
            stageSegments: [deep],
            stageAuthorityIsMotionAndIntegrityValidated: true,
            wakeEvent: wake)
        XCTAssertEqual(selected, fallbackCandidate,
                       "a one-second intersection must not become deep-stage authority")
    }

    func testRecoveryWindowFallsBackWhenStageAuthorityIsNotMotionAndIntegrityValidated() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)
        let deep = SleepStageSegment(id: "d2", start: at(420), end: at(455), stage: .deep)

        let fallbackCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 260, confidence: 0.95, end: at(205)))
        let containedDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 240, confidence: 0.80, end: at(435)))

        XCTAssertTrue(RecoverySelection.isFullyContained(containedDeepCandidate, in: deep))
        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [fallbackCandidate, containedDeepCandidate],
            stageSegments: [deep],
            stageAuthorityIsMotionAndIntegrityValidated: false,
            wakeEvent: wake)
        XCTAssertEqual(selected, fallbackCandidate)
    }

    func testRecoveryWindowFallsBackToQualityRuleWithoutStaging() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)

        let bestCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 250, confidence: 0.95, end: at(205)))
        let lowerQualityCandidate = RecoverySelection.Candidate(
            start: at(58), end: at(63),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 240, confidence: 0.92, end: at(63)))

        // HR-only night (no staging) -> current best-quality rule (most kept).
        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [bestCandidate, lowerQualityCandidate],
            stageSegments: [],
            stageAuthorityIsMotionAndIntegrityValidated: true,
            wakeEvent: wake)
        XCTAssertEqual(selected, bestCandidate)
    }

    func testRecoveryWindowRejectsCandidateBelowSavedWindowBeatGate() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
        let wake = at(480)
        let deep = SleepStageSegment(id: "d2", start: at(420), end: at(455), stage: .deep)

        let fallbackCandidate = RecoverySelection.Candidate(
            start: at(200), end: at(205),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 250, confidence: 0.95, end: at(205)))
        let insufficientBeatDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 160, confidence: 0.90, end: at(435)))

        XCTAssertTrue(insufficientBeatDeepCandidate.snapshot.isReady,
                      "fixture should isolate the stricter saved-window beat gate")
        XCTAssertFalse(insufficientBeatDeepCandidate.isReady)
        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [fallbackCandidate, insufficientBeatDeepCandidate],
            stageSegments: [deep],
            stageAuthorityIsMotionAndIntegrityValidated: true,
            wakeEvent: wake)
        XCTAssertEqual(selected, fallbackCandidate)
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
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 250, confidence: 0.95, end: at(205)))
        // The only window over the deep segment fails the RR-gap gate (>3s), so
        // qualification stays hard and selection falls back to the best ready
        // window overall.
        let unreadyDeepCandidate = RecoverySelection.Candidate(
            start: at(430), end: at(435),
            snapshot: intrinsicallyReadyRecoverySnapshot(
                kept: 240, confidence: 0.90, end: at(435), gap: 5))
        XCTAssertFalse(unreadyDeepCandidate.isReady)

        let selected = RecoverySelection.selectRecoveryWindow(
            candidates: [remCandidate, unreadyDeepCandidate],
            stageSegments: segments,
            stageAuthorityIsMotionAndIntegrityValidated: true,
            wakeEvent: wake)
        XCTAssertEqual(selected, remCandidate)
    }
}
