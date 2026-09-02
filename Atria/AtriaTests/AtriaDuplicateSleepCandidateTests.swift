import XCTest
@testable import Atria

/// Device 2026-09-02: the overnight settlement re-minted an already-confirmed
/// window (15:38 → 02:59) as a review candidate every hour, and Today swung
/// between the candidate's gross span (11h 22m) and the confirmed night's
/// staged time (9h 49m). A candidate that overlaps a confirmed night is the
/// same sleep seen twice: the confirmed record shows while it is current and
/// its duplicate never does.
final class AtriaDuplicateSleepCandidateTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private func night(id: String, start: Date, end: Date, duration: TimeInterval,
                       confirmed: Bool, confidence: String, source: String) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: calendar.startOfDay(for: end),
                                   start: start,
                                   end: end,
                                   duration: duration,
                                   restingHR: 55,
                                   hrv: 61,
                                   respiratoryRate: nil,
                                   sleepEfficiency: nil,
                                   confidence: confidence,
                                   source: source,
                                   confirmed: confirmed,
                                   stageSegments: [],
                                   eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private var confirmedStart: Date { date(9, 1, 15, 38) }
    private var confirmedEnd: Date { date(9, 2, 2, 59) }

    private var confirmedNight: SleepHistorySnapshot.Night {
        // Staged time asleep, the record's own effective duration.
        night(id: "confirmed", start: confirmedStart, end: confirmedEnd,
              duration: 9 * 3_600 + 49 * 60, confirmed: true,
              confidence: "user_confirmed_motion_validated", source: "validated_sleep_window")
    }

    /// The re-minted candidate: same window, gross span, a reference date one
    /// second newer than the confirmed night's.
    private var duplicateCandidate: SleepHistorySnapshot.Night {
        night(id: "duplicate", start: confirmedStart, end: confirmedEnd.addingTimeInterval(1),
              duration: 11 * 3_600 + 22 * 60, confirmed: false,
              confidence: "ready", source: "aggregate_sleep")
    }

    func testOverlappingCandidateNeverReplacesTheConfirmedNight() {
        let snapshot = SleepHistorySnapshot(nights: [confirmedNight], confirmedCount: 1, candidateCount: 0)
        let now = confirmedEnd.addingTimeInterval(4 * 3_600)
        let shown = AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                     pendingReview: duplicateCandidate,
                                                                     now: now,
                                                                     calendar: calendar)
        XCTAssertEqual(shown?.id, "confirmed")
        XCTAssertEqual(shown?.durationText, confirmedNight.durationText)
    }

    func testOverlappingCandidateInTheSnapshotIsIgnoredToo() {
        let snapshot = SleepHistorySnapshot(nights: [duplicateCandidate, confirmedNight],
                                            confirmedCount: 1, candidateCount: 1)
        let now = confirmedEnd.addingTimeInterval(4 * 3_600)
        let shown = AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot, now: now, calendar: calendar)
        XCTAssertEqual(shown?.id, "confirmed")
    }

    func testDuplicateDoesNotResurfaceAfterTheConfirmedNightExpires() {
        let snapshot = SleepHistorySnapshot(nights: [confirmedNight], confirmedCount: 1, candidateCount: 0)
        let muchLater = confirmedEnd.addingTimeInterval(40 * 3_600)
        let shown = AtriaOverviewCurrentSleep.resolveDisplayEvidence(from: snapshot,
                                                                     pendingReview: duplicateCandidate,
                                                                     now: muchLater,
                                                                     calendar: calendar)
        XCTAssertNotEqual(shown?.id, "duplicate", "an expired confirmed night's duplicate is stale too")
    }

    func testANonOverlappingFreshCandidateStillShows() {
        let snapshot = SleepHistorySnapshot(nights: [confirmedNight], confirmedCount: 1, candidateCount: 0)
        let nap = night(id: "nap", start: date(9, 2, 8, 0), end: date(9, 2, 9, 10),
                        duration: 70 * 60, confirmed: false, confidence: "ready", source: "nap_candidate")
        XCTAssertFalse(AtriaOverviewCurrentSleep.overlapsConfirmedNight(nap, in: snapshot))
        XCTAssertTrue(AtriaOverviewCurrentSleep.overlapsConfirmedNight(duplicateCandidate, in: snapshot))
    }

    /// Upstream half: the admission path must not persist a candidate that
    /// duplicates a confirmed window, so the display guard is a backstop, not
    /// the only defence.
    func testAdmissionRejectsACandidateThatOverlapsAConfirmedNight() throws {
        let sessions = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        let guardLine = "if AtriaOverviewCurrentSleep.overlapsConfirmedNight(night, in: self.sleepHistorySnapshot) {"
        let start = try XCTUnwrap(sessions.range(of: guardLine))
        let window = String(sessions[start.lowerBound...].prefix(400))
        XCTAssertTrue(window.contains("receipt.finalOutcome = \"already_confirmed_overlap\""))
        XCTAssertTrue(window.contains("let persisted = AtriaPendingSleepReviewStore.save(night)"),
                      "the overlap check sits directly before the pending-store save")
    }
}
