import XCTest
@testable import Atria

final class AtriaSleepAuditRegressionTests: XCTestCase {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int,
                      _ month: Int,
                      _ day: Int,
                      _ hour: Int,
                      _ minute: Int = 0,
                      _ second: Int = 0,
                      timeZoneIdentifier: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(year: year,
                                                  month: month,
                                                  day: day,
                                                  hour: hour,
                                                  minute: minute,
                                                  second: second))!
    }

    private func session(start: Date,
                         end: Date,
                         bpm: Int = 52,
                         eventTimeZoneIdentifier: String? = "UTC",
                         motionValidated: Bool = false) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        var value = SavedSession(id: UUID(),
                                 start: start,
                                 end: end,
                                 label: "Sleep audit fixture",
                                 points: points,
                                 eventTimeZoneIdentifier: eventTimeZoneIdentifier)
        value.motionEvidenceValidated = motionValidated
        value.motionEvidenceSource = motionValidated ? "validated_strap_stillness" : nil
        return value
    }

    private func denseHRRRSession(start: Date,
                                  end: Date,
                                  bpm: Int = 65,
                                  eventTimeZoneIdentifier: String? = "UTC") -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 1.5).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        var value = SavedSession(id: UUID(),
                                 start: start,
                                 end: end,
                                 label: "Dense morning HR+RR fixture",
                                 points: points,
                                 eventTimeZoneIdentifier: eventTimeZoneIdentifier)
        value.rrPoints = points.map {
            SavedSession.RRPoint(t: $0.t, ms: Int((60_000.0 / Double(bpm)).rounded()))
        }
        return value
    }

    private func candidates(_ sessions: [SavedSession], rest: Int = 50) -> [AggregateSleepCandidate] {
        SessionStore.aggregateSleepCandidates(in: sessions,
                                              rest: rest,
                                              maxHR: 190,
                                              calendar: Self.utcCalendar,
                                              historicalMotionPolicy: .boundedRecent)
    }

    private var july26ReportedSleepSessionsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "evidence/2026-07-27-all-day-motion-default/settled/sessions.json"
            )
    }

    private func confirmedSleep(source: String,
                                start: Date,
                                end: Date,
                                eventTimeZoneIdentifier: String? = "UTC") -> UserConfirmedSleep {
        UserConfirmedSleep(id: "\(source)-\(Int(start.timeIntervalSince1970))",
                           createdAt: end,
                           start: start,
                           end: end,
                           source: source,
                           confidence: "test",
                           sessions: 1,
                           samples: 26,
                           avgHR: 52,
                           peakHR: 54,
                           restingHR: 50,
                           hrv: nil,
                           hrvWindowCount: nil,
                           duration: end.timeIntervalSince(start),
                           span: end.timeIntervalSince(start),
                           reason: "test",
                           motionSource: "test",
                           motionValidated: false,
                           stageSegments: nil,
                           eventTimeZoneIdentifier: eventTimeZoneIdentifier)
    }

    func testResumedOvernightSupersedesOverlappingAutoNapButNotUserSleep() throws {
        let first = session(start: date(2032, 1, 1, 23, 0),
                            end: date(2032, 1, 2, 1, 0),
                            motionValidated: true)
        let resumed = session(start: date(2032, 1, 2, 1, 30),
                              end: date(2032, 1, 2, 7, 0),
                              motionValidated: true)
        let candidate = try XCTUnwrap(candidates([first, resumed]).first)
        XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))

        let napStart = date(2032, 1, 2, 1, 2)
        let napEnd = date(2032, 1, 2, 1, 28)
        let autoNap = confirmedSleep(source: "auto_nap", start: napStart, end: napEnd)
        let insertionBase = try XCTUnwrap(SessionStore.sleepInsertionBase(existing: [autoNap],
                                                                          candidate: candidate))
        XCTAssertTrue(insertionBase.isEmpty, "the strong overnight should replace the overlapping auto nap")

        for source in ["manual_sleep", "manual_nap", "user_adjusted_sleep", "user_adjusted_nap"] {
            let userSleep = confirmedSleep(source: source, start: napStart, end: napEnd)
            XCTAssertNil(SessionStore.sleepInsertionBase(existing: [userSleep], candidate: candidate),
                         "\(source) must remain authoritative")
        }
    }

    func testFragmentsClusterAcrossMidnightBeforeWakeDayAssignment() throws {
        let beforeMidnight = session(start: date(2032, 2, 1, 23, 0),
                                     end: date(2032, 2, 1, 23, 45))
        let afterMidnight = session(start: date(2032, 2, 2, 0, 5),
                                    end: date(2032, 2, 2, 3, 5))

        let candidate = try XCTUnwrap(candidates([afterMidnight, beforeMidnight]).first)
        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertEqual(candidate.start, beforeMidnight.start)
        XCTAssertEqual(candidate.end, afterMidnight.end)
        XCTAssertEqual(candidate.day, Self.utcCalendar.startOfDay(for: afterMidnight.end))
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate),
                       "split HR-only evidence must remain a single review candidate, not auto-confirm")
    }

    func testFlatHighHRCannotDefineItsOwnAutoConfirmBaseline() throws {
        let highHR = session(start: date(2032, 3, 1, 23, 0),
                             end: date(2032, 3, 2, 5, 0),
                             bpm: 70)
        XCTAssertTrue(candidates([highHR], rest: 50).isEmpty,
                      "flat elevated HR must be rejected against the external resting baseline")
    }

    func testSingleContactSpikeDoesNotDiscardOvernightFragmentBeforeRobustClustering() throws {
        let start = date(2032, 3, 3, 3, 50)
        let end = date(2032, 3, 3, 8, 20)
        let duration = end.timeIntervalSince(start)
        var points = stride(from: 0.0, to: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: 54)
        }
        points[points.count / 2] = SavedSession.Point(t: points[points.count / 2].t,
                                                      bpm: 115)
        var artifactSession = SavedSession(id: UUID(),
                                           start: start,
                                           end: end,
                                           label: "Overnight with one contact spike",
                                           points: points,
                                           eventTimeZoneIdentifier: "UTC")
        artifactSession.motionEvidenceValidated = true
        artifactSession.motionEvidenceSource = "validated_strap_stillness"

        let candidate = try XCTUnwrap(candidates([artifactSession], rest: 58).first)
        XCTAssertEqual(candidate.peakHR, 115, "diagnostics should preserve the observed peak")
        XCTAssertLessThanOrEqual(candidate.hrP90, 62,
                                 "robust eligibility should reflect the sustained low-HR stream")
    }

    func testMainSleepAutoConfirmRejectsLongWholeSessionAndTokenCoreOverlap() throws {
        let longSession = session(start: date(2032, 4, 1, 19, 30),
                                  end: date(2032, 4, 2, 8, 0))
        let longCandidate = try XCTUnwrap(candidates([longSession]).first)
        XCTAssertEqual(longCandidate.span, 12.5 * 60 * 60, accuracy: 0.1)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(longCandidate))

        let tokenCore = session(start: date(2032, 4, 3, 20, 0),
                                end: date(2032, 4, 4, 1, 0))
        let tokenCoreCandidate = try XCTUnwrap(candidates([tokenCore]).first)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(tokenCoreCandidate),
                       "one hour inside the sleep core is not enough for whole-session auto-confirm")
    }

    func testEventTimezoneSurvivesAggregationClassificationAndSaveResolution() throws {
        let identifier = "America/Los_Angeles"
        let localNight = session(start: date(2032, 7, 1, 23, 0, timeZoneIdentifier: identifier),
                                 end: date(2032, 7, 2, 5, 0, timeZoneIdentifier: identifier),
                                 eventTimeZoneIdentifier: identifier)
        let candidate = try XCTUnwrap(candidates([localNight]).first)

        XCTAssertEqual(candidate.eventTimeZoneIdentifier, identifier)
        XCTAssertTrue(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate,
                                                                          calendar: Self.utcCalendar),
                      "classification must use event-local hours, not the supplied UTC fallback")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertEqual(SessionStore.autoSleepClassification(for: candidate).source,
                       "auto_confirmed_sleep_hr_only")
        XCTAssertEqual(SessionStore.autoSleepEventTimeZoneIdentifier(
            for: candidate,
            existingEventTimeZoneIdentifier: "Asia/Kolkata",
            fallbackIdentifier: "UTC"
        ), identifier)
    }

    func testDaytimeLowHRWithoutValidatedStillnessDoesNotBecomeNap() {
        let quietDaytime = session(start: date(2032, 7, 3, 13, 0),
                                   end: date(2032, 7, 3, 13, 45),
                                   bpm: 52)

        XCTAssertTrue(candidates([quietDaytime]).isEmpty,
                      "daytime HR alone cannot distinguish a nap from quiet or intermittently active wakefulness")
    }

    func testDaytimeNapWithValidatedStillnessRemainsReviewOnly() throws {
        let quietDaytime = session(start: date(2032, 7, 3, 13, 0),
                                   end: date(2032, 7, 3, 13, 45),
                                   bpm: 52,
                                   motionValidated: true)
        let candidate = try XCTUnwrap(candidates([quietDaytime]).first)

        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertTrue(candidate.motionEvidenceValidated)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
    }

    func testShortOvernightQuietAwakeWindowNeedsValidatedMotion() {
        let quietAwake = session(start: date(2032, 7, 3, 22, 18),
                                 end: date(2032, 7, 4, 2, 5),
                                 bpm: 52)

        XCTAssertTrue(candidates([quietAwake]).isEmpty,
                      "a 3h47 HR-only midnight window is quiet-awake ambiguous")
    }

    func testSevenSecondShortDenseMorningWindowSurfacesForReviewOnly() throws {
        // Physical 2026-07-15 shape: the journal closed seven seconds before
        // the exact three-hour boundary despite retaining dense HR and RR.
        let morningSleep = denseHRRRSession(
            start: date(2032, 7, 9, 6, 16, 3),
            end: date(2032, 7, 9, 9, 15, 56)
        )

        let candidate = try XCTUnwrap(candidates([morningSleep], rest: 55).first)
        XCTAssertEqual(candidate.duration, 3 * 60 * 60 - 7, accuracy: 0.1)
        XCTAssertTrue(candidate.denseMorningHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate),
                       "boundary tolerance must never auto-confirm or affect recovery before Save")

        let rollups = SessionStore.makeHistoryDailyRollups(sessions: [morningSleep],
                                                           detections: [],
                                                           confirmedWorkouts: [],
                                                           rest: 55,
                                                           maxHR: 190,
                                                           calendar: Self.utcCalendar)
        let rollup = try XCTUnwrap(rollups.first)
        XCTAssertEqual(rollup.sleepCandidates, 1,
                       "the review-only recovery must be visible in Activity Center")
        XCTAssertEqual(rollup.sleepReady, 0)
        XCTAssertEqual(rollup.sleepStart, morningSleep.start)
        XCTAssertEqual(rollup.sleepEnd, morningSleep.end)
    }

    func testDenseFourHourMorningWindowRemainsVisibleButCannotAutoConfirm() throws {
        // Regression for the old non-monotonic gate: the same evidence was
        // reviewable at 2h59m, disappeared at 3h, then returned at 5h.
        let morningSleep = denseHRRRSession(
            start: date(2032, 7, 9, 5, 51),
            end: date(2032, 7, 9, 9, 51)
        )

        let candidate = try XCTUnwrap(candidates([morningSleep], rest: 55).first)
        XCTAssertTrue(candidate.denseMorningHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ), "a sub-five-hour HR-only window must remain review-only even with a trusted baseline")
    }

    func testReportedJuly26SleepIsNotHiddenByShortPreludeAcrossLongAwakeGap() throws {
        // Physical report: the wearer woke from a 3–4 hour sleep. The durable
        // strap stream contains a dense low-HR/RR block from 07:22–11:32, but
        // the old two-hour cluster allowance attached an isolated 41-minute
        // low-HR fragment ending at 05:25. That 1h56 awake gap made the whole
        // aggregate too sparse and incorrectly removed the review card.
        let allSessions = try JSONDecoder().decode(
            [SavedSession].self,
            from: Data(contentsOf: july26ReportedSleepSessionsURL)
        )
        var ist = Calendar(identifier: .gregorian)
        ist.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Kolkata"))
        let july26 = allSessions.filter {
            ist.component(.year, from: $0.start) == 2026
                && ist.component(.month, from: $0.start) == 7
                && ist.component(.day, from: $0.start) == 26
        }

        let detected = candidates(july26, rest: 59)
        let candidate = try XCTUnwrap(detected.first {
            ist.component(.hour, from: $0.start) == 7
                && ist.component(.minute, from: $0.start) == 22
        })

        XCTAssertEqual(candidate.sessions, 4)
        XCTAssertEqual(candidate.duration, 4 * 60 * 60 + 10 * 60, accuracy: 90)
        XCTAssertTrue(candidate.denseMorningHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ), "recovered HR-only sleep must require wearer confirmation")
    }

    func testSubstantialBiphasicSleepStillCombinesAcrossLongWake() throws {
        // A meaningful first sleep must still combine with resumed sleep. This
        // preserves the user's requested WHOOP-style biphasic-night behavior;
        // only a short isolated prelude may be separated.
        var first = denseHRRRSession(
            start: date(2032, 7, 9, 0, 5),
            end: date(2032, 7, 9, 2, 5),
            bpm: 60
        )
        var resumed = denseHRRRSession(
            start: date(2032, 7, 9, 3, 50),
            end: date(2032, 7, 9, 7, 20),
            bpm: 60
        )
        first.motionEvidenceValidated = true
        first.motionEvidenceSource = "validated_strap_stillness"
        resumed.motionEvidenceValidated = true
        resumed.motionEvidenceSource = "validated_strap_stillness"

        let detected = candidates([first, resumed], rest: 59)
        let candidate = try XCTUnwrap(detected.first)
        XCTAssertEqual(detected.count, 1)
        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertEqual(candidate.start, first.start)
        XCTAssertEqual(candidate.end, resumed.end)
    }

    func testDenseMorningReviewRejectsGapBeyondSleepCredit() {
        let first = denseHRRRSession(
            start: date(2032, 7, 10, 7, 0),
            end: date(2032, 7, 10, 8, 30),
            bpm: 60
        )
        let resumed = denseHRRRSession(
            start: date(2032, 7, 10, 8, 51),
            end: date(2032, 7, 10, 10, 30),
            bpm: 60
        )

        XCTAssertTrue(candidates([first, resumed], rest: 59).isEmpty,
                      "a gap beyond the 20-minute sleep credit must remain missing evidence")
    }

    func testDenseMorningReviewRejectsAcceptedHRGapBeyondNinetySeconds() {
        var morningSleep = denseHRRRSession(
            start: date(2032, 7, 10, 6, 0),
            end: date(2032, 7, 10, 10, 0),
            bpm: 60
        )
        morningSleep.hrMaxAcceptedGap = 91

        XCTAssertTrue(candidates([morningSleep], rest: 59).isEmpty,
                      "a material accepted-HR outage must not be hidden by aggregate density")
    }

    func testDenseShiftedSleepWithVerifiedReconnectSeamSurfacesForReviewOnly() throws {
        // Physical 2026-07-23 shape: 10:05am–2:19pm sleep arrived in two
        // dense HR/RR journal sessions separated by a 4m21s reconnect seam,
        // with one 47.8s accepted-HR gap in the first session. This must be a
        // review card, but cannot alter recovery until the wearer saves it.
        let first = denseHRRRSession(
            start: date(2032, 7, 9, 10, 5),
            end: date(2032, 7, 9, 11, 15),
            bpm: 60
        )
        let resumed = denseHRRRSession(
            start: date(2032, 7, 9, 11, 19),
            end: date(2032, 7, 9, 14, 19),
            bpm: 60
        )

        let candidate = try XCTUnwrap(candidates([first, resumed], rest: 61).first)
        XCTAssertEqual(candidate.maximumHRSampleGap, 4 * 60, accuracy: 2)
        XCTAssertTrue(candidate.denseMorningHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testDenseOvernightSleepWithShortReconnectSeamSurfacesForReviewOnly() throws {
        // A verified long sleep may span a brief journal/reconnect seam. Dense
        // HR+RR remains eligible for a review card, but no-motion evidence can
        // never silently update recovery.
        let first = denseHRRRSession(
            start: date(2032, 7, 9, 2, 11),
            end: date(2032, 7, 9, 4, 44),
            bpm: 65
        )
        let resumed = denseHRRRSession(
            start: date(2032, 7, 9, 4, 49),
            end: date(2032, 7, 9, 7, 22),
            bpm: 65
        )

        let candidate = try XCTUnwrap(candidates([first, resumed], rest: 55).first)
        XCTAssertTrue(candidate.denseLongHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ), "a no-motion reconnect path must require the wearer's confirmation")
    }

    func testDenseShiftedSleepWithShortReconnectSeamSurfacesForReviewOnly() throws {
        // The same evidence must not disappear merely because the wearer sleeps
        // outside a conventional night window. This is still review-only.
        let first = denseHRRRSession(
            start: date(2032, 7, 9, 8, 0),
            end: date(2032, 7, 9, 10, 33),
            bpm: 65
        )
        let resumed = denseHRRRSession(
            start: date(2032, 7, 9, 10, 38),
            end: date(2032, 7, 9, 13, 11),
            bpm: 65
        )

        let candidate = try XCTUnwrap(candidates([first, resumed], rest: 55).first)
        XCTAssertTrue(candidate.denseLongHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testDenseMorningReviewSurvivesASeamlessReconnectSplit() throws {
        let first = denseHRRRSession(
            start: date(2032, 7, 10, 5, 51),
            end: date(2032, 7, 10, 7, 51)
        )
        let resumed = denseHRRRSession(
            start: date(2032, 7, 10, 7, 51, 10),
            end: date(2032, 7, 10, 10, 6)
        )

        let candidate = try XCTUnwrap(candidates([first, resumed], rest: 55).first)
        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertTrue(candidate.denseMorningHROnlyReviewQualified)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testMateriallyShortDenseMorningWindowRemainsRejected() {
        let shortMorningRest = denseHRRRSession(
            start: date(2032, 7, 10, 6, 16),
            end: date(2032, 7, 10, 9, 14)
        )

        XCTAssertTrue(candidates([shortMorningRest], rest: 55).isEmpty,
                      "dense evidence must not broadly lower the three-hour review threshold")
    }

    func testDenseHRRRDoesNotReviveReportedQuietAwakeFalseWindow() {
        let quietAwake = denseHRRRSession(
            start: date(2032, 7, 11, 22, 18),
            end: date(2032, 7, 12, 2, 5),
            bpm: 52
        )

        XCTAssertTrue(candidates([quietAwake], rest: 50).isEmpty,
                      "22:18–02:05 remains ambiguous quiet-awake even with dense HR and RR")
    }

    func testMotionValidatedQuietAwakeWindowRemainsDiagnosticOnly() throws {
        // Regression for the reported 10:18pm–2:05am false sleep. Sustained
        // stillness and low HR are still compatible with quiet TV/reading. A
        // sub-five-hour window with less than majority sleep-core overlap must
        // remain diagnostic-only: no Home card and no Activity Center row.
        let quietAwake = session(start: date(2032, 7, 3, 22, 18),
                                 end: date(2032, 7, 4, 2, 5),
                                 bpm: 52,
                                 motionValidated: true)
        let candidate = try XCTUnwrap(candidates([quietAwake]).first)
        XCTAssertTrue(candidate.motionEvidenceValidated)
        XCTAssertFalse(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertEqual(SessionStore.autoSleepClassification(for: candidate).source,
                       "sleep_review_motion_validated")

        let physiological = SessionStore.physiologicalSleepReviewNight(
            in: [quietAwake],
            rest: 50,
            calendar: Self.utcCalendar
        )
        XCTAssertNil(physiological,
                     "the five-minute fallback must not recreate a rejected quiet-awake window")

        let legacyDetection = try XCTUnwrap(quietAwake.detectedActivity(rest: 50,
                                                                        maxHR: 190,
                                                                        calendar: Self.utcCalendar))
        XCTAssertEqual(legacyDetection.kind, .sleepCandidate)
        let rollups = SessionStore.makeHistoryDailyRollups(sessions: [quietAwake],
                                                           detections: [legacyDetection],
                                                           confirmedWorkouts: [],
                                                           rest: 50,
                                                           maxHR: 190,
                                                           calendar: Self.utcCalendar)
        let wakeDay = Self.utcCalendar.startOfDay(for: quietAwake.end)
        let rollup = try XCTUnwrap(rollups.first { $0.day == wakeDay })
        XCTAssertEqual(rollup.sleepCandidates, 0)
        XCTAssertEqual(rollup.sleepReady, 0)
        XCTAssertNil(rollup.sleepStart)
        XCTAssertNil(rollup.sleepEnd)

        let sessionsSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/Sessions.swift"),
            encoding: .utf8
        )
        let liveStart = try XCTUnwrap(sessionsSource.range(of: "func dailyRollups("))
        let liveEnd = try XCTUnwrap(sessionsSource.range(of: "func aggregateWorkoutCandidates(",
                                                          range: liveStart.upperBound..<sessionsSource.endIndex))
        let liveRollups = String(sessionsSource[liveStart.lowerBound..<liveEnd.lowerBound])
        XCTAssertTrue(liveRollups.contains(".filter(Self.isReviewWorthySleepCandidate)"),
                      "Live rollups must not surface diagnostic-only sleep candidates")
    }

    func testReportedMorningResumptionMergesIntoOneMainSleep() throws {
        // Reported 2026-07-13 shape: first sleep 03:50–08:34, brief wake, then
        // sleep again until 11:38. The first fragment is not yet a full main
        // sleep, so the morning fragment must extend it rather than becoming a
        // separate nap merely because it starts after 08:00.
        let first = session(start: date(2032, 7, 8, 3, 50),
                            end: date(2032, 7, 8, 8, 34),
                            bpm: 52,
                            motionValidated: true)
        let resumed = session(start: date(2032, 7, 8, 8, 44),
                              end: date(2032, 7, 8, 11, 38),
                              bpm: 53,
                              motionValidated: true)

        let sleepCandidates = candidates([first, resumed])
        let candidate = try XCTUnwrap(sleepCandidates.first)
        XCTAssertEqual(sleepCandidates.count, 1)
        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertEqual(candidate.start, first.start)
        XCTAssertEqual(candidate.end, resumed.end)
        XCTAssertEqual(candidate.kind, "overnight_sleep")
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertTrue(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: false
        ), "validated motion remains sufficient without a mature resting-HR baseline")
    }

    func testMotionValidatedNightWithSustainedAwakeTailDoesNotAutoConfirm() throws {
        let start = date(2032, 7, 6, 22, 30)
        let end = date(2032, 7, 7, 5, 30)
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: $0 < 6 * 60 * 60 ? 52 : 92)
        }
        // Keep the fixture mutable to mirror the persisted sensor record.
        var awakeTail = SavedSession(id: UUID(),
                                     start: start,
                                     end: end,
                                     label: "Motionless night with awake tail",
                                     points: points,
                                     eventTimeZoneIdentifier: "UTC")
        awakeTail.motionEvidenceValidated = true
        awakeTail.motionEvidenceSource = "validated_strap_stillness"

        let candidate = try XCTUnwrap(candidates([awakeTail]).first)
        XCTAssertGreaterThanOrEqual(candidate.elevatedSampleFraction, 0.10)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
    }

    func testStableFiveHourHROnlyMainSleepCanAnchorWithoutMotion() throws {
        let mainSleep = session(start: date(2032, 7, 4, 23, 0),
                                end: date(2032, 7, 5, 4, 30),
                                bpm: 52)

        let candidate = try XCTUnwrap(candidates([mainSleep]).first)
        XCTAssertEqual(candidate.kind, "overnight_sleep")
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(candidate),
                       "HR-only sleep must fail closed without trusted resting-HR provenance")
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
        XCTAssertEqual(SessionStore.autoSleepClassification(for: candidate).source,
                       "auto_confirmed_sleep_hr_only")
    }

    func testStableShiftWorkerHROnlyMainSleepUsesPhysiologyNotClockTime() throws {
        let shiftSleep = session(start: date(2032, 7, 5, 9, 0),
                                 end: date(2032, 7, 5, 14, 30),
                                 bpm: 52)

        let candidate = try XCTUnwrap(candidates([shiftSleep]).first)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertTrue(SessionStore.isUnambiguousHROnlyMainSleepCandidate(
            candidate,
            calendar: Self.utcCalendar
        ))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ), "an identical trusted sleep physiology must not depend on wall-clock hour")
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: false
        ), "HR-only auto-confirm still requires a trusted personal resting baseline")

        let trustedRollup = try XCTUnwrap(SessionStore.makeHistoryDailyRollups(
            sessions: [shiftSleep],
            detections: [],
            confirmedWorkouts: [],
            baselineRestingIsTrusted: true,
            rest: 50,
            maxHR: 190,
            calendar: Self.utcCalendar
        ).first)
        XCTAssertEqual(trustedRollup.sleepReady, 1)

        let untrustedRollup = try XCTUnwrap(SessionStore.makeHistoryDailyRollups(
            sessions: [shiftSleep],
            detections: [],
            confirmedWorkouts: [],
            baselineRestingIsTrusted: false,
            rest: 50,
            maxHR: 190,
            calendar: Self.utcCalendar
        ).first)
        XCTAssertEqual(untrustedRollup.sleepReady, 0)
    }

    func testStableShiftWorkerSleepSurvivesThreeHourRetentionRollover() throws {
        let firstRetentionChunk = session(start: date(2032, 7, 5, 9, 0),
                                          end: date(2032, 7, 5, 12, 0),
                                          bpm: 52)
        let secondRetentionChunk = session(start: date(2032, 7, 5, 12, 0),
                                           end: date(2032, 7, 5, 14, 30),
                                           bpm: 52)

        let candidate = try XCTUnwrap(candidates([
            firstRetentionChunk,
            secondRetentionChunk
        ]).first)
        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertEqual(candidate.maxGap, 0, accuracy: 0.001)
        XCTAssertTrue(SessionStore.isUnambiguousHROnlyMainSleepCandidate(
            candidate,
            calendar: Self.utcCalendar
        ), "a storage-only rollover must not turn continuous shift-work sleep into fragmentation")
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testFragmentedShiftWorkerChunksRemainRejectedWithoutSleepCoreEvidence() {
        let firstFragment = session(start: date(2032, 7, 5, 9, 0),
                                    end: date(2032, 7, 5, 12, 0),
                                    bpm: 52)
        let secondFragment = session(start: date(2032, 7, 5, 13, 0),
                                     end: date(2032, 7, 5, 15, 30),
                                     bpm: 52)

        XCTAssertTrue(candidates([firstFragment, secondFragment]).isEmpty,
                      "a one-hour daytime evidence gap is not a storage-only rollover")
    }

    func testClusteredHRBurstCannotClaimWholeNightCoverage() throws {
        let start = date(2032, 7, 5, 23, 0)
        let end = date(2032, 7, 6, 5, 0)
        let points = stride(from: 0.0, through: 5 * 60.0, by: 1.0).map {
            SavedSession.Point(t: $0, bpm: 52)
        }
        var session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Clustered HR burst",
                                   points: points,
                                   eventTimeZoneIdentifier: "UTC")
        session.motionEvidenceValidated = true
        session.motionEvidenceSource = "validated_strap_stillness"

        let candidate = try XCTUnwrap(candidates([session]).first)
        XCTAssertLessThan(candidate.hrObservedCoverageFraction, 0.10)
        XCTAssertGreaterThan(candidate.maximumHRSampleGap, 5 * 60 * 60)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate))
    }

    func testLongSilentTailCannotBeAutoConfirmedAsObservedSleep() throws {
        let start = date(2032, 7, 6, 23, 0)
        let end = date(2032, 7, 7, 5, 0)
        let points = stride(from: 0.0, through: 60 * 60.0, by: 10.0).map {
            SavedSession.Point(t: $0, bpm: 52)
        }
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Silent HR tail",
                                   points: points,
                                   eventTimeZoneIdentifier: "UTC")

        let candidate = try XCTUnwrap(candidates([session]).first)
        XCTAssertLessThan(candidate.hrObservedCoverageFraction, 0.20)
        XCTAssertGreaterThan(candidate.maximumHRSampleGap, 4 * 60 * 60)
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(candidate))
    }

    func testReconnectFragmentsCanAnchorOnlyWithDenseStablePhysiology() throws {
        let first = session(start: date(2032, 7, 9, 23, 30),
                            end: date(2032, 7, 10, 2, 20),
                            bpm: 52)
        let second = session(start: date(2032, 7, 10, 2, 30),
                             end: date(2032, 7, 10, 5, 30),
                             bpm: 53)
        let candidate = try XCTUnwrap(candidates([first, second]).first)

        XCTAssertEqual(candidate.sessions, 2)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertTrue(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(candidate))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testThirtyNineSecondCrashTailGapDoesNotDiscardDenseHROvernightEvidence() throws {
        let start = date(2032, 7, 10, 23, 30)
        let end = date(2032, 7, 11, 5, 0)
        let duration = end.timeIntervalSince(start)
        let gapStart: TimeInterval = 2 * 60 * 60
        let gapEnd = gapStart + 39
        let points = stride(from: 0.0, to: duration, by: 5.0)
            .filter { $0 < gapStart || $0 >= gapEnd }
            .map { SavedSession.Point(t: $0, bpm: 52) }
        let journalProjection = SavedSession(id: UUID(),
                                             start: start,
                                             end: end,
                                             label: "Resident journal with crash tail gap",
                                             points: points,
                                             eventTimeZoneIdentifier: "UTC")

        let candidate = try XCTUnwrap(candidates([journalProjection]).first)
        XCTAssertGreaterThanOrEqual(candidate.maximumHRSampleGap, 39)
        XCTAssertLessThan(candidate.maximumHRSampleGap,
                          AggregateSleepCandidate.briefSleepGapCreditMax)
        XCTAssertGreaterThan(candidate.hrObservedCoverageFraction, 0.99)
        XCTAssertTrue(SessionStore.isUnambiguousHROnlyMainSleepCandidate(candidate))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
    }

    func testIntermittentRRLapsePreservesQualifiedWindowsBeforeAndAfterGap() {
        let start = date(2032, 7, 10, 23, 30)
        let runStarts: [TimeInterval] = [0, 475, 950]
        let rrPoints = runStarts.flatMap { runStart in
            (0...300).map { offset in
                SavedSession.RRPoint(t: runStart + TimeInterval(offset),
                                     ms: offset.isMultiple(of: 2) ? 980 : 1_020,
                                     source: .standardHeartRateMeasurement2A37)
            }
        }
        let end = start.addingTimeInterval(1_251)
        let session = SavedSession(id: UUID(),
                                   start: start,
                                   end: end,
                                   label: "Intermittent standard RR",
                                   points: [SavedSession.Point(t: 0, bpm: 60),
                                            SavedSession.Point(t: 1_250, bpm: 60)],
                                   rrPoints: rrPoints,
                                   eventTimeZoneIdentifier: "UTC")

        XCTAssertEqual(session.localHRVWindowCount, 3)
        XCTAssertNotNil(session.localRMSSD,
                        "a bounded RR lapse must split continuity, not erase qualified windows")
    }

    func testLongQuietWindowWithWakePhysiologyDoesNotAnchor() throws {
        let start = date(2032, 7, 11, 23, 0)
        let end = date(2032, 7, 12, 5, 30)
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 60.0).map {
            SavedSession.Point(t: $0, bpm: $0 < 4 * 60 * 60 ? 52 : 78)
        }
        let awake = SavedSession(id: UUID(),
                                 start: start,
                                 end: end,
                                 label: "Quiet awake tail",
                                 points: points,
                                 eventTimeZoneIdentifier: "UTC")
        XCTAssertTrue(candidates([awake]).isEmpty,
                      "a sustained wake-shaped tail must be rejected before automatic anchoring")
    }
}
