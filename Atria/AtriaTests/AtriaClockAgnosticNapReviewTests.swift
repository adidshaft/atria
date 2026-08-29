import XCTest
@testable import Atria

/// Clock-agnostic nap admission + HR-only nap review (2026-08-29 device
/// defect: two real morning naps produced "No sleep candidates proposed at
/// all"). These tests pin three behaviors:
///  - a bounded morning low-HR window is minted as a review-only nap even
///    though its clock hours classify as "overnight",
///  - an HR-only nap (motion offload lagging) surfaces for wearer review
///    behind a stricter HR bar and can never auto-confirm,
///  - an unbounded mid-night fragment is still refused, and the refusal is
///    named in the detection ring instead of dying silently.
final class AtriaClockAgnosticNapReviewTests: XCTestCase {
    // The onset clamp under `.boundedRecent` reads the device-use journal from
    // shared standard defaults; whatever journal a previous suite or run
    // persisted on this host would silently clamp fixture onsets. An empty
    // journal is exact identity with clamp-off.
    override func setUp() {
        super.setUp()
        AtriaDeviceUseJournal.reset()
    }

    // Deliberately `Calendar.current` (device-local): production always calls
    // aggregateSleepCandidates with `calendar: .current`, and every fixture
    // date is built through this same calendar so hour-of-day gating stays
    // self-consistent regardless of the test host's timezone.
    private var localCalendar: Calendar { Calendar.current }

