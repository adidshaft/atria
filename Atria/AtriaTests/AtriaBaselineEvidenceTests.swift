import XCTest
@testable import Atria

/// Baseline resting-sample acceptance floor (2026-07-08, device-reported
/// "1/14 RHR" after 3 days). All-day wear fragmented by frequent BLE drops
/// into sub-20-min segments was silently discarding genuinely restful data,
/// stalling the RHR baseline. The floor is now 5 min; the avg/peak
/// rest-window guards still decide what actually counts as resting, so
/// elevated segments never pollute the resting norm.
final class AtriaBaselineEvidenceTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    /// A fixed midday instant so restingHRForBaseline never takes the
    /// sleep-candidate path (a short daytime window is neither overnight nor
    /// long enough to be a nap).
    private func middaySession(durationSeconds: Double, bpm: Int) -> SavedSession {
        let start = DateComponents(calendar: calendar, year: 2026, month: 7, day: 1,
                                   hour: 12, minute: 0).date!
        let points = stride(from: 0.0, through: durationSeconds, by: 10.0).map {
            SavedSession.Point(t: $0, bpm: bpm)
        }
        return SavedSession(id: UUID(),
                            start: start,
                            end: start.addingTimeInterval(durationSeconds),
                            label: "Rest",
                            points: points,
                            respiratoryRate: nil,
                            rrPoints: nil,
                            sleepWakeResearchState: nil)
    }

    func testRestfulTenMinuteSegmentNowAccepted() {
        // 10 min at 65 bpm, rest 60: previously rejected "duration_below_20m",
        // now clears the 5-min floor and the avg/peak guards.
        let evidence = middaySession(durationSeconds: 600, bpm: 65)
            .baselineLearningEvidence(rest: 60, maxHR: 190, calendar: calendar)
        XCTAssertTrue(evidence.accepted, "genuinely restful 10-min segment must count")
        XCTAssertEqual(evidence.reason, "low_hr_window")
    }

    func testElevatedTenMinuteSegmentStillRejected() {
        // 10 min at 90 bpm, rest 60: above rest+15, must NOT pollute the
        // resting baseline even though it now clears the duration floor.
        let evidence = middaySession(durationSeconds: 600, bpm: 90)
            .baselineLearningEvidence(rest: 60, maxHR: 190, calendar: calendar)
        XCTAssertFalse(evidence.accepted)
        XCTAssertEqual(evidence.reason, "avg_hr_above_rest_window")
    }

    func testSubFiveMinuteSegmentStillRejected() {
        // 4 min at 65 bpm: too short to trust, still fails closed.
        let evidence = middaySession(durationSeconds: 240, bpm: 65)
            .baselineLearningEvidence(rest: 60, maxHR: 190, calendar: calendar)
        XCTAssertFalse(evidence.accepted)
        XCTAssertEqual(evidence.reason, "duration_below_5m")
    }

    func testQualifiedRRCannotBypassElevatedRestingGate() {
        let start = DateComponents(calendar: calendar, year: 2026, month: 7, day: 2,
                                   hour: 1, minute: 0).date!
        let duration = 16 * 60.0
        let rr = stride(from: 1.0, through: duration, by: 1.0).map { offset in
            SavedSession.RRPoint(t: offset,
                                 ms: Int(offset).isMultiple(of: 2) ? 980 : 1_020,
                                 source: .standardHeartRateMeasurement2A37)
        }
        let elevated = SavedSession(id: UUID(),
                                    start: start,
                                    end: start.addingTimeInterval(duration),
                                    label: "Elevated RR window",
                                    points: stride(from: 0.0, through: duration, by: 10).map {
                                        SavedSession.Point(t: $0, bpm: 92)
                                    },
                                    hrv: 42,
                                    rrPoints: rr)

        XCTAssertNotNil(elevated.localRMSSD)
        let evidence = elevated.baselineLearningEvidence(rest: 60,
                                                         maxHR: 190,
                                                         calendar: calendar)
        XCTAssertFalse(evidence.accepted)
        XCTAssertEqual(evidence.reason, "avg_hr_above_rest_window")
    }

    func testRestingBaselineMaturityQualifierShowsProgressFromDayOne() {
        // A wearer must see a reading and how mature it is on day one, not a
        // blank until the baseline is trusted. Mirrors AtriaFitnessAge's
        // "Early estimate · day N of M" phrasing so the caveat reads the same
        // wherever it is surfaced.
        let now = Date(timeIntervalSince1970: 1_784_000_000)
        func baseline(days: Int) -> PersonalBaseline {
            var value = PersonalBaseline()
            value.updated = now
            value.samples = (0..<days).map { index in
                PersonalBaseline.BaselineSample(
                    date: now.addingTimeInterval(TimeInterval(-index) * 86_400),
                    restingHR: 60,
                    rmssd: nil,
                    overnight: false
                )
            }
            return value
        }
        // Resting evidence may come from a qualified daytime low-HR window, so
        // its maturity unit is days. HRV remains sleep-window qualified.
        XCTAssertEqual(
            baseline(days: 1).restingBaselineMaturityQualifierText(now: now),
            "Learning · 1 of 14 days"
        )
        XCTAssertEqual(
            baseline(days: 5).restingBaselineMaturityQualifierText(now: now),
            "Learning · 5 of 14 days"
        )
        // Once trusted the qualifier disappears entirely — one caveat, and only
        // while it is true.
        XCTAssertNil(baseline(days: 14).restingBaselineMaturityQualifierText(now: now))
    }

    func testReconnectFragmentsReceiveOneBaselineObservationPerDay() {
        let firstDay = Date(timeIntervalSince1970: 1_783_036_800)
        var canonical = PersonalBaseline()
        var fragmented = PersonalBaseline()

        for day in 0..<14 {
            let date = firstDay.addingTimeInterval(Double(day) * 86_400 + 12 * 3_600)
            let resting = day == 7 ? 90 : 60
            canonical.learn(fromResting: resting, hrv: 0, at: date)
            let fragments = day == 7 ? 4 : 1
            for fragment in 0..<fragments {
                fragmented.learn(
                    fromResting: resting,
                    hrv: 0,
                    at: date.addingTimeInterval(Double(fragment) * 600)
                )
            }
        }

        XCTAssertEqual(fragmented.restingSampleCount, 14)
        XCTAssertEqual(try XCTUnwrap(fragmented.restingHR),
                       try XCTUnwrap(canonical.restingHR),
                       accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(fragmented.restingStats(
                now: firstDay.addingTimeInterval(15 * 86_400)
            )).mean,
            try XCTUnwrap(canonical.restingStats(
                now: firstDay.addingTimeInterval(15 * 86_400)
            )).mean,
            accuracy: 0.000_001
        )
    }

}
