import XCTest
@testable import Atria

final class AtriaSleepAuditRegressionTests: XCTestCase {
    // Time-anchored fixture replays (e.g. the July-26 reported-sleep capture)
    // run under `.boundedRecent`, whose onset clamp reads the device-use
    // journal from shared standard defaults. Whatever journal earlier suites
    // or previous runs persisted on this host/simulator silently clamps the
    // fixture's onset and shifts duration/session assertions — the exact
    // contamination class documented 2026-08-06. An empty journal is exact
    // identity with clamp-off, so reset before every test.
    override func setUp() {
        super.setUp()
        AtriaDeviceUseJournal.reset()
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let indiaCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
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
                         motionValidated: Bool = false,
                         qualifiedRR: Bool = false) -> SavedSession {
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
        // 2026-08-14 assessment P1.10: silent auto-confirmation now also
        // demands provenance-qualified RR coverage, so fixtures exercising
        // that gate opt into a dense 2A37 stream (~1 sample/second).
        if qualifiedRR {
            value.rrPoints = (0..<Int(duration)).map {
                SavedSession.RRPoint(t: Double($0),
                                     ms: Int((60_000.0 / Double(bpm)).rounded()),
                                     source: .standardHeartRateMeasurement2A37)
            }
        }
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

    private func physicalResumedSleepSession(start: Date,
                                             end: Date,
                                             activeTail: Bool = false) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 1.5).enumerated().map {
            index, offset -> SavedSession.Point in
            let bpm: Int
            if activeTail {
                bpm = index.isMultiple(of: 3) ? 108 : 92
            } else if index.isMultiple(of: 100) {
                bpm = 123
            } else if index.isMultiple(of: 25) {
                bpm = 94
            } else if index.isMultiple(of: 10) {
                bpm = 83
            } else {
                bpm = 65
            }
            return SavedSession.Point(t: offset, bpm: bpm)
        }
        let rrPoints = points.map {
            SavedSession.RRPoint(
                t: $0.t,
                ms: Int((60_000.0 / Double($0.bpm)).rounded()),
                source: .standardHeartRateMeasurement2A37
            )
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Physical resumed-sleep shape",
                            points: points,
                            rrPoints: rrPoints,
                            eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private func respiratoryRRSession(start: Date,
                                      end: Date,
                                      rrOffsets: [TimeInterval],
                                      breathsPerMinute: Double = 15,
                                      bpm: Int = 60,
                                      motionValidated: Bool = true) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let points = stride(from: 0.0, to: duration, by: 30.0).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        let rrPoints = rrOffsets.map { offset in
            let modulation = 70 * sin(2 * Double.pi * (breathsPerMinute / 60) * offset)
            return SavedSession.RRPoint(
                t: offset,
                ms: Int((900 + modulation).rounded()),
                source: .standardHeartRateMeasurement2A37
            )
        }
        var value = SavedSession(id: UUID(),
                                 start: start,
                                 end: end,
                                 label: "Respiratory sleep fixture",
                                 points: points,
                                 rrPoints: rrPoints,
                                 sleepWakeResearchState: "sleep_research",
                                 eventTimeZoneIdentifier: "UTC")
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

    func testDelayedTinyMorningFragmentCannotEraseCompletedMainSleep() throws {
        let first = denseHRRRSession(
            start: date(2032, 1, 2, 0, 45, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 3, 4, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 70,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let second = denseHRRRSession(
            start: date(2032, 1, 2, 3, 4, 1, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 4, 23, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 69,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let delayedTinyFragment = denseHRRRSession(
            start: date(2032, 1, 2, 5, 58, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 6, 4, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 70,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let laterQuietFragment = denseHRRRSession(
            start: date(2032, 1, 2, 6, 17, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 6, 39, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 61,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )

        let result = candidates([first, second, delayedTinyFragment, laterQuietFragment], rest: 60)
        let mainSleep = try XCTUnwrap(result.first)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(mainSleep.start, first.start)
        XCTAssertEqual(mainSleep.end, second.end)
        XCTAssertEqual(mainSleep.sessions, 2)
        XCTAssertEqual(mainSleep.duration, first.duration + second.duration + 1, accuracy: 1)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(mainSleep))
    }

    func testPhysicalRestlessOvernightFragmentsSurviveBeforeMotionProjection() throws {
        // Physical July 29 shape: the trusted long-term resting baseline was
        // 56 bpm, while two real low-motion sleep fragments averaged 77–78.
        // The former early filter discarded those fragments before the R10
        // stillness evidence could be evaluated, collapsing a 7h21m night into
        // "fragmented below minimum."
        func restlessSession(start: Date, end: Date, base: Int) -> SavedSession {
            let duration = end.timeIntervalSince(start)
            let points = stride(from: 0.0, to: duration, by: 1.5)
                .enumerated()
                .map { index, offset -> SavedSession.Point in
                    let bpm: Int
                    if index.isMultiple(of: 20) {
                        bpm = 100
                    } else if index.isMultiple(of: 5) {
                        bpm = 88
                    } else if index.isMultiple(of: 11) {
                        bpm = 65
                    } else {
                        bpm = base
                    }
                    return SavedSession.Point(t: offset, bpm: bpm)
                }
            var value = SavedSession(
                id: UUID(),
                start: start,
                end: end,
                label: "Validated restless overnight fragment",
                points: points,
                rrPoints: points.map {
                    SavedSession.RRPoint(
                        t: $0.t,
                        ms: Int((60_000.0 / Double($0.bpm)).rounded()),
                        source: .standardHeartRateMeasurement2A37
                    )
                },
                eventTimeZoneIdentifier: "Asia/Kolkata"
            )
            value.motionEvidenceValidated = false
            value.motionEvidenceSource = "unavailable"
            return value
        }

        let first = restlessSession(
            start: date(2032, 1, 1, 22, 52, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 1, 16, timeZoneIdentifier: "Asia/Kolkata"),
            base: 74
        )
        let second = restlessSession(
            start: date(2032, 1, 2, 1, 31, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 2, 52, timeZoneIdentifier: "Asia/Kolkata"),
            base: 71
        )
        let third = restlessSession(
            start: date(2032, 1, 2, 3, 14, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 4, 46, timeZoneIdentifier: "Asia/Kolkata"),
            base: 76
        )
        let final = restlessSession(
            start: date(2032, 1, 2, 5, 41, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 6, 14, timeZoneIdentifier: "Asia/Kolkata"),
            base: 65
        )

        let result = SessionStore.aggregateSleepCandidates(
            in: [first, second, third, final],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        )
        let candidate = try XCTUnwrap(result.first {
            $0.start == first.start && $0.end == final.end
        })

        XCTAssertEqual(candidate.sessions, 4)
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertTrue(SessionStore.isHighSpecificityFragmentedHROnlyMainSleepCandidate(candidate))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: true
        ))
        XCTAssertTrue(SessionStore.isAutoConfirmableMainSleepCandidate(
            candidate,
            baselineRestingIsTrusted: false,
            baselineRestingIsNearTrusted: true
        ), "a 13-day near-trusted baseline may admit only this strict fragmented-HR tier")

        let withoutTrustedBaseline = SessionStore.autoSleepClassification(
            for: candidate,
            baselineRestingIsTrusted: false,
            baselineRestingIsNearTrusted: false
        )
        XCTAssertEqual(withoutTrustedBaseline.source, "sleep_review_hr_only")
        XCTAssertEqual(withoutTrustedBaseline.confidence, "low")
        XCTAssertFalse(withoutTrustedBaseline.allowsAutomaticPersistence,
                       "review-only classification must never become a saved sleep")

        let withNearTrustedBaseline = SessionStore.autoSleepClassification(
            for: candidate,
            baselineRestingIsTrusted: false,
            baselineRestingIsNearTrusted: true
        )
        XCTAssertEqual(withNearTrustedBaseline.source, "auto_confirmed_sleep_hr_only")
        XCTAssertEqual(withNearTrustedBaseline.confidence, "provisional")
        XCTAssertTrue(withNearTrustedBaseline.allowsAutomaticPersistence,
                      "the persistence label must agree with the strict baseline-aware gate")
    }

    func testPhysicalMorningShapeQueuesSeparateResumedSleepAfterMainSettlement() throws {
        let first = denseHRRRSession(
            start: date(2032, 1, 2, 0, 45, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 3, 4, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 70,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let second = denseHRRRSession(
            start: date(2032, 1, 2, 3, 4, 1, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 4, 23, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 69,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let tiny = denseHRRRSession(
            start: date(2032, 1, 2, 5, 58, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 6, 4, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 70,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let ambiguous = denseHRRRSession(
            start: date(2032, 1, 2, 6, 17, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 6, 39, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 61,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let resumed = physicalResumedSleepSession(
            start: date(2032, 1, 2, 8, 33, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 10, 42, timeZoneIdentifier: "Asia/Kolkata")
        )
        let sessions = [first, second, tiny, ambiguous, resumed]
        let candidates = SessionStore.aggregateSleepCandidates(
            in: sessions,
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        )
        let main = try XCTUnwrap(candidates.first {
            $0.kind == "overnight_sleep" && $0.start == first.start
        })
        let tail = try XCTUnwrap(candidates.first {
            $0.kind == "resumed_sleep_candidate"
        })

        XCTAssertEqual(main.start, first.start)
        XCTAssertEqual(main.end, second.end)
        XCTAssertEqual(tail.start, resumed.start)
        XCTAssertEqual(tail.end, resumed.end)
        XCTAssertEqual(tail.duration, resumed.duration, accuracy: 1)
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            tail,
            baselineRestingIsTrusted: true
        ))

        let firstReview = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ))
        XCTAssertEqual(firstReview.start, first.start)
        XCTAssertEqual(firstReview.end, second.end)

        let confirmedMain = UserConfirmedSleep(
            id: "physical-main",
            createdAt: second.end,
            start: first.start,
            end: second.end,
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            sessions: 2,
            samples: first.points.count + second.points.count,
            avgHR: 70,
            peakHR: 70,
            restingHR: 60,
            hrv: 50,
            hrvWindowCount: 3,
            duration: first.duration + second.duration + 1,
            span: second.end.timeIntervalSince(first.start),
            reason: "physical main",
            motionSource: "user_review",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let queued = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [confirmedMain],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: first.start, end: second.end)
            ],
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ))
        XCTAssertEqual(queued.source, "resumed_sleep_candidate")
        XCTAssertEqual(queued.start, resumed.start)
        XCTAssertEqual(queued.end, resumed.end)

        let dismissedTail = SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [confirmedMain],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: first.start, end: second.end),
                AtriaDismissedSleepCandidate(start: resumed.start, end: resumed.end)
            ],
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar
        )
        XCTAssertNil(dismissedTail,
                     "the settled main may unlock the tail, but a dismissal of the tail itself remains final")
    }

    func testResumedSleepNeedsPriorMainAndRejectsActiveTail() {
        let quiet = physicalResumedSleepSession(
            start: date(2032, 1, 2, 8, 33, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 10, 42, timeZoneIdentifier: "Asia/Kolkata")
        )
        XCTAssertFalse(SessionStore.aggregateSleepCandidates(
            in: [quiet],
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        ).contains { $0.kind == "resumed_sleep_candidate" })

        let main = denseHRRRSession(
            start: date(2032, 1, 2, 0, 45, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 4, 23, timeZoneIdentifier: "Asia/Kolkata"),
            bpm: 69,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let active = physicalResumedSleepSession(
            start: date(2032, 1, 2, 8, 33, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 10, 42, timeZoneIdentifier: "Asia/Kolkata"),
            activeTail: true
        )
        XCTAssertFalse(SessionStore.aggregateSleepCandidates(
            in: [main, active],
            rest: 60,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        ).contains { $0.kind == "resumed_sleep_candidate" })
    }

    func testDenseHROnlyPostWakeWindowSurfacesAsSeparateReviewWithoutBridgingGap() throws {
        let mainStart = date(2032, 1, 1, 22, 52, 49, timeZoneIdentifier: "Asia/Kolkata")
        let mainEnd = date(2032, 1, 2, 6, 14, 37, timeZoneIdentifier: "Asia/Kolkata")
        let main = denseHRRRSession(
            start: mainStart,
            end: mainEnd,
            bpm: 61,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )

        // Exact physical July 29 journal shape: the resumed episode arrived in
        // two all-day-wear sessions separated by a 6m28s reconnect seam. The
        // first carried 4,126 accepted HR samples and one 81.86s accepted-HR
        // seam. The second carried 6,766 samples, stayed open after wake, then
        // recorded a sustained active transition beginning in the 14:35 bin.
        // None of its RR was reference-qualified and no motion was validated.
        let resumedStart = date(2032, 1, 2, 12, 19, 7, timeZoneIdentifier: "Asia/Kolkata")
        let firstEnd = date(2032, 1, 2, 13, 27, 23, timeZoneIdentifier: "Asia/Kolkata")
        let secondStart = date(2032, 1, 2, 13, 33, 51, timeZoneIdentifier: "Asia/Kolkata")
        let journalEnd = date(2032, 1, 2, 15, 28, 16, timeZoneIdentifier: "Asia/Kolkata")
        let wakeBoundary = date(2032, 1, 2, 14, 35, timeZoneIdentifier: "Asia/Kolkata")
        let quietAwakeStart = date(2032, 1, 2, 14, 55, timeZoneIdentifier: "Asia/Kolkata")
        let acceptedGap: TimeInterval = 81.85544097423553
        let acceptedGapStart: TimeInterval = 34 * 60
        let firstObservedSpan = firstEnd.timeIntervalSince(resumedStart) - acceptedGap
        let firstPoints = (0..<4_126).map { index -> SavedSession.Point in
            let observedOffset = firstObservedSpan * Double(index) / Double(4_125)
            let offset = observedOffset > acceptedGapStart
                ? observedOffset + acceptedGap
                : observedOffset
            let bpm: Int
            if index.isMultiple(of: 211) {
                bpm = 108
            } else if index.isMultiple(of: 17) {
                bpm = 69
            } else {
                bpm = 60
            }
            return SavedSession.Point(t: offset, bpm: bpm)
        }
        var firstAllDayWear = SavedSession(
            id: UUID(),
            start: resumedStart,
            end: firstEnd,
            label: "All-day wear",
            points: firstPoints,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        firstAllDayWear.hrMaxAcceptedGap = acceptedGap

        let secondDuration = journalEnd.timeIntervalSince(secondStart)
        let secondPoints = (0..<6_766).map { index -> SavedSession.Point in
            let offset = secondDuration * Double(index) / Double(6_765)
            let sampleDate = secondStart.addingTimeInterval(offset)
            let bpm: Int
            if sampleDate >= wakeBoundary && sampleDate < quietAwakeStart {
                bpm = index.isMultiple(of: 9) ? 124 : 95
            } else if sampleDate >= quietAwakeStart {
                bpm = index.isMultiple(of: 31) ? 78 : 61
            } else if index.isMultiple(of: 41) {
                bpm = 82
            } else {
                bpm = 60
            }
            return SavedSession.Point(t: offset, bpm: bpm)
        }
        let secondAllDayWear = SavedSession(
            id: UUID(),
            start: secondStart,
            end: journalEnd,
            label: "All-day wear",
            points: secondPoints,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )

        let sessions = [main, firstAllDayWear, secondAllDayWear]
        let candidates = SessionStore.aggregateSleepCandidates(
            in: sessions,
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        )
        let mainCandidate = try XCTUnwrap(candidates.first {
            $0.kind == "overnight_sleep"
        })
        let resumed = try XCTUnwrap(candidates.first {
            $0.kind == "resumed_sleep_candidate"
        })

        XCTAssertEqual(resumed.start, resumedStart)
        XCTAssertEqual(resumed.end, wakeBoundary)
        XCTAssertEqual(resumed.sessions, 2)
        XCTAssertEqual(
            resumed.duration,
            firstEnd.timeIntervalSince(resumedStart)
                + wakeBoundary.timeIntervalSince(secondStart),
            accuracy: 1,
            "the reconnect seam and post-wake quiet journal tail must receive zero sleep credit"
        )
        XCTAssertEqual(
            resumed.span - resumed.duration,
            secondStart.timeIntervalSince(firstEnd),
            accuracy: 1
        )
        XCTAssertEqual(resumed.maxGap, secondStart.timeIntervalSince(firstEnd), accuracy: 1)
        XCTAssertEqual(resumed.maximumHRSampleGap,
                       secondStart.timeIntervalSince(firstEnd),
                       accuracy: 2)
        XCTAssertGreaterThan(resumed.start.timeIntervalSince(mainCandidate.end), 6 * 60 * 60)
        XCTAssertEqual(resumed.motionEvidenceSource, "strap_hr_review_only")
        XCTAssertFalse(resumed.motionEvidenceValidated)
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
            resumed,
            baselineRestingIsTrusted: true
        ))
        XCTAssertFalse(SessionStore.autoSleepClassification(
            for: resumed,
            baselineRestingIsTrusted: true
        ).allowsAutomaticPersistence)

        let confirmedMain = UserConfirmedSleep(
            id: "physical-main",
            createdAt: mainEnd,
            start: mainStart,
            end: mainEnd,
            source: "sleep_window",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: main.points.count,
            avgHR: 61,
            peakHR: 61,
            restingHR: 56,
            hrv: 50,
            hrvWindowCount: 3,
            duration: main.duration,
            span: main.duration,
            reason: "confirmed after review",
            motionSource: "user_review",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        let review = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [confirmedMain],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: mainStart, end: mainEnd)
            ],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ))
        XCTAssertEqual(review.source, "resumed_sleep_candidate")
        XCTAssertEqual(review.start, resumedStart)
        XCTAssertEqual(review.end, wakeBoundary)
        XCTAssertEqual(review.duration, resumed.duration, accuracy: 1)
        XCTAssertFalse(review.confirmed)

        var unboundedGap = SavedSession(
            id: UUID(),
            start: resumedStart,
            end: firstEnd,
            label: "All-day wear",
            points: firstPoints,
            eventTimeZoneIdentifier: "Asia/Kolkata"
        )
        unboundedGap.hrMaxAcceptedGap = 91
        XCTAssertFalse(SessionStore.aggregateSleepCandidates(
            in: [main, unboundedGap],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        ).contains { $0.kind == "resumed_sleep_candidate" },
        "a resumed-sleep review may tolerate the physical 81.86s reconnect seam, but not a >90s accepted-HR outage")

        // Physical 2026-07-31 regression: the user dismissed the mis-bounded
        // overnight aggregate WITHOUT confirming any sleep. The distinct
        // late-morning resumed segment must still surface for review — a
        // dismissal settles one window, not the whole day.
        let dismissalOnlyReview = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: mainStart, end: mainEnd)
            ],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ), "dismissing the overnight window must not hide the distinct resumed-sleep review")
        XCTAssertEqual(dismissalOnlyReview.source, "resumed_sleep_candidate")
        XCTAssertEqual(dismissalOnlyReview.start, resumedStart)
        XCTAssertEqual(dismissalOnlyReview.end, wakeBoundary)
        XCTAssertFalse(dismissalOnlyReview.confirmed)

        // The dismissed window itself must stay suppressed: with no other
        // unsettled candidate on that day, the review is empty rather than
        // resurfacing the rejected overnight aggregate.
        XCTAssertNil(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: [main],
            confirmedSleeps: [],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: mainStart, end: mainEnd)
            ],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ), "a dismissed window with no distinct later evidence must not come back")
    }

    func testLongBiphasicMiddayResumedSleepIsRepresentableAcrossReconnectSeam() throws {
        // Physical 2026-07-31 magnitude: a late-morning biphasic sleep ran
        // ~4 h 26 m captured across one ~4.5-minute reconnect seam. The old
        // 3-hour resumed cap made that day's real sleep unrepresentable.
        // Anchoring here uses the wear-gap rule (strap charged after the main
        // wake); the continuous-wear anchor deliberately does not exist yet —
        // see the note at the separation guard in Sessions.swift.
        let tz = "Asia/Kolkata"
        let mainStart = date(2032, 1, 1, 21, 0, timeZoneIdentifier: tz)
        let mainEnd = date(2032, 1, 2, 5, 5, timeZoneIdentifier: tz)
        let main = denseHRRRSession(start: mainStart, end: mainEnd, bpm: 61,
                                    eventTimeZoneIdentifier: tz)
        let middayAStart = date(2032, 1, 2, 8, 39, 42, timeZoneIdentifier: tz)
        let middayAEnd = date(2032, 1, 2, 11, 11, 27, timeZoneIdentifier: tz)
        let middayBStart = date(2032, 1, 2, 11, 16, 7, timeZoneIdentifier: tz)
        let middayBEnd = date(2032, 1, 2, 13, 10, 0, timeZoneIdentifier: tz)
        let middayA = denseHRRRSession(start: middayAStart, end: middayAEnd,
                                       bpm: 60, eventTimeZoneIdentifier: tz)
        let middayB = denseHRRRSession(start: middayBStart, end: middayBEnd,
                                       bpm: 58, eventTimeZoneIdentifier: tz)

        let sessions = [main, middayA, middayB]
        let candidates = SessionStore.aggregateSleepCandidates(
            in: sessions,
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        )
        let resumed = try XCTUnwrap(
            candidates.first { $0.kind == "resumed_sleep_candidate" },
            "a wear-gap-anchored 4.5-hour biphasic episode must be representable"
        )
        XCTAssertEqual(resumed.start, middayAStart)
        XCTAssertEqual(resumed.sessions, 2)
        XCTAssertEqual(
            resumed.duration,
            middayAEnd.timeIntervalSince(middayAStart)
                + middayBEnd.timeIntervalSince(middayBStart),
            accuracy: 5,
            "both halves of the seam-split midday sleep must be represented"
        )
        XCTAssertFalse(resumed.motionEvidenceValidated)
        XCTAssertFalse(SessionStore.autoSleepClassification(
            for: resumed,
            baselineRestingIsTrusted: true
        ).allowsAutomaticPersistence,
        "a five-hour-class resumed episode remains review-only")

        // Dismissing the overnight window must still leave the midday block
        // reviewable (the 2026-07-31 dismissal fallback).
        let review = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(start: mainStart, end: mainEnd)
            ],
            rest: 56,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ))
        // The dense-morning tier may legitimately outrank the resumed
        // classification for the same window; either way the block must be
        // reviewable with its real bounds after the overnight dismissal.
        XCTAssertTrue(
            review.source == "resumed_sleep_candidate"
                || review.source == "aggregate_sleep",
            "unexpected review source \(review.source)"
        )
        XCTAssertEqual(review.start, middayAStart)
        XCTAssertFalse(review.confirmed)
    }

    func testDeferredRecoveredGenerationPublishesSyntheticSecondSleepAfterWakeFrontier()
        throws {
        typealias Coordinator = AtriaRecoveredDataRecomputeCoordinator
        let tz = "Asia/Kolkata"
        let firstStart = date(2032, 8, 11, 1, 1, 57,
                              timeZoneIdentifier: tz)
        let firstEnd = date(2032, 8, 11, 3, 17,
                            timeZoneIdentifier: tz)
        // Synthetic retained-authority fixture matching the independently
        // observed 10:53:25-13:53:25 shape. This unit test proves lifecycle
        // publication semantics only; physical proof remains exclusively in
        // the external acceptance harness.
        let laterStart = date(2032, 8, 11, 10, 53, 25,
                              timeZoneIdentifier: tz)
        let laterEnd = date(2032, 8, 11, 13, 53, 25,
                            timeZoneIdentifier: tz)
        let drainedThrough = date(2032, 8, 11, 15, 2, 1,
                                  timeZoneIdentifier: tz)
        XCTAssertGreaterThan(drainedThrough, laterEnd)

        let first = denseHRRRSession(
            start: firstStart,
            end: firstEnd,
            bpm: 61,
            eventTimeZoneIdentifier: tz
        )
        var later = physicalResumedSleepSession(
            start: laterStart,
            end: laterEnd
        )
        // The HR spike distribution exercises the review gate; it is not a
        // beat-to-beat RR model. Give this synthetic source independent,
        // provenance-qualified physiological variation so local RMSSD is
        // truthfully available while external-reference validation stays nil.
        let rrPattern = [900, 912, 896, 918, 904]
        later.rrPoints = later.points.enumerated().map { index, point in
            SavedSession.RRPoint(
                t: point.t,
                ms: rrPattern[index % rrPattern.count],
                source: .standardHeartRateMeasurement2A37
            )
        }
        let confirmedFirst = UserConfirmedSleep(
            id: "synthetic-aug11-first",
            createdAt: firstEnd,
            start: firstStart,
            end: firstEnd,
            source: "user_adjusted_sleep",
            confidence: "user_adjusted_hr_only",
            sessions: 1,
            samples: first.points.count,
            avgHR: 61,
            peakHR: 61,
            restingHR: 56,
            hrv: nil,
            hrvWindowCount: nil,
            duration: firstEnd.timeIntervalSince(firstStart),
            span: firstEnd.timeIntervalSince(firstStart),
            reason: "synthetic first episode",
            motionSource: "verified_historical_motion",
            motionValidated: true,
            stageSegments: nil,
            eventTimeZoneIdentifier: tz
        )
        XCTAssertTrue(
            SessionStore.confirmedSleepIsPhysiologicalMainSleep(confirmedFirst)
        )

        var coordinator = Coordinator(requiredComponents: [])
        let cutoff = Self.indiaCalendar.startOfDay(for: firstStart)
        let startEffects = coordinator.request(
            archiveRevision: 170,
            reason: "frontier_beyond_second_wake",
            scope: .automaticCurrentCycle(since: cutoff)
        )
        guard case let .startProjection(old) = startEffects.first else {
            return XCTFail("expected old projection")
        }
        XCTAssertEqual(
            coordinator.deferActiveUntilForeground(ticket: old),
            [.deferredUntilForeground(old)]
        )
        XCTAssertTrue(
            coordinator.projectionCompleted(ticket: old).isEmpty,
            "a cancelled generation may publish neither the old one-sleep image nor a partial second episode"
        )

        let freshEffects = coordinator.startDeferredForegroundRetry()
        guard case let .startProjection(fresh) = freshEffects.first else {
            return XCTFail("safe foreground must start one fresh generation")
        }
        XCTAssertGreaterThan(fresh.generation, old.generation)
        XCTAssertEqual(fresh.archiveRevision, old.archiveRevision)
        XCTAssertEqual(fresh.scope, old.scope)
        XCTAssertTrue(coordinator.startDeferredForegroundRetry().isEmpty)

        // The independently observed Atria resting authority for this window
        // is 62 bpm. Keep the production physiology gate unchanged and make
        // the synthetic fixture exercise that exact qualified path.
        let recoveredRestingHR = 62
        let recoveredCandidates = SessionStore.aggregateSleepCandidates(
            in: [first, later],
            rest: recoveredRestingHR,
            maxHR: 190,
            calendar: Self.indiaCalendar,
            historicalMotionPolicy: .sessionOnly
        )
        let laterCandidate = try XCTUnwrap(recoveredCandidates.first {
            $0.start == laterStart && $0.end == laterEnd
        })
        XCTAssertTrue(laterCandidate.denseMorningHROnlyReviewQualified)

        let review = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: [first, later],
            confirmedSleeps: [confirmedFirst],
            dismissedCandidates: [
                AtriaDismissedSleepCandidate(
                    start: firstStart,
                    end: firstEnd
                ),
            ],
            rest: recoveredRestingHR,
            maxHR: 190,
            calendar: Self.indiaCalendar
        ))
        XCTAssertEqual(review.start, laterStart)
        XCTAssertEqual(review.end, laterEnd)
        XCTAssertFalse(review.confirmed)

        let localResult = try XCTUnwrap(
            SessionStore.latestLocalRMSSDSourceCancellable(
                in: [later],
                shouldContinue: { true }
            )
        )
        let localHRV = try XCTUnwrap(localResult)
        XCTAssertGreaterThan(localHRV.value, 0)
        let referenceResult = try XCTUnwrap(
            SessionStore.latestReferenceValidatedHRVSourceCancellable(
                in: [later],
                shouldContinue: { true }
            )
        )
        XCTAssertNil(
            referenceResult,
            "unvalidated reference HRV must remain an explicit blocker instead of borrowing Aug 10"
        )

        // The later episode is review-only until the user confirms it. A
        // successful fresh lifecycle generation may surface that review, but
        // it must keep every nightly biomarker on its own qualified authority:
        // the confirmed first episode supplies RHR, while absent/unvalidated
        // HRV, respiration, SpO2 and skin temperature stay absent. A prior
        // night's values remain on that prior day and are never copied forward.
        let sleepSnapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [confirmedFirst],
            dismissedCandidates: [],
            calendar: Self.indiaCalendar
        )
        let currentMetrics = SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: sleepSnapshot,
            baseline: PersonalBaseline(),
            sessions: [first, later],
            skinTemperatureDeviationByDay: [:],
            calendar: Self.indiaCalendar
        )
        let currentDay = Self.indiaCalendar.startOfDay(for: firstEnd)
        let currentMetric = try XCTUnwrap(currentMetrics.first {
            Self.indiaCalendar.isDate($0.day, inSameDayAs: currentDay)
        })
        XCTAssertEqual(currentMetric.restingHR, confirmedFirst.restingHR)
        XCTAssertNil(currentMetric.hrv)
        XCTAssertNil(currentMetric.respiratoryRate)
        XCTAssertNil(currentMetric.skinTemperatureDeviationCelsius)
        XCTAssertFalse(AtriaResearchProbe.validatedSpO2DecoderAvailable)
        XCTAssertFalse(
            AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable
        )

        let priorDay = Self.indiaCalendar.date(
            byAdding: .day,
            value: -1,
            to: currentDay
        )!
        let priorMetric = SavedDailyMetric(
            day: priorDay,
            recoveryPercent: 64,
            recoveryConfidence: "fixture_prior_night",
            hrv: 47,
            restingHR: 58,
            respiratoryRate: 14.4,
            sleepDuration: 7 * 3_600,
            sleepSpan: 7.5 * 3_600,
            sleepStart: priorDay,
            sleepEnd: priorDay.addingTimeInterval(7 * 3_600),
            sleepSource: "fixture_prior_night",
            sleepStageSegments: [],
            sleepConsistencyPercent: nil,
            strain: nil,
            skinTemperatureDeviationCelsius: 0.2
        )
        let mergedMetrics = SessionStore.mergeDailyMetricHistory(
            existing: [priorMetric],
            computed: currentMetrics,
            sessions: [first, later],
            sleep: sleepSnapshot,
            baseline: PersonalBaseline(),
            maxHR: 190,
            now: drainedThrough,
            skinTemperatureDeviationByDay: [:],
            skinTemperatureSourceValidated: false,
            authoritativeDays: [currentDay],
            calendar: Self.indiaCalendar
        )
        let freshDay = try XCTUnwrap(mergedMetrics.first {
            Self.indiaCalendar.isDate($0.day, inSameDayAs: currentDay)
        })
        XCTAssertEqual(freshDay.restingHR, confirmedFirst.restingHR)
        XCTAssertNil(freshDay.hrv, "must not borrow prior-night HRV")
        XCTAssertNil(freshDay.respiratoryRate,
                     "must not borrow prior-night respiration")
        XCTAssertNil(freshDay.skinTemperatureDeviationCelsius,
                     "must not borrow prior-night skin deviation")
        XCTAssertTrue(mergedMetrics.contains { $0 == priorMetric })

        XCTAssertEqual(
            coordinator.projectionCompleted(ticket: fresh),
            [.startDerived(fresh, [.currentCycleAndLatestNight])]
        )
        XCTAssertTrue(coordinator.projectionCompleted(ticket: fresh).isEmpty)
        XCTAssertEqual(
            coordinator.componentCompleted(
                ticket: fresh,
                component: .currentCycleAndLatestNight
            ),
            [.publish(fresh)]
        )
        XCTAssertTrue(
            coordinator.componentCompleted(
                ticket: fresh,
                component: .currentCycleAndLatestNight
            ).isEmpty
        )
    }

    func testConfirmedResumedSleepAddsOnlyObservedDurationToCycle() throws {
        let mainStart = date(2032, 1, 2, 0, 45, timeZoneIdentifier: "Asia/Kolkata")
        let mainEnd = date(2032, 1, 2, 4, 23, timeZoneIdentifier: "Asia/Kolkata")
        let resumedStart = date(2032, 1, 2, 8, 33, timeZoneIdentifier: "Asia/Kolkata")
        let resumedEnd = date(2032, 1, 2, 10, 42, timeZoneIdentifier: "Asia/Kolkata")
        func confirmed(id: String,
                       start: Date,
                       end: Date,
                       source: String,
                       restingHR: Int,
                       hrv: Int,
                       respiratoryRate: Double) -> UserConfirmedSleep {
            UserConfirmedSleep(
                id: id,
                createdAt: end,
                start: start,
                end: end,
                source: source,
                confidence: "user_confirmed_hr_only",
                sessions: 1,
                samples: 1_000,
                avgHR: 65,
                peakHR: 83,
                restingHR: restingHR,
                hrv: hrv,
                hrvWindowCount: 3,
                respiratoryRate: respiratoryRate,
                duration: end.timeIntervalSince(start),
                span: end.timeIntervalSince(start),
                reason: "test",
                motionSource: "user_review",
                motionValidated: false,
                stageSegments: nil,
                eventTimeZoneIdentifier: "Asia/Kolkata"
            )
        }
        let main = confirmed(id: "main",
                             start: mainStart,
                             end: mainEnd,
                             source: "sleep_window",
                             restingHR: 63,
                             hrv: 42,
                             respiratoryRate: 15.8)
        let resumed = confirmed(
            id: "resumed",
            start: resumedStart,
            end: resumedEnd,
            source: "resumed_sleep",
            restingHR: 58,
            hrv: 65,
            respiratoryRate: 14.9
        )
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [main, resumed],
            calendar: Self.indiaCalendar
        )
        let combined = try XCTUnwrap(snapshot.latestMainSleep)

        XCTAssertEqual(combined.start, mainStart)
        XCTAssertEqual(combined.end, resumedEnd)
        XCTAssertEqual(
            combined.duration,
            main.duration + resumed.duration,
            accuracy: 1,
            "04:23–08:33 must remain awake and receive zero sleep credit"
        )
        XCTAssertEqual(
            combined.observedDuration,
            main.duration + resumed.duration,
            accuracy: 1,
            "resumed projection must preserve measured coverage separately from staged TST"
        )
        XCTAssertEqual(
            combined.sleepEfficiency ?? 0,
            (main.duration + resumed.duration) / resumedEnd.timeIntervalSince(mainStart),
            accuracy: 0.001
        )
        XCTAssertEqual(snapshot.additionalMainNights.map(\.id), ["resumed"])
        XCTAssertEqual(combined.hrvWindowCount, 6)
        XCTAssertGreaterThan(try XCTUnwrap(combined.hrv), main.hrv ?? 0)
        XCTAssertLessThan(try XCTUnwrap(combined.restingHR), main.restingHR)
        XCTAssertLessThan(try XCTUnwrap(combined.respiratoryRate),
                          main.respiratoryRate ?? .infinity)
    }

    func testResumedNightCombinationPreservesObservedCoverageSeparateFromTST() throws {
        let mainStart = date(2032, 1, 2, 0, 0, timeZoneIdentifier: "Asia/Kolkata")
        let mainEnd = mainStart.addingTimeInterval(3 * 60 * 60)
        let resumedStart = mainEnd.addingTimeInterval(2 * 60 * 60)
        let resumedEnd = resumedStart.addingTimeInterval(90 * 60)
        func night(id: String,
                   start: Date,
                   end: Date,
                   source: String,
                   tst: TimeInterval,
                   observed: TimeInterval) -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(
                id: id,
                day: Self.indiaCalendar.startOfDay(for: end),
                savedAt: end,
                start: start,
                end: end,
                duration: tst,
                observedDuration: observed,
                restingHR: 55,
                hrv: 45,
                hrvWindowCount: 3,
                respiratoryRate: 15,
                sleepEfficiency: tst / end.timeIntervalSince(start),
                confidence: "user_confirmed_hr_only",
                source: source,
                confirmed: true,
                stageSegments: [],
                eventTimeZoneIdentifier: "Asia/Kolkata",
                motionValidated: false
            )
        }
        let main = night(id: "main-observed",
                         start: mainStart,
                         end: mainEnd,
                         source: "user_adjusted_sleep",
                         tst: 2 * 60 * 60,
                         observed: 3 * 60 * 60)
        let resumed = night(id: "resumed-observed",
                            start: resumedStart,
                            end: resumedEnd,
                            source: "resumed_sleep",
                            tst: 60 * 60,
                            observed: 90 * 60)

        let combined = try XCTUnwrap(SleepHistorySnapshot.combiningResumedSleepSegments(
            main: main,
            resumed: [resumed]
        ))

        XCTAssertEqual(combined.duration, 3 * 60 * 60)
        XCTAssertEqual(combined.observedDuration, 4.5 * 60 * 60)
        XCTAssertEqual(combined.end, resumedEnd)
    }

    func testResumedSleepCannotPromoteSubPolicyMainIntoRecoveryOnlyNight() throws {
        let start = date(2032, 1, 2, 0, timeZoneIdentifier: "Asia/Kolkata")
        func confirmed(id: String,
                       start: Date,
                       end: Date,
                       source: String) -> UserConfirmedSleep {
            UserConfirmedSleep(
                id: id,
                createdAt: end,
                start: start,
                end: end,
                source: source,
                confidence: "user_confirmed_hr_only",
                sessions: 1,
                samples: 1_000,
                avgHR: 60,
                peakHR: 75,
                restingHR: 55,
                hrv: 45,
                hrvWindowCount: 3,
                respiratoryRate: 15,
                duration: end.timeIntervalSince(start),
                span: end.timeIntervalSince(start),
                reason: "resumed parity regression",
                motionSource: "test",
                motionValidated: false,
                stageSegments: nil,
                eventTimeZoneIdentifier: "Asia/Kolkata"
            )
        }
        let shortMain = confirmed(id: "short-manual-main",
                                  start: start,
                                  end: start.addingTimeInterval(2 * 60 * 60),
                                  source: "manual_sleep")
        let resumed = confirmed(id: "short-main-resumed",
                                start: start.addingTimeInterval(3 * 60 * 60),
                                end: start.addingTimeInterval(5 * 60 * 60),
                                source: "resumed_sleep")
        let now = start.addingTimeInterval(6 * 60 * 60)
        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [shortMain, resumed],
            calendar: Self.indiaCalendar
        )
        let projectedMain = try XCTUnwrap(snapshot.nights.first { $0.id == shortMain.id })
        let projectedResumed = try XCTUnwrap(
            snapshot.additionalMainNights.first { $0.id == resumed.id }
        )

        XCTAssertFalse(SessionStore.confirmedSleepIsPhysiologicalMainSleep(shortMain))
        XCTAssertNil(SleepHistorySnapshot.combiningResumedSleepSegments(
            main: projectedMain,
            resumed: [projectedResumed]
        ))
        XCTAssertEqual(snapshot.latestMainSleep?.end, shortMain.end,
                       "resumed sleep cannot rescue an ineligible main into a recovery night")
        XCTAssertTrue(SessionStore.makeSavedDailyMetrics(
            rollups: [],
            sleep: snapshot,
            baseline: PersonalBaseline(),
            calendar: Self.indiaCalendar
        ).isEmpty)

        let direct = AtriaPhysiologicalDay.current(
            now: now,
            confirmedSleeps: [shortMain, resumed],
            calendar: Self.indiaCalendar
        )
        let projected = AtriaPhysiologicalDay.current(
            now: now,
            sleepHistory: snapshot,
            calendar: Self.indiaCalendar
        )
        XCTAssertEqual(projected, direct,
                       "Recovery projection and Today ownership must share main-sleep eligibility")
    }

    func testResumedSleepLinksAcrossCivilMidnightByInterval() throws {
        func confirmed(id: String,
                       start: Date,
                       end: Date,
                       source: String) -> UserConfirmedSleep {
            UserConfirmedSleep(
                id: id,
                createdAt: end,
                start: start,
                end: end,
                source: source,
                confidence: "user_confirmed_hr_only",
                sessions: 1,
                samples: 1_000,
                avgHR: 60,
                peakHR: 80,
                restingHR: 55,
                hrv: 50,
                hrvWindowCount: 3,
                respiratoryRate: 15,
                duration: end.timeIntervalSince(start),
                span: end.timeIntervalSince(start),
                reason: "test",
                motionSource: "user_review",
                motionValidated: false,
                stageSegments: nil,
                eventTimeZoneIdentifier: "Asia/Kolkata"
            )
        }
        let main = confirmed(
            id: "main-cross-day",
            start: date(2032, 1, 2, 19, 40, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 2, 23, 40, timeZoneIdentifier: "Asia/Kolkata"),
            source: "sleep_window"
        )
        let resumed = confirmed(
            id: "resumed-cross-day",
            start: date(2032, 1, 2, 23, 55, timeZoneIdentifier: "Asia/Kolkata"),
            end: date(2032, 1, 3, 0, 35, timeZoneIdentifier: "Asia/Kolkata"),
            source: "resumed_sleep"
        )

        let snapshot = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [main, resumed],
            calendar: Self.indiaCalendar
        )
        let combined = try XCTUnwrap(snapshot.latestMainSleep)
        XCTAssertEqual(combined.id, main.id)
        XCTAssertEqual(combined.end, resumed.end)
        XCTAssertEqual(combined.duration,
                       main.duration + resumed.duration,
                       accuracy: 1)
    }

    @MainActor
    func testConfirmingResumedSleepPersistsASeparateSegmentAndKeepsMain() async throws {
        let store = SessionStore()
        let mainStart = date(2036, 1, 2, 0, 45, timeZoneIdentifier: "Asia/Kolkata")
        let mainEnd = date(2036, 1, 2, 4, 23, timeZoneIdentifier: "Asia/Kolkata")
        let resumedStart = date(2036, 1, 2, 8, 33, timeZoneIdentifier: "Asia/Kolkata")
        let resumedEnd = date(2036, 1, 2, 10, 42, timeZoneIdentifier: "Asia/Kolkata")

        func review(id: String,
                    start: Date,
                    end: Date,
                    source: String) -> SleepHistorySnapshot.Night {
            SleepHistorySnapshot.Night(
                id: id,
                day: Self.indiaCalendar.startOfDay(for: end),
                start: start,
                end: end,
                duration: end.timeIntervalSince(start),
                restingHR: 59,
                hrv: 50,
                hrvWindowCount: 3,
                respiratoryRate: 15,
                sleepEfficiency: 1,
                confidence: "review_needed",
                source: source,
                confirmed: false,
                stageSegments: [],
                eventTimeZoneIdentifier: "Asia/Kolkata"
            )
        }

        let mainResult = await store.saveSleepReviewNightForUI(
            review(id: "main-review",
                   start: mainStart,
                   end: mainEnd,
                   source: "sleep_window"),
            start: mainStart,
            end: mainEnd,
            isNap: false,
            rest: 60,
            source: "test-main"
        )
        let main = try XCTUnwrap(mainResult)
        defer { Task { @MainActor in _ = await store.deleteConfirmedSleep(id: main.id) } }

        let resumedResult = await store.saveSleepReviewNightForUI(
            review(id: "resumed-review",
                   start: resumedStart,
                   end: resumedEnd,
                   source: "resumed_sleep_candidate"),
            start: resumedStart,
            end: resumedEnd,
            isNap: false,
            rest: 60,
            source: "test-resumed"
        )
        let resumed = try XCTUnwrap(resumedResult)
        defer { Task { @MainActor in _ = await store.deleteConfirmedSleep(id: resumed.id) } }

        XCTAssertEqual(resumed.source, "resumed_sleep")
        XCTAssertEqual(resumed.start, resumedStart)
        XCTAssertEqual(resumed.end, resumedEnd)
        XCTAssertEqual(resumed.duration, resumedEnd.timeIntervalSince(resumedStart), accuracy: 1)
        XCTAssertEqual(resumed.span, resumed.duration, accuracy: 1)

        let durableMain = try XCTUnwrap(store.confirmedSleeps.first { $0.id == main.id })
        let durableResumed = try XCTUnwrap(store.confirmedSleeps.first { $0.id == resumed.id })
        XCTAssertEqual(durableMain.start, mainStart)
        XCTAssertEqual(durableMain.end, mainEnd)
        XCTAssertEqual(durableResumed.start, resumedStart)
        XCTAssertEqual(durableResumed.end, resumedEnd)
        XCTAssertNotEqual(durableMain.id, durableResumed.id)

        // Other tests intentionally persist future-dated sleeps in the shared
        // simulator container. Scope this projection to the two records created
        // above so the regression proves resumed-sleep semantics rather than
        // whichever unrelated fixture has the latest date.
        let projected = try XCTUnwrap(
            SleepHistorySnapshot(
                rollups: [],
                confirmedSleeps: store.confirmedSleeps.filter {
                    $0.id == main.id || $0.id == resumed.id
                },
                calendar: Self.indiaCalendar
            ).latestMainSleep
        )
        XCTAssertEqual(projected.start, mainStart)
        XCTAssertEqual(projected.end, resumedEnd)
        XCTAssertEqual(
            projected.duration,
            main.duration + resumed.duration,
            accuracy: 1,
            "the 04:23–08:33 awake interval must remain zero-credit"
        )
    }

    func testSleepWindowRespirationAggregatesFragmentedOverlappingQualifiedRuns() throws {
        let sleepStart = date(2032, 1, 2, 0, 0)
        let sleepEnd = date(2032, 1, 2, 3, 30)
        let firstOffsets = stride(from: 0.0, through: 85.0, by: 0.9).map { $0 }
        let secondOffsets = stride(from: 0.0, through: 85.0, by: 0.9).map { $0 }
        let first = respiratoryRRSession(start: sleepStart,
                                         end: sleepEnd,
                                         rrOffsets: firstOffsets)
        let overlapping = respiratoryRRSession(
            start: sleepStart.addingTimeInterval(70),
            end: sleepEnd,
            rrOffsets: secondOffsets
        )

        let rate = try XCTUnwrap(SessionStore.confirmedSleepRespiratoryRate(
            from: [first, overlapping],
            start: sleepStart,
            end: sleepEnd
        ))
        XCTAssertEqual(rate, 15, accuracy: 1)

        let review = try XCTUnwrap(SessionStore.makeSleepReviewNightForCache(
            snapshot: .empty,
            canonicalSessions: [first, overlapping],
            confirmedSleeps: [],
            rest: 60,
            maxHR: 190,
            calendar: Self.utcCalendar
        ))
        XCTAssertEqual(try XCTUnwrap(review.respiratoryRate), 15, accuracy: 1)
    }

    func testSleepWindowRespirationRejectsRunsSeparatedByMoreThanThreeSeconds() {
        let start = date(2032, 1, 2, 0, 0)
        let first = stride(from: 0.0, through: 38.0, by: 0.9).map { $0 }
        let secondStart = (first.last ?? 0) + 4
        let second = stride(from: secondStart, through: secondStart + 38, by: 0.9).map { $0 }
        let session = respiratoryRRSession(
            start: start,
            end: start.addingTimeInterval(second.last ?? 80),
            rrOffsets: first + second
        )

        XCTAssertNil(SessionStore.confirmedSleepRespiratoryRate(
            from: [session],
            start: start,
            end: session.end
        ), "two sub-45-second runs must not be bridged across a >3-second RR hole")
    }

    func testConfirmedSleepRespirationPersistsProjectsAndLegacyDecodeStaysNil() throws {
        let start = date(2032, 1, 2, 0, 0)
        let end = date(2032, 1, 2, 6, 0)
        let sleep = UserConfirmedSleep(
            id: "respiratory-persistence",
            createdAt: end,
            start: start,
            end: end,
            source: "sleep_window",
            confidence: "user_confirmed_motion_validated",
            sessions: 2,
            samples: 1_000,
            avgHR: 62,
            peakHR: 74,
            restingHR: 58,
            hrv: 55,
            hrvWindowCount: 3,
            respiratoryRate: 14.5,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: "test",
            motionSource: "user_review_validated",
            motionValidated: true,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )

        let encoded = try JSONEncoder().encode(sleep)
        let decoded = try JSONDecoder().decode(UserConfirmedSleep.self, from: encoded)
        XCTAssertEqual(decoded.respiratoryRate, 14.5)
        let projected = SleepHistorySnapshot(
            rollups: [],
            confirmedSleeps: [decoded],
            calendar: Self.utcCalendar
        )
        XCTAssertEqual(projected.latestMainSleep?.respiratoryRate, 14.5)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "respiratoryRate")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(UserConfirmedSleep.self, from: legacyData)
        XCTAssertNil(legacy.respiratoryRate)
    }

    func testRespirationOnlyRequalificationInvalidatesConfirmedSleepWakeDay() throws {
        let start = date(2032, 1, 2, 0, 0)
        let end = date(2032, 1, 2, 3, 30)
        let rrOffsets = stride(from: 0.0, through: 90.0, by: 0.9).map { $0 }
        let session = respiratoryRRSession(
            start: start,
            end: end,
            rrOffsets: rrOffsets
        )
        let legacy = UserConfirmedSleep(
            id: "legacy-respiration-migration",
            createdAt: end,
            start: start,
            end: end,
            source: "overnight_sleep",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: session.points.count,
            avgHR: session.avg,
            peakHR: session.peak,
            restingHR: session.restingStable,
            hrv: nil,
            hrvWindowCount: 0,
            respiratoryRate: nil,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: "legacy row",
            motionSource: "user_review",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        )

        let migrated = try XCTUnwrap(
            SessionStore.requalifiedConfirmedSleepHRVRecords(
                [legacy],
                sessions: [session]
            ).first
        )

        XCTAssertEqual(migrated.hrv, legacy.hrv)
        XCTAssertEqual(migrated.hrvWindowCount, legacy.hrvWindowCount)
        XCTAssertNotNil(migrated.respiratoryRate)
        XCTAssertTrue(SessionStore.confirmedSleepQualifiedMetricsChanged(
            previous: legacy,
            next: migrated
        ), "a respiration-only migration must reach persistence and day invalidation")
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
                            motionValidated: true,
                            qualifiedRR: true)
        let resumed = session(start: date(2032, 1, 2, 1, 30),
                              end: date(2032, 1, 2, 7, 0),
                              motionValidated: true,
                              qualifiedRR: true)
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

    func testDaytimeLowHRWithoutValidatedStillnessStaysReviewOnly() throws {
        // 2026-08-29 clock-agnostic nap fix: an HR-only nap above the stricter
        // review bar (avg <= rest+12, P90 <= rest+30, >= 30 min) surfaces for
        // wearer review instead of dying on lagging motion offload. Daytime HR
        // alone still cannot CONFIRM a nap: the candidate stays unvalidated,
        // low-confidence, and outside every auto-confirm tier.
        let quietDaytime = session(start: date(2032, 7, 3, 13, 0),
                                   end: date(2032, 7, 3, 13, 45),
                                   bpm: 52)

        let candidate = try XCTUnwrap(candidates([quietDaytime]).first)
        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertFalse(candidate.motionEvidenceValidated,
                       "no stillness evidence exists; the candidate must say so")
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(candidate,
                                                                        baselineRestingIsTrusted: true,
                                                                        baselineRestingIsNearTrusted: true),
                       "an unvalidated HR-only nap must never auto-confirm")
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
        // This fixture is an untracked physical-device evidence pull (private
        // health data, kept out of git by policy — see .gitignore). On a
        // machine without the local evidence tree, skip instead of failing:
        // the replay is machine-bound, not broken. 2026-08-20: the file was
        // lost once to an evidence cleanup and reconstructed from the
        // 2026-07-27-gate4-v13-acquisition-ready snapshot (see the capture
        // directory's README).
        try XCTSkipUnless(
            FileManager.default.fileExists(
                atPath: july26ReportedSleepSessionsURL.path
            ),
            "local evidence pull evidence/2026-07-27-all-day-motion-default/settled/sessions.json is absent on this machine"
        )
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
                            motionValidated: true,
                            qualifiedRR: true)
        let resumed = session(start: date(2032, 7, 8, 8, 44),
                              end: date(2032, 7, 8, 11, 38),
                              bpm: 53,
                              motionValidated: true,
                              qualifiedRR: true)

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

    // HR-only presentation honesty (2026-08-01, physical device review): a
    // confirmed/review sleep without validated motion showed "100%"
    // efficiency (actually captured/span coverage) and an all-deep stage
    // band with full validated authority. Efficiency stays withheld and
    // stored data stays untouched; since 2026-08-12 the stage band renders
    // again, but strictly as the labeled HR-only ESTIMATE.
    func testHROnlyNightWithholdsEfficiencyAndStagesButKeepsStorage() {
        let start = date(2026, 7, 31, 22, 0)
        let end = date(2026, 8, 1, 6, 0)
        let allDeep = [SleepStageSegment(id: "aggregate-hr-1",
                                         start: start,
                                         end: end,
                                         stage: .deep)]
        let night = SleepHistorySnapshot.Night(
            id: "hr-only-night",
            day: Self.utcCalendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 52,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 1.0,
            confidence: "user_confirmed_hr_only",
            source: "aggregate_sleep",
            confirmed: true,
            stageSegments: allDeep,
            eventTimeZoneIdentifier: "UTC",
            motionValidated: false
        )

        XCTAssertFalse(night.hasValidatedMotionEvidence)
        XCTAssertNil(night.displaySleepEfficiency,
                     "captured/span coverage must not display as efficiency")
        XCTAssertEqual(night.sleepEfficiencyText, "--")
        XCTAssertEqual(night.sleepEfficiencyFootnote, "Needs motion data")
        XCTAssertEqual(night.stageEvidence, .hrOnlyEstimate)
        XCTAssertEqual(night.stageEvidence.label, "Stages need motion data")
        // The band renders as the mandatory labeled estimate — never with the
        // "Checked stages"/plain-hypnogram authority the 2026-08-01 audit hit.
        XCTAssertTrue(night.isEstimatedStageDisplay)
        XCTAssertEqual(night.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
        XCTAssertFalse(night.displayStageSegments.isEmpty)
        XCTAssertEqual(night.stageSegmentsForStorage.count, 1,
                       "presentation honesty must not rewrite stored/projected segments")
    }

    func testMotionValidatedNightKeepsEfficiencyAndStages() {
        let start = date(2026, 7, 30, 22, 0)
        let end = date(2026, 7, 31, 6, 0)
        let stages = [SleepStageSegment(id: "validated-1",
                                        start: start,
                                        end: end,
                                        stage: .light)]
        let night = SleepHistorySnapshot.Night(
            id: "motion-validated-night",
            day: Self.utcCalendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 52,
            hrv: 48,
            respiratoryRate: 14.2,
            sleepEfficiency: 0.94,
            confidence: "user_confirmed_motion_validated",
            source: "aggregate_sleep",
            confirmed: true,
            stageSegments: stages,
            eventTimeZoneIdentifier: "UTC",
            motionValidated: true
        )

        XCTAssertTrue(night.hasValidatedMotionEvidence)
        XCTAssertEqual(night.sleepEfficiencyText, "94%")
        XCTAssertEqual(night.sleepEfficiencyFootnote, "Duration-based estimate")
        XCTAssertEqual(night.stageEvidence, .sensorResearch)
        XCTAssertFalse(night.displayStageSegments.isEmpty)
    }

    func testLegacyReadyConfidenceStillCountsAsMotionValidated() {
        let start = date(2026, 7, 29, 22, 0)
        let end = date(2026, 7, 30, 6, 0)
        let night = SleepHistorySnapshot.Night(
            id: "legacy-ready-night",
            day: Self.utcCalendar.startOfDay(for: end),
            start: start,
            end: end,
            duration: end.timeIntervalSince(start),
            restingHR: 52,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: 0.91,
            confidence: "ready",
            source: "validated_sleep_window",
            confirmed: false,
            stageSegments: []
        )

        XCTAssertTrue(night.hasValidatedMotionEvidence,
                      "rollup 'ready' remains the legacy motion-ready marker")
        XCTAssertEqual(night.sleepEfficiencyText, "91%")
    }
}
