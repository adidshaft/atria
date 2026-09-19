import SwiftUI
import XCTest
@testable import Atria

/// Expanded-chart activity parity (2026-08-20 user report): tapping to expand
/// a metric chart to full screen lost the workout/sleep activity markers the
/// smaller inline charts show. Two mechanisms, both pinned here:
///
///   1. The expanded chart derived its x-domain from the METRIC POINTS alone
///      (`points.first.day - 12h ... points.last.day + 12h`) while the inline
///      detail chart plots the full calendar period. Activity on period days
///      whose metric had not settled yet — today's confirmed sleep/workout —
///      was silently clipped out of the full-screen view. The detail sheet now
///      passes its period window as the expanded chart's explicit x-domain.
///   2. The event lane rendered DAY-BUCKETED marks (`unit: .day`) but counted
///      raw timestamps, so afternoon activity on the last plotted day rendered
///      without being counted (or vice versa) and the edit sheet's
///      "Mark journal events" toggle reported no events. The lane list and the
///      count now come from one day-bucketed membership rule.
///
/// Everything tested here is pure presentation policy: no stores, no clocks,
/// no timing waits. All dates use a fixed UTC calendar.
@MainActor
final class AtriaExpandedChartActivityParityTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Deterministic Monday-start weeks regardless of host locale.
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day,
                                           hour: hour, minute: minute))!
    }

    private func workout(id: String,
                         start: Date,
                         minutes: Double,
                         source: String = "manual",
                         activityType: String? = nil,
                         activitySubtype: String? = nil) -> UserConfirmedWorkout {
        let end = start.addingTimeInterval(minutes * 60)
        return UserConfirmedWorkout(id: id,
                                    createdAt: end,
                                    start: start,
                                    end: end,
                                    label: "Fixture workout",
                                    source: source,
                                    confidence: "test",
                                    sessions: 1,
                                    samples: 10,
                                    avgHR: 120,
                                    peakHR: 150,
                                    p95HR: 145,
                                    p99HR: 148,
                                    thresholdHR: 110,
                                    streamCoveragePercent: 100,
                                    observedDuration: end.timeIntervalSince(start),
                                    reason: "test",
                                    activityType: activityType,
                                    activitySubtype: activitySubtype)
    }

    private func night(id: String, day: Date, confirmed: Bool) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: id,
                                   day: day,
                                   start: day.addingTimeInterval(13 * 3600),
                                   end: day.addingTimeInterval(19 * 3600),
                                   duration: 6 * 3600,
                                   restingHR: 54,
                                   hrv: nil,
                                   respiratoryRate: nil,
                                   sleepEfficiency: nil,
                                   confidence: "ready",
                                   source: "sleep_window",
                                   confirmed: confirmed,
                                   stageSegments: [])
    }

    // MARK: - 1. One shared builder: expanded route == inline route

    /// The expanded routes now compute their events through
    /// `AtriaChartEvent.activityEvents`, whose output must be exactly the
    /// mapping the inline Vitals trend host renders for identical inputs:
    /// presentable workouts (accidental sub-minute live fragments excluded)
    /// plus CONFIRMED sleep nights only, with the same ids, days, labels,
    /// glyphs, and tints.
    func testActivityEventBuilderMatchesInlineRouteMappingForIdenticalInputs() {
        let run = workout(id: "w-run",
                          start: date(2026, 8, 11, 7, 30),
                          minutes: 40,
                          activityType: "Running",
                          activitySubtype: "Tempo run")
        let unlabeled = workout(id: "w-unlabeled",
                                start: date(2026, 8, 12, 18, 0),
                                minutes: 25)
        // The inline route's presentability gate: a sub-minute live fragment
        // is an accidental tap, not a training session, and must not mark.
        let fragment = workout(id: "w-fragment",
                               start: date(2026, 8, 12, 9, 0),
                               minutes: 0.5,
                               source: "live_workout_window")
        let confirmedNight = night(id: "n-confirmed",
                                   day: date(2026, 8, 12),
                                   confirmed: true)
        let reviewNight = night(id: "n-review",
                                day: date(2026, 8, 13),
                                confirmed: false)

        let events = AtriaChartEvent.activityEvents(
            workouts: [run, fragment, unlabeled],
            sleepNights: [confirmedNight, reviewNight]
        )

        let expected: [AtriaChartEvent] = [
            AtriaChartEvent(id: "workout-w-run",
                            day: run.start,
                            label: "Tempo run",
                            systemImage: "flame.fill",
                            tint: Metrics.electricStrain),
            AtriaChartEvent(id: "workout-w-unlabeled",
                            day: unlabeled.start,
                            label: "Workout",
                            systemImage: "flame.fill",
                            tint: Metrics.electricStrain),
            AtriaChartEvent(id: "sleep-n-confirmed",
                            day: confirmedNight.day,
                            label: "Sleep",
                            systemImage: "bed.double.fill",
                            tint: Metrics.electricSleep),
        ]
        XCTAssertEqual(events, expected)
    }

    /// Subtype beats type beats the generic fallback — the exact label rule
    /// every route shared before the builders diverged.
    func testActivityEventLabelFallsBackFromSubtypeToTypeToGeneric() {
        let typed = workout(id: "w-typed",
                            start: date(2026, 8, 11, 8),
                            minutes: 30,
                            activityType: "Cycling")
        let events = AtriaChartEvent.activityEvents(workouts: [typed], sleepNights: [])
        XCTAssertEqual(events.map(\.label), ["Cycling"])
    }

    // MARK: - 2. Expanded renderer lane membership (day-bucketed, non-empty)

    /// The renderer's lane draws day-bucketed marks, so membership must be
    /// day-bucketed too. Regression pin: an afternoon workout on the last
    /// period day used to be dropped from the count (raw timestamp beyond the
    /// domain) while its day-bucketed mark rendered — the edit sheet then
    /// disabled the journal-events toggle claiming there was nothing to mark.
    func testEventLaneUsesDayBucketedMembershipInsideDomain() {
        // Trailing week ending on the reference day: Thu 2026-08-06 ...
        // Thu 2026-08-13 (exclusive upper edge), so the last plotted day is
        // Wed 2026-08-12. These fixtures used to describe a Mon-anchored
        // calendar week; the window became trailing on 2026-09-03 so that
        // every range ends at today, and the dates moved with it. What is
        // pinned here — day-bucketed membership, and both edges excluded — is
        // unchanged.
        let domain = AtriaMetricDetailSheet.chartPeriodXDomain(
            range: .week,
            referenceDate: date(2026, 8, 12),
            calendar: calendar
        )
        XCTAssertEqual(domain.lowerBound, date(2026, 8, 6))
        XCTAssertEqual(domain.upperBound, date(2026, 8, 13))

        let lastDayEvening = AtriaChartEvent(id: "workout-late",
                                             day: date(2026, 8, 12, 18, 30),
                                             label: "Run",
                                             systemImage: "flame.fill",
                                             tint: Metrics.electricStrain)
        let nextPeriodMidnight = AtriaChartEvent(id: "sleep-next",
                                                 day: date(2026, 8, 13),
                                                 label: "Sleep",
                                                 systemImage: "bed.double.fill",
                                                 tint: Metrics.electricSleep)
        let priorWeek = AtriaChartEvent(id: "sleep-prior",
                                        day: date(2026, 8, 5, 23, 0),
                                        label: "Sleep",
                                        systemImage: "bed.double.fill",
                                        tint: Metrics.electricSleep)

        let lane = AtriaExpandedChartView.eventLaneEvents(
            [lastDayEvening, nextPeriodMidnight, priorWeek],
            xDomain: domain,
            calendar: calendar
        )

        XCTAssertEqual(lane.map(\.id), ["workout-late"],
                       "in-period afternoon activity marks; the next period's first day and the prior week do not")
    }

    func testEventLaneIsNonEmptyWheneverAConfirmedActivityFallsInThePeriod() {
        let domain = AtriaMetricDetailSheet.chartPeriodXDomain(
            range: .week,
            referenceDate: date(2026, 8, 12),
            calendar: calendar
        )
        let events = AtriaChartEvent.activityEvents(
            workouts: [],
            sleepNights: [night(id: "n-today", day: date(2026, 8, 11), confirmed: true)]
        )
        let lane = AtriaExpandedChartView.eventLaneEvents(events,
                                                          xDomain: domain,
                                                          calendar: calendar)
        XCTAssertFalse(lane.isEmpty,
                       "non-empty events inside the plotted period must reach the expanded renderer's overlay layer")
        XCTAssertEqual(AtriaExpandedChartView.eventLaneEvents([],
                                                              xDomain: domain,
                                                              calendar: calendar), [],
                       "an empty day has no marker — nothing is invented")
    }

    // MARK: - 3. Explicit period domain ends the metric-points clip

    /// THE reported drop: metric points end mid-period (recovery/HRV settle
    /// after the cycle), so the points-derived domain excluded the days where
    /// today's activity lives. With the detail sheet's explicit period domain
    /// the same event is inside the domain; without it (the legacy trend-card
    /// route) the derived window is preserved bit-for-bit.
    func testExpandedPreparedModelHonorsExplicitPeriodDomainAndKeepsLegacyDerivedDomain() {
        // Points settle early in the window and stop; the activity lands on a
        // later day of the same period. (Dates follow the trailing week
        // 08-06 ... 08-13; the shape of the case is untouched.)
        let points = [
            AtriaDetailChartPoint(day: date(2026, 8, 6), value: 62, tint: .green),
            AtriaDetailChartPoint(day: date(2026, 8, 7), value: 64, tint: .green),
            AtriaDetailChartPoint(day: date(2026, 8, 8), value: 61, tint: .green),
            AtriaDetailChartPoint(day: date(2026, 8, 9), value: 66, tint: .green),
        ]
        let periodDomain = AtriaMetricDetailSheet.chartPeriodXDomain(
            range: .week,
            referenceDate: date(2026, 8, 12),
            calendar: calendar
        )
        let latePeriodSleep = AtriaChartEvent(id: "sleep-late-in-period",
                                              day: date(2026, 8, 11),
                                            label: "Sleep",
                                            systemImage: "bed.double.fill",
                                            tint: Metrics.electricSleep)

        let explicitModel = AtriaExpandedChartPreparedModel(points: points,
                                                            priorPoints: [],
                                                            baselineBand: nil,
                                                            overlays: [],
                                                            explicitXDomain: periodDomain,
                                                            calendar: calendar)
        XCTAssertEqual(explicitModel.xDomain, periodDomain)
        XCTAssertEqual(explicitModel.spanDays, 7)
        XCTAssertEqual(AtriaExpandedChartView.eventLaneEvents([latePeriodSleep],
                                                              xDomain: explicitModel.xDomain,
                                                              calendar: calendar).map(\.id),
                       ["sleep-late-in-period"],
                       "activity on a period day without a settled metric point must render in the expanded chart")

        let derivedModel = AtriaExpandedChartPreparedModel(points: points,
                                                           priorPoints: [],
                                                           baselineBand: nil,
                                                           overlays: [],
                                                           explicitXDomain: nil,
                                                           calendar: calendar)
        XCTAssertEqual(derivedModel.xDomain,
                       date(2026, 8, 6).addingTimeInterval(-43_200)...date(2026, 8, 9).addingTimeInterval(43_200),
                       "the trend-card route keeps its legacy data-derived window unchanged")
        XCTAssertEqual(derivedModel.spanDays, 3)
        XCTAssertTrue(AtriaExpandedChartView.eventLaneEvents([latePeriodSleep],
                                                             xDomain: derivedModel.xDomain,
                                                             calendar: calendar).isEmpty,
                      "the derived window is exactly the clip the explicit period domain exists to fix")
    }

    // MARK: - 4. Route wiring stays shared

    /// Structural pin: both expanded routes compute events through the ONE
    /// shared builder, the detail sheet hands its period window to the
    /// expanded view, and the renderer's overlay layer consumes the gated
    /// day-bucketed lane list (not the raw events array).
    func testExpandedRouteWiringSharesBuilderPeriodDomainAndLaneList() throws {
        let (_, overview) = try source("AtriaOverviewSections.swift")
        let (_, trend) = try source("AtriaTrendChart.swift")
        let (_, expanded) = try source("AtriaExpandedChart.swift")

        XCTAssertTrue(overview.contains("AtriaChartEvent.activityEvents(workouts: confirmedWorkouts"),
                      "the metric-detail expanded route must use the shared activity builder")
        XCTAssertTrue(overview.contains("xDomain: expandedChartXDomain"),
                      "the metric-detail expanded route must pass its inline period window")
        XCTAssertTrue(trend.contains("AtriaChartEvent.activityEvents(workouts: store.confirmedWorkouts"),
                      "the trend projection must use the shared activity builder")
        XCTAssertTrue(expanded.contains("ForEach(laneEvents)"),
                      "the expanded renderer's event lane must draw the day-bucketed in-domain lane list")
        XCTAssertTrue(expanded.contains("if markJournalEvents {"),
                      "the event overlay layer must exist in the expanded renderer")
    }

    private func source(_ name: String) throws -> (String, String) {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let url = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria/\(name)")
        return (name, try String(contentsOf: url, encoding: .utf8))
    }
}
