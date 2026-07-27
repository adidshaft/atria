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

        let seeded = SessionStore.seedRestingBaselineFromConfirmedSleepsIfNeeded(
            &baseline,
            confirmedSleeps: [nap]
        )

        XCTAssertEqual(seeded, 0)
        XCTAssertNil(baseline.restingInt)
        XCTAssertEqual(baseline.restingSampleCount, 0)
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
}
