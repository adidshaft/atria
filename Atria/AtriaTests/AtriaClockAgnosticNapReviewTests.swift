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