    private func localDate(_ year: Int, _ month: Int, _ day: Int,
                           _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: localCalendar,
                       timeZone: localCalendar.timeZone,
                       year: year,
                       month: month,
                       day: day,
                       hour: hour,
                       minute: minute).date!
    }

    private func flatHRSession(start: Date, end: Date, bpm: Int,
                               motionValidated: Bool = false) -> SavedSession {
        let duration = end.timeIntervalSince(start)
        let count = max(2, Int(duration / 60))
        let points = (0..<count).map { SavedSession.Point(t: Double($0) * 60, bpm: bpm) }
        return SavedSession(id: UUID(),
                            start: start,
                            end: end,
                            label: "Test",
                            points: points,
                            motionEvidenceSource: motionValidated ? "validated_strap_motion" : nil,
                            motionEvidenceValidated: motionValidated)
    }

    private func candidates(in sessions: [SavedSession], rest: Int = 50) -> [AggregateSleepCandidate] {
        SessionStore.aggregateSleepCandidates(in: sessions,
                                              rest: rest,
                                              maxHR: 190,
                                              calendar: localCalendar,
                                              historicalMotionPolicy: .boundedRecent)
    }

    private func assertNeverAutoConfirmable(_ candidate: AggregateSleepCandidate,
                                            file: StaticString = #filePath,
                                            line: UInt = #line) {
        XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate),
                       "a nap review candidate must never clear the strong auto-confirm tier",
                       file: file, line: line)
        XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(candidate,
                                                                        baselineRestingIsTrusted: true,
                                                                        baselineRestingIsNearTrusted: true),
                       "a nap review candidate must never auto-confirm, even with a trusted baseline",
                       file: file, line: line)
    }

    /// The 2026-08-29 device defect: an 08:00-09:30 low-HR morning nap
    /// (endHour <= 11 classifies "overnight") followed by clearly-awake HR.
    /// It must surface as a review-only HR-only nap candidate.
    func testMorningNapWithAwakeEvidenceAfterMintsHROnlyReview() {
        let nap = flatHRSession(start: localDate(2027, 3, 2, 8, 0),
                                end: localDate(2027, 3, 2, 9, 30),
                                bpm: 60)
        let awake = flatHRSession(start: localDate(2027, 3, 2, 9, 35),
                                  end: localDate(2027, 3, 2, 10, 30),
                                  bpm: 80)

        let result = candidates(in: [nap, awake])
        let naps = result.filter { $0.kind == "nap_candidate" }
        XCTAssertEqual(naps.count, 1,
                       "a bounded morning low-HR window must be minted as a nap review candidate")
        guard let candidate = naps.first else { return }
        XCTAssertFalse(candidate.motionEvidenceValidated,
                       "no stillness evidence was provided; the candidate must say so")
        XCTAssertEqual(candidate.confidence, .low)
        XCTAssertTrue(SessionStore.isReviewWorthySleepCandidate(candidate))
        assertNeverAutoConfirmable(candidate)
        XCTAssertTrue(result.allSatisfy { $0.kind == "nap_candidate" },
                      "the awake tail must not become a sleep candidate of its own")
    }

    /// Same morning window with validated strap stillness keeps the existing
    /// motion-backed nap path: medium confidence, motion validated.
    func testMorningNapWithValidatedMotionMintsNapCandidate() {
        let nap = flatHRSession(start: localDate(2027, 3, 2, 8, 0),
                                end: localDate(2027, 3, 2, 9, 30),
                                bpm: 60,
                                motionValidated: true)
        let awake = flatHRSession(start: localDate(2027, 3, 2, 9, 35),
                                  end: localDate(2027, 3, 2, 10, 30),
                                  bpm: 80)

        let result = candidates(in: [nap, awake]).filter { $0.kind == "nap_candidate" }
        XCTAssertEqual(result.count, 1)
        guard let candidate = result.first else { return }
        XCTAssertTrue(candidate.motionEvidenceValidated)
        XCTAssertEqual(candidate.confidence, .medium)
    }

    /// A mid-night low-HR fragment whose recording continues past the window
    /// end (a hole-riddled night in progress) must not be minted as a nap.
    func testMidNightFragmentTouchingContinuingRecordingIsNotMinted() {
        // Past-dated so only the continuing session blocks admission, not the
        // 45-minutes-before-now deferral.
        let fragment = flatHRSession(start: localDate(2025, 3, 2, 1, 0),
                                     end: localDate(2025, 3, 2, 2, 30),
                                     bpm: 52)
        // Overlapping tail extending past the window end within the join gap:
        // ambiguous continuation, not sustained awake-after evidence (it does
        // not begin after the window end).
        let continuing = flatHRSession(start: localDate(2025, 3, 2, 1, 45),
                                       end: localDate(2025, 3, 2, 3, 30),
                                       bpm: 75)

        let result = candidates(in: [fragment, continuing])
        XCTAssertTrue(result.isEmpty,
                      "a mid-night fragment touching a continuing recording must not become a nap")
    }

    /// The previously fail-closed afternoon case: a daytime-clock HR-only nap
    /// above the stricter review bar now surfaces for wearer review.
    func testAfternoonHROnlyNapMintsReview() {
        let nap = flatHRSession(start: localDate(2027, 3, 2, 14, 0),
                                end: localDate(2027, 3, 2, 15, 0),
                                bpm: 55)

        let result = candidates(in: [nap])
        XCTAssertEqual(result.count, 1)
        guard let candidate = result.first else { return }
        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertFalse(candidate.motionEvidenceValidated)
        XCTAssertEqual(candidate.confidence, .low)
        assertNeverAutoConfirmable(candidate)
    }

    /// Weak HR (avg above rest+12) keeps the morning window out entirely, and
    /// the refusal is named in the detection ring instead of dying silently.
    func testWeakHRMorningWindowStaysNilAndIsNamed() {
        UserDefaults.standard.removeObject(forKey: DetectionEventLog.storageKey)
        let window = flatHRSession(start: localDate(2027, 3, 2, 8, 0),
                                   end: localDate(2027, 3, 2, 9, 30),
                                   bpm: 65)
        let awake = flatHRSession(start: localDate(2027, 3, 2, 9, 35),
                                  end: localDate(2027, 3, 2, 10, 30),
                                  bpm: 80)

        let result = candidates(in: [window, awake])
        XCTAssertTrue(result.isEmpty,
                      "avg above rest+12 must not become a nap at any clock hour")
        XCTAssertTrue(DetectionEventLog.load().contains { $0.reason == "cluster_no_surviving_lane" },
                      "the refused cluster must be named in the detection ring")
    }

    /// Nap physiology below the stricter 30-minute HR-only floor stays
    /// fail-closed without motion, and the refusal is named.
    func testShortHROnlyNapBelowReviewFloorStaysNilAndIsNamed() {
        UserDefaults.standard.removeObject(forKey: DetectionEventLog.storageKey)
        let shortNap = flatHRSession(start: localDate(2027, 3, 2, 14, 0),
                                     end: localDate(2027, 3, 2, 14, 25),
                                     bpm: 52)

        let result = candidates(in: [shortNap])
        XCTAssertTrue(result.isEmpty,
                      "a 25-minute HR-only nap shape is below the stricter review floor")
        XCTAssertTrue(DetectionEventLog.load().contains { $0.reason == "nap_motion_unvalidated_hr_weak" },
                      "the fail-closed nap must be named in the detection ring")
    }

    /// The stopped-recording bound: a past morning window with nothing after
    /// it (the strap simply stopped serving data) is still admitted, because
    /// nothing marks it as the leading fragment of more sleep.
    func testStoppedRecordingMorningNapMintsViaQuietTail() {
        let nap = flatHRSession(start: localDate(2025, 3, 2, 5, 30),
                                end: localDate(2025, 3, 2, 7, 0),
                                bpm: 52)

        let result = candidates(in: [nap])
        XCTAssertEqual(result.count, 1)
        guard let candidate = result.first else { return }
        XCTAssertEqual(candidate.kind, "nap_candidate")
        XCTAssertFalse(candidate.motionEvidenceValidated)
        assertNeverAutoConfirmable(candidate)
    }
}

