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
}
