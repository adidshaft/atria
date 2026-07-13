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
                      timeZoneIdentifier: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return calendar.date(from: DateComponents(year: year,
                                                  month: month,
                                                  day: day,
                                                  hour: hour,
                                                  minute: minute))!
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

    private func candidates(_ sessions: [SavedSession], rest: Int = 50) -> [AggregateSleepCandidate] {
        SessionStore.aggregateSleepCandidates(in: sessions,
                                              rest: rest,
                                              maxHR: 190,
                                              calendar: Self.utcCalendar,
                                              historicalMotionPolicy: .boundedRecent)
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
                       "sleep_review_hr_only")
        XCTAssertEqual(SessionStore.autoSleepEventTimeZoneIdentifier(
            for: candidate,
            existingEventTimeZoneIdentifier: "Asia/Kolkata",
            fallbackIdentifier: "UTC"
        ), identifier)
    }

    func testDaytimeNapCandidateRemainsReviewOnly() throws {
        let quietDaytime = session(start: date(2032, 7, 3, 13, 0),
                                   end: date(2032, 7, 3, 13, 45),
                                   bpm: 52)
        let candidate = try XCTUnwrap(candidates([quietDaytime]).first)

        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
    }

    func testShortOvernightQuietAwakeWindowNeedsValidatedMotion() {
        let quietAwake = session(start: date(2032, 7, 3, 22, 18),
                                 end: date(2032, 7, 4, 2, 5),
                                 bpm: 52)

        XCTAssertTrue(candidates([quietAwake]).isEmpty,
                      "a 3h47 HR-only midnight window is quiet-awake ambiguous")
    }

    func testStableFiveHourHROnlyMainSleepRemainsReviewable() throws {
        let mainSleep = session(start: date(2032, 7, 4, 23, 0),
                                end: date(2032, 7, 5, 4, 30),
                                bpm: 52)

        let candidate = try XCTUnwrap(candidates([mainSleep]).first)
        XCTAssertEqual(candidate.kind, "overnight_sleep")
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertEqual(SessionStore.autoSleepClassification(for: candidate).source,
                       "sleep_review_hr_only")
    }
}