/// Awake-split retry at the cluster dead-end (2026-08-29 device failure): an
/// evening sleep plus the next morning's naps chained into ONE ~13-18h cluster
/// (session gaps never exceeded the join horizon), and the whole cluster was
/// refused by every lane — napMaximumSpan, maximumAutoConfirmMainSleepSpan and
/// the span-capped review tiers can none of them accept such a span — so the
/// real sleep inside it never surfaced. When (and only when) the unsplit
/// cluster fails everything and its span exceeds the nap ceiling, the builder
/// cuts it at sustained elevated-HR runs (elevated-bounded, >= 15 min at
/// >= 0.60 elevated fraction over rest+22, alive through rest+15 support
/// minutes) and coverage holes > 45 min, then re-evaluates each
/// sub-cluster through the SAME lanes exactly once.
final class AtriaAwakeSplitRetryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AtriaDeviceUseJournal.reset()
        UserDefaults.standard.removeObject(forKey: DetectionEventLog.storageKey)
    }

    private var localCalendar: Calendar { Calendar.current }

    private func localDate(_ year: Int, _ month: Int, _ day: Int,
                           _ hour: Int, _ minute: Int) -> Date {
        DateComponents(calendar: localCalendar,
                       timeZone: localCalendar.timeZone,
                       year: year,
                       month: month,
                       day: day,
                       hour: hour,
                       minute: minute).date!
    }

    /// One point per minute; a nil bpm segment is a coverage hole (the minutes
    /// advance, no points are emitted).
    private func segmentedSession(start: Date,
                                  segments: [(minutes: Int, bpm: Int?)]) -> SavedSession {
        var points: [SavedSession.Point] = []
        var minute = 0
        for segment in segments {
            if let bpm = segment.bpm {
                for offset in 0..<segment.minutes {
                    points.append(.init(t: Double((minute + offset) * 60), bpm: bpm))
                }
            }
            minute += segment.minutes
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(Double(minute) * 60),
                            label: "Test",
                            points: points)
    }

    private func candidates(in sessions: [SavedSession],
                            rest: Int = 55) -> [AggregateSleepCandidate] {
        SessionStore.aggregateSleepCandidates(in: sessions,
                                              rest: rest,
                                              maxHR: 190,
                                              calendar: localCalendar,
                                              historicalMotionPolicy: .boundedRecent)
    }

    /// The device-shaped chained cluster: evening awake run, overnight sleep,
    /// two mid-morning awake runs around a coverage hole, an early-morning
    /// nap, a sustained 78 bpm blip, a second nap, then clearly-awake HR.
    /// Session fragments mirror the journal's 1-4h chunking, so the awake
    /// runs sit INSIDE fragments that pass per-session eligibility (that is
    /// exactly how the device cluster chained). Minute-level HR carries the
    /// dips real sleep has; a night's 30-min means near rest+15 sit above the
    /// per-minute medians the lanes anchor on.
    private func chainedClusterFixture(morningNapSegments: [(minutes: Int, bpm: Int?)])
        -> [SavedSession] {
        // 20:30-23:00: quiet evening then a 60-min awake run at rest+31.
        let s0 = segmentedSession(start: localDate(2027, 3, 2, 20, 30),
                                  segments: [(90, 63), (60, 86)])
        // 23:05-03:15: the overnight sleep block.
        let s1 = segmentedSession(start: localDate(2027, 3, 2, 23, 5),
                                  segments: [(250, 62)])
        // 03:20-07:30: brief sleep tail, 45-min awake run, 45-min hole,
        // 30-min awake run, then a 2h nap.
        let s2 = segmentedSession(start: localDate(2027, 3, 3, 3, 20),
                                  segments: [(10, 62), (45, 86), (45, nil),
                                             (30, 90), (120, 66)])
        // 07:35-09:30: sustained 78 bpm (rest+23) blip, then the second nap.
        let s3 = segmentedSession(start: localDate(2027, 3, 3, 7, 35),
                                  segments: morningNapSegments)
        // 09:35-10:30: clearly awake; ineligible as a sleep fragment, so it
        // stays outside the cluster and bounds the last nap from the right.
        let s4 = segmentedSession(start: localDate(2027, 3, 3, 9, 35),
                                  segments: [(55, 84)])
        return [s0, s1, s2, s3, s4]
    }

    /// Acceptance 1: today's device failure shape must yield a main-sleep
    /// review candidate over the evening block AND nap review candidates for
    /// both real morning naps. The 30-min 78 bpm (rest+23) blip sits above the
    /// rest+22 split floor, so the two naps deliberately do NOT merge across
    /// it — two separate review naps is the documented choice.
    func testChainedClusterSplitsIntoMainReviewAndMorningNaps() {
        let sessions = chainedClusterFixture(
            morningNapSegments: [(25, 78), (90, 61)]
        )
        let result = candidates(in: sessions)

        let mains = result.filter { $0.kind == "overnight_sleep" }
        XCTAssertEqual(mains.count, 1,
                       "the evening sleep block must surface as exactly one main-sleep review candidate")
        if let main = mains.first {
            XCTAssertLessThanOrEqual(main.start, localDate(2027, 3, 2, 23, 5))
            XCTAssertGreaterThanOrEqual(main.end, localDate(2027, 3, 3, 3, 15))
            XCTAssertLessThanOrEqual(main.end, localDate(2027, 3, 3, 3, 30))
            XCTAssertEqual(main.confidence, .low)
            XCTAssertFalse(main.motionEvidenceValidated)
        }

        let naps = result.filter { $0.kind == "nap_candidate" }
        XCTAssertTrue(naps.contains {
            $0.start == localDate(2027, 3, 3, 8, 0) && $0.end == localDate(2027, 3, 3, 9, 30)
        }, "the 08:00-09:30 nap must stand alone as a review candidate")
        XCTAssertTrue(naps.contains {
            $0.start == localDate(2027, 3, 3, 5, 30) && $0.end == localDate(2027, 3, 3, 7, 30)
        }, "the 05:30-07:30 nap must stand alone (the rest+23 blip splits, by design)")

        // Acceptance 4 folded in: no split product may auto-confirm or claim
        // validated motion, and awake-run minutes belong to no candidate.
        for candidate in result {
            XCTAssertFalse(candidate.motionEvidenceValidated)
            XCTAssertEqual(candidate.confidence, .low)
            XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
            XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
                candidate,
                baselineRestingIsTrusted: true,
                baselineRestingIsNearTrusted: true
            ))
            let awakeRunStart = localDate(2027, 3, 3, 3, 30)
            let awakeRunEnd = localDate(2027, 3, 3, 4, 15)
            XCTAssertFalse(candidate.start < awakeRunEnd && candidate.end > awakeRunStart,
                           "no candidate may cover the 03:30-04:15 awake run")
        }
    }

    /// Acceptance 2 (regression pin): a cluster any lane already accepts is
    /// untouched by the split code — same single candidate, full window, and
    /// no dead-end diagnostic, so the retry provably never ran.
    func testAcceptedClusterIsNeverSplit() {
        let night = segmentedSession(start: localDate(2027, 3, 2, 23, 0),
                                     segments: [(300, 62)])
        let result = candidates(in: [night])
        XCTAssertEqual(result.count, 1)
        guard let candidate = result.first else { return }
        XCTAssertEqual(candidate.kind, "overnight_sleep")
        XCTAssertEqual(candidate.start, localDate(2027, 3, 2, 23, 0))
        XCTAssertEqual(candidate.end, localDate(2027, 3, 3, 4, 0))
        XCTAssertEqual(candidate.sessions, 1)
        let events = DetectionEventLog.load()
        XCTAssertFalse(events.contains { $0.reason == "cluster_no_surviving_lane" })
        XCTAssertFalse(events.contains { $0.detail.contains("post_split") })
    }

    /// Acceptance 3: a pathological cluster that fails everything but carries
    /// NO positive awake evidence and no >45-min hole still returns nothing;
    /// the split finds no cut point and the plain refusal stays named. The
    /// split never cuts a window merely to make it fit a lane.
    func testUniformLowHRClusterWithoutCutPointsStaysRefused() {
        let sessions = [
            segmentedSession(start: localDate(2027, 3, 2, 13, 0), segments: [(180, 62)]),
            segmentedSession(start: localDate(2027, 3, 2, 16, 10), segments: [(180, 62)]),
            segmentedSession(start: localDate(2027, 3, 2, 19, 20), segments: [(180, 62)]),
            segmentedSession(start: localDate(2027, 3, 2, 22, 30), segments: [(180, 62)]),
            segmentedSession(start: localDate(2027, 3, 3, 1, 40), segments: [(80, 62)])
        ]
        let result = candidates(in: sessions)
        XCTAssertTrue(result.isEmpty,
                      "a 14h uniform low-HR chain has no honest split and must stay refused")
        let events = DetectionEventLog.load()
        XCTAssertTrue(events.contains { $0.reason == "cluster_no_surviving_lane" })
        XCTAssertFalse(events.contains { $0.detail.contains("post_split") },
                       "no sub-cluster was ever evaluated, so no post_split refusal may exist")
    }

    /// Real-device shape (downsampled): the owner's 2026-08-29 morning cluster
    /// (04:58-10:32 IST) as PER-MINUTE means taken from the actual device
    /// archive. This is the shape that defeated the first-shipped detector:
    /// span 5.6h (under the original 12h retry gate), and every awake stretch
    /// broken by isolated support-floor minutes (the 07:17+ blip measures
    /// 12/18 elevated; the waking tail dips to 74/76 inside 20 elevated
    /// minutes), so strict consecutive-minute runs never reached 20. The
    /// refused cluster must split at the elevated-dominated runs and yield
    /// both real naps as review candidates.
    func testRealShapedMorningClusterSplitsIntoBothNaps() {
        // 04:58 + 179 minutes (ends 07:57); head awake, first nap, awake blip.
        let morningA: [Int] = [
            81, 81, 78, 82, 79, 79, 90, 73, 79, 76, 78, 86, 98, 82, 87, 98, 82, 83, 106, 103,
            105, 116, 110, 98, 93, 96, 101, 85, 82, 82, 84, 76, 78, 82, 81, 80, 70, 70, 67, 67,
            70, 73, 86, 79, 71, 72, 76, 80, 73, 71, 71, 74, 75, 75, 75, 73, 72, 69, 65, 66,
            68, 68, 68, 72, 70, 77, 70, 73, 68, 70, 67, 68, 68, 69, 66, 68, 68, 69, 67, 67,
            67, 69, 65, 67, 65, 66, 68, 64, 63, 65, 63, 67, 76, 67, 65, 67, 67, 69, 67, 69,
            62, 64, 63, 65, 66, 72, 68, 68, 64, 64, 72, 70, 69, 66, 65, 66, 65, 65, 66, 67,
            71, 65, 62, 67, 65, 67, 66, 65, 64, 65, 68, 66, 61, 63, 67, 65, 69, 63, 76, 86,
            80, 80, 79, 79, 78, 81, 80, 77, 76, 75, 78, 82, 81, 77, 80, 84, 80, 74, 75, 76,
            79, 75, 79, 86, 112, 116, 77, 71, 69, 69, 69, 69, 73, 71, 72, 72, 71, 71, 70
        ]
        // 07:59 + 154 minutes (ends 10:33); second nap, then the waking tail.
        let morningB: [Int] = [
            69, 67, 69, 66, 66, 66, 67, 65, 65, 63, 67, 65, 62, 64, 66, 66, 65, 66, 66, 66,
            67, 64, 64, 65, 66, 64, 63, 64, 63, 68, 61, 64, 61, 60, 61, 58, 62, 64, 66, 60,
            61, 61, 59, 58, 58, 61, 60, 61, 58, 59, 58, 57, 58, 58, 60, 59, 58, 61, 59, 56,
            57, 57, 55, 57, 57, 56, 57, 57, 58, 63, 60, 57, 58, 58, 60, 58, 55, 62, 64, 61,
            69, 65, 69, 73, 69, 70, 71, 72, 74, 66, 67, 67, 68, 66, 67, 67, 65, 67, 69, 68,
            66, 65, 66, 66, 67, 65, 65, 64, 65, 64, 67, 67, 71, 61, 69, 84, 84, 87, 74, 75,
            82, 86, 82, 83, 83, 83, 68, 65, 62, 62, 62, 65, 73, 84, 74, 83, 96, 95, 102, 97,
            91, 102, 100, 88, 76, 87, 79, 82, 89, 86, 84, 90, 92, 81
        ]
        func minuteSession(start: Date, means: [Int]) -> SavedSession {
            let points = means.enumerated().map {
                SavedSession.Point(t: Double($0.offset * 60), bpm: $0.element)
            }
            return SavedSession(id: UUID(),
                                start: start,
                                end: start.addingTimeInterval(Double(means.count) * 60),
                                label: "Test",
                                points: points)
        }
        let sessionA = minuteSession(start: localDate(2027, 3, 3, 4, 58), means: morningA)
        let sessionB = minuteSession(start: localDate(2027, 3, 3, 7, 59), means: morningB)

        let result = candidates(in: [sessionA, sessionB], rest: 57)
        let naps = result.filter { $0.kind == "nap_candidate" }
        XCTAssertTrue(naps.contains {
            $0.start <= localDate(2027, 3, 3, 6, 0) && $0.end >= localDate(2027, 3, 3, 7, 0)
        }, "the first real nap (~05:34-07:17) must surface as a review candidate")
        XCTAssertTrue(naps.contains {
            $0.start <= localDate(2027, 3, 3, 8, 30) && $0.end >= localDate(2027, 3, 3, 9, 30)
        }, "the second real nap (~08:00-09:30) must surface as a review candidate")
        for candidate in result {
            XCTAssertEqual(candidate.confidence, .low)
            XCTAssertFalse(candidate.motionEvidenceValidated)
            XCTAssertFalse(SessionStore.isStrongAutoConfirmableSleepCandidate(candidate))
            XCTAssertFalse(SessionStore.isAutoConfirmableMainSleepCandidate(
                candidate,
                baselineRestingIsTrusted: true,
                baselineRestingIsNearTrusted: true
            ))
            XCTAssertGreaterThanOrEqual(candidate.start, localDate(2027, 3, 3, 5, 30),
                                        "no candidate may claim the 04:58-05:33 awake head")
            XCTAssertLessThanOrEqual(candidate.end, localDate(2027, 3, 3, 10, 15),
                                     "no candidate may claim the 10:12+ waking tail")
        }
    }

    /// A sub-cluster that fails its own lanes after the split dies with the
    /// existing named diagnostic carrying the post_split marker: here the
    /// second morning nap is 25 min — nap-shaped, but below the 30-min HR-only
    /// review floor — while the rest of the split still surfaces normally.
    func testFailedSubClusterIsNamedWithPostSplitMarker() {
        let sessions = chainedClusterFixture(
            morningNapSegments: [(25, 78), (25, 61), (65, 78)]
        )
        let result = candidates(in: sessions)

        XCTAssertEqual(result.filter { $0.kind == "overnight_sleep" }.count, 1,
                       "the failed 25-min sub-nap must not take the rescued night down with it")
        XCTAssertFalse(result.contains {
            $0.start == localDate(2027, 3, 3, 8, 0) && $0.end == localDate(2027, 3, 3, 8, 25)
        }, "a 25-min HR-only nap shape stays below the review floor even post-split")
        let events = DetectionEventLog.load()
        XCTAssertTrue(events.contains {
            $0.reason == "nap_motion_unvalidated_hr_weak" && $0.detail.contains("post_split")
        }, "the refused sub-cluster must be named in the detection ring as a post-split refusal")
    }
}
