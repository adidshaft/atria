import SwiftUI
import Charts
import MapKit
import Combine

struct AtriaActivitySectionsRequestKey: Equatable {
    let sleepRevision: Int
    let workoutsRevision: Int
    let rollupsRevision: Int
    let detectionsRevision: Int
    let reviewFingerprint: String
    let selectedDayStart: Date
    let intervalStart: Date
    let intervalEnd: Date
    let isCurrentPhysiologicalDay: Bool
    let calendarIdentifier: String
    let timeZoneIdentifier: String

    init(sleepRevision: Int,
         workoutsRevision: Int,
         rollupsRevision: Int = 0,
         detectionsRevision: Int = 0,
         reviewFingerprint: String = "",
         selectedDay: Date,
         interval: DateInterval? = nil,
         isCurrentPhysiologicalDay: Bool = false,
         calendar: Calendar) {
        self.sleepRevision = sleepRevision
        self.workoutsRevision = workoutsRevision
        self.rollupsRevision = rollupsRevision
        self.detectionsRevision = detectionsRevision
        self.reviewFingerprint = reviewFingerprint
        selectedDayStart = calendar.startOfDay(for: selectedDay)
        let civilEnd = calendar.date(byAdding: .day, value: 1, to: selectedDayStart) ?? selectedDayStart
        intervalStart = interval?.start ?? selectedDayStart
        intervalEnd = interval?.end ?? civilEnd
        self.isCurrentPhysiologicalDay = isCurrentPhysiologicalDay
        calendarIdentifier = String(describing: calendar.identifier)
        timeZoneIdentifier = calendar.timeZone.identifier
    }
}

struct AtriaActivityDisplayWindow: Equatable {
    let interval: DateInterval
    let labelDay: Date
    let isCurrentPhysiologicalDay: Bool
    /// Historical windows expose whether they came from measured wake
    /// boundaries, a deterministic no-sleep rollover, or the civil fallback.
    /// Current windows delegate directly to `AtriaPhysiologicalDay` and leave
    /// this nil.
    let historicalStartBoundary: AtriaHistoricalPhysiologicalCycle.StartBoundary?
    let historicalEndBoundary: AtriaHistoricalPhysiologicalCycle.EndBoundary?

    static func current(now: Date,
                        sleepHistory: SleepHistorySnapshot,
                        calendar: Calendar = .current) -> Self {
        // A second-level moving end would invalidate SwiftUI task/cache keys on
        // every body evaluation. Activity presentation is minute-granular, so
        // keep one stable live window per minute without changing attribution.
        let minuteNow = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let day = AtriaPhysiologicalDay.current(now: now,
                                               sleepHistory: sleepHistory,
                                               calendar: calendar)
        let stableEnd = max(day.start, minuteNow)
        return Self(interval: DateInterval(start: day.start, end: stableEnd),
                    labelDay: day.displayDay,
                    isCurrentPhysiologicalDay: true,
                    historicalStartBoundary: nil,
                    historicalEndBoundary: nil)
    }

    static func historical(day: Date,
                           sleepHistory: SleepHistorySnapshot,
                           calendar: Calendar = .current) -> Self {
        let cycle = AtriaHistoricalPhysiologicalCycle.resolve(
            displayDay: day,
            sleepHistory: sleepHistory,
            calendar: calendar
        )
        return Self(interval: cycle.interval,
                    labelDay: cycle.displayDay,
                    isCurrentPhysiologicalDay: false,
                    historicalStartBoundary: cycle.startBoundary,
                    historicalEndBoundary: cycle.endBoundary)
    }

    /// Explicit no-evidence overload retained for previews and narrow callers.
    /// Its provenance is deliberately civil rather than silently implying a
    /// wake boundary.
    static func historical(day: Date, calendar: Calendar = .current) -> Self {
        historical(day: day, sleepHistory: .empty, calendar: calendar)
    }
}

/// Pure day-navigation policy for Activity's physiological window model. Date
/// labels remain civil and stable, while their content resolves wake-to-wake.
/// Comparing against the selected historical window itself makes every next-day
/// tap look like the Today boundary, so the real current display day must be an
/// independent input.
enum AtriaActivityDayNavigation {
    struct Destination: Equatable {
        let day: Date
        let viewsCurrentPhysiologicalDay: Bool
    }

    static func next(
        from selectedDay: Date,
        currentPhysiologicalDisplayDay: Date,
        calendar: Calendar = .current
    ) -> Destination {
        let selected = calendar.startOfDay(for: selectedDay)
        let current = calendar.startOfDay(for: currentPhysiologicalDisplayDay)
        guard selected < current,
              let next = calendar.date(byAdding: .day, value: 1, to: selected) else {
            return Destination(day: current, viewsCurrentPhysiologicalDay: true)
        }
        if next >= current {
            return Destination(day: current, viewsCurrentPhysiologicalDay: true)
        }
        return Destination(day: next, viewsCurrentPhysiologicalDay: false)
    }
}

/// Bounded invalidation policy for the selected-day signal projection. Raw
/// archive appends can arrive about once per second, so Activity deliberately
/// does not observe that row-level notification. It refreshes when the scene
/// becomes usable again and when SessionStore publishes one fully-settled
/// recovered-data revision.
enum AtriaActivityTimelineRefreshPolicy {
    static func shouldRefresh(
        previousScenePhase: ScenePhase,
        scenePhase: ScenePhase
    ) -> Bool {
        previousScenePhase != .active && scenePhase == .active
    }

    static func nextRevision(after revision: UInt64) -> UInt64 {
        revision &+ 1
    }
}

/// Stable identity for one Activity signal window. The current wake-to-wake
/// window intentionally has no moving end, so a foreground/completeness refresh
/// can preserve the trace already on screen while it refreshes its backing data.
struct AtriaActivityHeartRateWindowIdentity: Equatable, Sendable {
    let start: Date
    let historicalEnd: Date?
    let isCurrent: Bool
}

enum AtriaActivityHeartRateLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case unavailable
    case interrupted
}

/// Pure request-lifecycle policy used by the SwiftUI leaf and pinned in tests.
/// An old request may finish after a newer one, but it never owns the newer
/// request's state. Cancellation is terminal for the request that still owns the
/// view; a visible trace remains usable rather than being blanked.
enum AtriaActivityHeartRateRefreshPolicy {
    static func preservesProjection(
        previous: AtriaActivityHeartRateWindowIdentity?,
        next: AtriaActivityHeartRateWindowIdentity
    ) -> Bool {
        previous == next
    }

    static func terminalState(readSucceeded: Bool) -> AtriaActivityHeartRateLoadState {
        readSucceeded ? .loaded : .unavailable
    }

    static func cancellationState(hasVisiblePoints: Bool) -> AtriaActivityHeartRateLoadState {
        hasVisiblePoints ? .loaded : .interrupted
    }

    /// Live history revisions must not re-key a *completed* historical day's HR
    /// load. A live append cannot change a finished civil day, but folding the
    /// ever-advancing live revision into that day's `.task` id restarted the
    /// archive read on every tick, pinning it at `.loading` forever. Mirror the
    /// stress key: the current physiological window follows live revisions; a
    /// historical window is pinned (0) and re-reads only on a completeness /
    /// publication revision, so its single read reaches a terminal state.
    static func foldedHistoryRevision(isCurrent: Bool, liveRevision: Int) -> Int {
        isCurrent ? liveRevision : 0
    }
}

/// Keeps sensor suggestions visible without duplicating an already-saved
/// workout or showing the same physiological window twice through the general
/// detector and the higher-quality workout-review cache.
enum AtriaActivityReviewProjection {
    static func visibleDetections(_ detections: [ActivityDetection],
                                  workoutReview: WorkoutReviewCandidate?,
                                  confirmedWorkouts: [UserConfirmedWorkout],
                                  interval: DateInterval) -> [ActivityDetection] {
        detections.filter { detection in
            guard detection.kind == .activityCandidate || detection.kind == .workout,
                  detection.end > interval.start,
                  detection.start < interval.end,
                  !overlapsConfirmedWorkout(start: detection.start,
                                            end: detection.end,
                                            confirmedWorkouts: confirmedWorkouts) else { return false }
            if let workoutReview {
                let overlap = min(workoutReview.end, detection.end)
                    .timeIntervalSince(max(workoutReview.start, detection.start))
                let shortest = min(workoutReview.duration, detection.duration)
                if overlap >= 5 * 60 || (shortest > 0 && overlap / shortest >= 0.70) { return false }
            }
            return true
        }.sorted { $0.start > $1.start }
    }

    static func overlapsConfirmedWorkout(start: Date,
                                         end: Date,
                                         confirmedWorkouts: [UserConfirmedWorkout]) -> Bool {
        confirmedWorkouts.contains { workout in
            let overlap = min(workout.end, end).timeIntervalSince(max(workout.start, start))
            guard overlap > 0 else { return false }
            let shortest = min(workout.duration, end.timeIntervalSince(start))
            return overlap >= 5 * 60 || (shortest > 0 && overlap / shortest >= 0.70)
        }
    }

    static func visibleDetections(_ detections: [ActivityDetection],
                                  workoutReview: WorkoutReviewCandidate?,
                                  confirmedWorkouts: [UserConfirmedWorkout],
                                  selectedDay: Date,
                                  calendar: Calendar) -> [ActivityDetection] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return visibleDetections(detections,
                                 workoutReview: workoutReview,
                                 confirmedWorkouts: confirmedWorkouts,
                                 interval: DateInterval(start: dayStart, end: dayEnd))
    }

    static func visibleWorkoutReview(_ candidate: WorkoutReviewCandidate?,
                                     confirmedWorkouts: [UserConfirmedWorkout],
                                     selectedDay: Date,
                                     calendar: Calendar) -> WorkoutReviewCandidate? {
        guard let candidate else { return nil }
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart),
              candidate.end > dayStart,
              candidate.start < dayEnd,
              !overlapsConfirmedWorkout(start: candidate.start,
                                        end: candidate.end,
                                        confirmedWorkouts: confirmedWorkouts) else { return nil }
        return candidate
    }

    static func visibleWorkoutReview(_ candidate: WorkoutReviewCandidate?,
                                     confirmedWorkouts: [UserConfirmedWorkout],
                                     interval: DateInterval) -> WorkoutReviewCandidate? {
        guard let candidate,
              candidate.end > interval.start,
              candidate.start < interval.end,
              !overlapsConfirmedWorkout(start: candidate.start,
                                        end: candidate.end,
                                        confirmedWorkouts: confirmedWorkouts) else { return nil }
        return candidate
    }
}

struct AtriaActivitySectionsCache<Value> {
    struct Request: Equatable {
        let key: AtriaActivitySectionsRequestKey
        let generation: Int
    }

    private(set) var value: Value?
    private(set) var publishedKey: AtriaActivitySectionsRequestKey?
    private(set) var pendingRequest: Request?
    private var generation = 0

    var isLoadingWithoutValue: Bool { value == nil }

    func value(for key: AtriaActivitySectionsRequestKey) -> Value? {
        publishedKey == key ? value : nil
    }

    mutating func request(for key: AtriaActivitySectionsRequestKey) -> Request? {
        if publishedKey == key {
            if pendingRequest != nil {
                generation &+= 1
                pendingRequest = nil
            }
            return nil
        }
        if pendingRequest?.key == key { return nil }

        generation &+= 1
        let request = Request(key: key, generation: generation)
        pendingRequest = request
        return request
    }

    @discardableResult
    mutating func publish(_ newValue: Value, for request: Request) -> Bool {
        guard pendingRequest == request, generation == request.generation else { return false }
        value = newValue
        publishedKey = request.key
        pendingRequest = nil
        return true
    }

    mutating func cancel(_ request: Request) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
    }
}

/// Pure, testable workout projection for the selected-day Activity timeline.
/// Intervals are packed into the minimum deterministic set of collision-free
/// lanes so a busy day stays compact without allowing overlapping entries to
/// visually collapse. The interval is clipped only for presentation; persisted
/// workout boundaries remain untouched.
struct AtriaActivityTimelineWorkoutSpan: Equatable, Identifiable {
    let id: String
    let lane: String
    let start: Date
    let end: Date
    let label: String
    let icon: String
}

struct AtriaActivityTimelineAxisTick: Equatable, Identifiable {
    let date: Date
    let label: String
    let accessibilityLabel: String

    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}

struct AtriaActivityTimelineLaneInterval: Equatable {
    let id: String
    let start: Date
    let end: Date
}

enum AtriaActivityTimelineLanePacker {
    /// Greedy interval partitioning is optimal when intervals are visited by
    /// start time. A lane becomes reusable at an interval's half-open end.
    static func assignments(for intervals: [AtriaActivityTimelineLaneInterval]) -> [String: Int] {
        let ordered = intervals
            .filter { $0.end > $0.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }
        var laneEnds: [Date] = []
        var result: [String: Int] = [:]
        result.reserveCapacity(ordered.count)

        for interval in ordered {
            if let reusable = laneEnds.firstIndex(where: { $0 <= interval.start }) {
                result[interval.id] = reusable
                laneEnds[reusable] = interval.end
            } else {
                result[interval.id] = laneEnds.count
                laneEnds.append(interval.end)
            }
        }
        return result
    }
}

/// Compact, deterministic ticks for the 24-hour Activity timeline. Fixed
/// six-hour anchors make position immediately readable; the trailing tick is
/// live for today and the next-midnight boundary for completed days. A live
/// label replaces an anchor when they would render too close together, rather
/// than stacking two labels into the same few points of horizontal space.
enum AtriaActivityTimelineAxis {
    private static let minimumLiveTickSeparation: TimeInterval = 2 * 3_600

    static func ticks(selectedDay: Date,
                      calendar: Calendar,
                      now: Date = Date()) -> [AtriaActivityTimelineAxisTick] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        let anchors: [(hour: Int, label: String, accessibility: String)] = [
            (0, "12a", "12 AM"),
            (6, "6a", "6 AM"),
            (12, "12p", "12 PM"),
            (18, "6p", "6 PM")
        ]
        var ticks = anchors.compactMap { anchor -> AtriaActivityTimelineAxisTick? in
            guard let date = calendar.date(byAdding: .hour,
                                           value: anchor.hour,
                                           to: dayStart) else { return nil }
            return AtriaActivityTimelineAxisTick(date: date,
                                                 label: anchor.label,
                                                 accessibilityLabel: anchor.accessibility)
        }
        if calendar.isDate(selectedDay, inSameDayAs: now) {
            let boundedNow = min(max(now, dayStart), dayEnd)
            ticks.removeAll {
                abs($0.date.timeIntervalSince(boundedNow)) < minimumLiveTickSeparation
            }
            ticks.append(AtriaActivityTimelineAxisTick(date: boundedNow,
                                                       label: "Now",
                                                       accessibilityLabel: "Now"))
        } else {
            ticks.append(AtriaActivityTimelineAxisTick(date: dayEnd,
                                                       label: "12a",
                                                       accessibilityLabel: "End of day, 12 AM"))
        }
        return ticks
    }

    static func ticks(interval: DateInterval,
                      isCurrent: Bool,
                      calendar: Calendar) -> [AtriaActivityTimelineAxisTick] {
        guard interval.end > interval.start else { return [] }
        var dates = [interval.start]
        var cursor = calendar.nextDate(after: interval.start,
                                       matching: DateComponents(minute: 0, second: 0),
                                       matchingPolicy: .nextTime) ?? interval.end
        while cursor < interval.end {
            if cursor.timeIntervalSince(dates.last ?? interval.start) >= 4 * 3_600 {
                dates.append(cursor)
            }
            guard let next = calendar.date(byAdding: .hour, value: 6, to: cursor), next > cursor else { break }
            cursor = next
        }
        if interval.end.timeIntervalSince(dates.last ?? interval.start) >= 2 * 3_600 || dates.count == 1 {
            dates.append(interval.end)
        } else {
            dates[dates.count - 1] = interval.end
        }
        return dates.enumerated().map { index, date in
            let isEnd = index == dates.count - 1
            let label = isEnd && isCurrent ? "Now" : date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            return AtriaActivityTimelineAxisTick(date: date,
                                                 label: label,
                                                 accessibilityLabel: isEnd && isCurrent ? "Now" : date.formatted(date: .omitted, time: .shortened))
        }
    }

    static func tick(at date: Date,
                     in ticks: [AtriaActivityTimelineAxisTick]) -> AtriaActivityTimelineAxisTick? {
        ticks.first { abs($0.date.timeIntervalSince(date)) < 0.5 }
    }
}

/// One canonical selected-day predicate for both the chart and its tappable
/// workout rows. A workout belongs to every civil day its half-open interval
/// overlaps, so an effort that crosses midnight never appears in the graph
/// without a matching detail row below it.
enum AtriaActivitySelectedDayWorkouts {
    static func overlapping(_ workouts: [UserConfirmedWorkout],
                            interval: DateInterval) -> [UserConfirmedWorkout] {
        // Sub-minute accidental live fragments never render as Activity rows
        // or timeline spans (2026-07-31 device review); the record stays saved.
        AtriaWorkoutMetricPresentation.presentableWorkouts(workouts)
            .filter { $0.end > $0.start && $0.end > interval.start && $0.start < interval.end }
    }
    static func overlapping(_ workouts: [UserConfirmedWorkout],
                            selectedDay: Date,
                            calendar: Calendar) -> [UserConfirmedWorkout] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        return AtriaWorkoutMetricPresentation.presentableWorkouts(workouts).filter {
            $0.end > $0.start && $0.end > dayStart && $0.start < dayEnd
        }
    }
}

/// One canonical sleep/nap projection for the Activity row list and timeline.
/// A pending detector window that substantially overlaps an already-saved
/// night is not a second activity. Confirmed main sleep belongs to its final-
/// wake day; naps and pending windows remain overlap-based evidence.
enum AtriaActivitySelectedDaySleeps {
    static func canonical(snapshot: SleepHistorySnapshot,
                          pendingReview: SleepHistorySnapshot.Night?,
                          napReviewCandidates: [SleepHistorySnapshot.Night] = []) -> [SleepHistorySnapshot.Night] {
        var byID = (snapshot.nights + snapshot.additionalMainNights + snapshot.napNights)
            .reduce(into: [String: SleepHistorySnapshot.Night]()) { result, night in
                result[night.id] = night
            }
        if let pendingReview,
           !pendingReview.confirmed,
           !byID.values.contains(where: { substantiallyOverlaps($0, pendingReview) }) {
            byID[pendingReview.id] = pendingReview
        }
        // Review-worthy naps surface as their own detection rows. A nap that
        // already maps to a confirmed/candidate night (or the main-sleep review
        // card) is deduped so a single window is never shown twice.
        for nap in napReviewCandidates where !nap.confirmed {
            guard !byID.values.contains(where: { substantiallyOverlaps($0, nap) }) else { continue }
            byID[nap.id] = nap
        }
        return byID.values.sorted {
            let lhs = $0.start ?? $0.day
            let rhs = $1.start ?? $1.day
            if lhs != rhs { return lhs < rhs }
            return $0.id < $1.id
        }
    }

    static func overlapping(snapshot: SleepHistorySnapshot,
                            pendingReview: SleepHistorySnapshot.Night?,
                            napReviewCandidates: [SleepHistorySnapshot.Night] = [],
                            selectedDay: Date,
                            calendar: Calendar) -> [SleepHistorySnapshot.Night] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return overlapping(snapshot: snapshot,
                           pendingReview: pendingReview,
                           napReviewCandidates: napReviewCandidates,
                           interval: DateInterval(start: dayStart, end: dayEnd),
                           calendar: calendar,
                           mainSleepOwnershipDay: dayStart)
    }

    static func overlapping(snapshot: SleepHistorySnapshot,
                            pendingReview: SleepHistorySnapshot.Night?,
                            napReviewCandidates: [SleepHistorySnapshot.Night] = [],
                            interval: DateInterval,
                            calendar: Calendar,
                            includeStartBoundarySleep: Bool = false,
                            mainSleepOwnershipDay: Date? = nil) -> [SleepHistorySnapshot.Night] {
        canonical(snapshot: snapshot,
                  pendingReview: pendingReview,
                  napReviewCandidates: napReviewCandidates).filter { night in
            // A confirmed non-nap is a wake-boundary record. It belongs to the
            // date on which its final wake was recorded, never to every civil
            // date overlapped by its bedtime-to-wake interval. Naps and pending
            // detections remain interval-overlap records as before.
            if let mainSleepOwnershipDay,
               night.confirmed,
               !night.isNapEvidence {
                // `Night.day` is materialized in the calendar that built the
                // snapshot. Activity may later project that snapshot in a new
                // local calendar (travel) or a deterministic test calendar.
                // Re-derive wake ownership from the factual boundary and its
                // event-local timezone so the same saved sleep cannot vanish
                // or move dates when those calendars differ. Legacy day-only
                // records retain their stored label as the fail-closed fallback.
                let ownershipDay = night.end.map {
                    EventCivilTime.day(
                        containing: $0,
                        eventTimeZoneIdentifier: night.eventTimeZoneIdentifier,
                        outputCalendar: calendar
                    )
                } ?? calendar.startOfDay(for: night.day)
                return calendar.isDate(ownershipDay,
                                       inSameDayAs: mainSleepOwnershipDay)
            }
            if let start = night.start, let end = night.end, end > start {
                // The CURRENT physiological day begins at the anchoring main
                // sleep's WAKE, so that sleep ends exactly at `interval.start`.
                // A strict `end > interval.start` therefore hides the very sleep
                // that defines the day — the moment it is confirmed it leaves the
                // review-card slot and, ending exactly on the boundary, is dropped
                // from both the timeline and the row list, so it silently vanishes.
                // For the current day, admit a sleep that ends exactly at the day
                // start so "the sleep you woke from" stays visible in today.
                let overlapsStart = includeStartBoundarySleep
                    ? end >= interval.start
                    : end > interval.start
                return overlapsStart && start < interval.end
            }
            return calendar.isDate(night.day,
                                   inSameDayAs: mainSleepOwnershipDay ?? interval.start)
        }
    }

    private static func substantiallyOverlaps(_ lhs: SleepHistorySnapshot.Night,
                                               _ rhs: SleepHistorySnapshot.Night) -> Bool {
        guard let lhsStart = lhs.start, let lhsEnd = lhs.end,
              let rhsStart = rhs.start, let rhsEnd = rhs.end,
              lhsEnd > lhsStart, rhsEnd > rhsStart else {
            return lhs.id == rhs.id
        }
        let overlap = min(lhsEnd, rhsEnd).timeIntervalSince(max(lhsStart, rhsStart))
        let shortest = min(lhsEnd.timeIntervalSince(lhsStart), rhsEnd.timeIntervalSince(rhsStart))
        return overlap > 0 && overlap / shortest >= 0.70
    }
}

enum AtriaActivitySleepStatusPresentation {
    static func badge(confirmed: Bool, confidence: String) -> String {
        guard !confirmed else { return "Confirmed" }
        let normalized = confidence
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
        switch normalized.lowercased() {
        case "", "candidate", "detected", "pending", "review needed":
            return "Review"
        default:
            return normalized
        }
    }
}

/// Resolves the symbol that actually describes the saved activity, including
/// older broad-container records such as `Sport · Basketball`,
/// `Cardio · Stair climber`, or `Other` with a meaningful user label. The
/// general catalog resolver intentionally preserves an exact persisted type;
/// Activity needs the more specific subtype for its row and timeline marker.
enum AtriaActivityDisplayIcon {
    static func icon(activityType: String?, subtype: String?, label: String) -> String {
        let base = AtriaWorkoutActivityType.resolved(activityType: activityType,
                                                     subtype: subtype,
                                                     label: label)
        let inferred = AtriaWorkoutActivityType.resolved(activityType: nil,
                                                         subtype: subtype,
                                                         label: label)
        switch base {
        case .other:
            return inferred.icon
        case .sport:
            let sportSpecific: Set<AtriaWorkoutActivityType> = [
                .basketball, .football, .cricket, .tennis, .badminton,
                .volleyball, .golf, .martialArts, .boxing, .climbing, .hiking
            ]
            return sportSpecific.contains(inferred) ? inferred.icon : base.icon
        case .cardio:
            let cardioSpecific: Set<AtriaWorkoutActivityType> = [
                .walking, .running, .cycling, .swimming, .rowing,
                .elliptical, .stairClimber, .jumpRope
            ]
            return cardioSpecific.contains(inferred) ? inferred.icon : base.icon
        case .hiit:
            return inferred == .jumpRope ? inferred.icon : base.icon
        default:
            return base.icon
        }
    }
}

struct AtriaDetectedActivityPresentation: Equatable {
    let title: String
    let icon: String

    static func make(kind: ActivityDetection.Kind,
                     suggestedActivityType: AtriaWorkoutActivityType?) -> Self {
        if let suggestedActivityType {
            return Self(title: "\(suggestedActivityType.rawValue) suggested",
                        icon: suggestedActivityType.icon)
        }
        return Self(title: kind == .workout ? "Workout detected" : "Activity detected",
                    icon: kind == .workout ? "figure.mixed.cardio" : "waveform.path.ecg")
    }
}

enum AtriaActivityTimelineBuilder {
    static func workoutSpans(workouts: [UserConfirmedWorkout],
                             interval: DateInterval) -> [AtriaActivityTimelineWorkoutSpan] {
        let projected = AtriaActivitySelectedDayWorkouts.overlapping(workouts, interval: interval).map { workout in
            AtriaActivityTimelineWorkoutSpan(
                id: "workout-\(workout.id)",
                lane: "",
                start: max(workout.start, interval.start),
                end: min(workout.end, interval.end),
                label: workout.activitySubtype ?? workout.activityType ?? workout.label,
                icon: AtriaActivityDisplayIcon.icon(activityType: workout.activityType,
                                                    subtype: workout.activitySubtype,
                                                    label: workout.label)
            )
        }.sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
        let assignments = AtriaActivityTimelineLanePacker.assignments(for: projected.map {
            AtriaActivityTimelineLaneInterval(id: $0.id, start: $0.start, end: $0.end)
        })
        return projected.map {
            AtriaActivityTimelineWorkoutSpan(id: $0.id,
                                             lane: "workout-\(assignments[$0.id] ?? 0)",
                                             start: $0.start,
                                             end: $0.end,
                                             label: $0.label,
                                             icon: $0.icon)
        }
    }

    static func workoutSpans(workouts: [UserConfirmedWorkout],
                             selectedDay: Date,
                             calendar: Calendar) -> [AtriaActivityTimelineWorkoutSpan] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }

        let projected = AtriaActivitySelectedDayWorkouts.overlapping(workouts,
                                                                     selectedDay: selectedDay,
                                                                     calendar: calendar).map { workout in
            return AtriaActivityTimelineWorkoutSpan(
                id: "workout-\(workout.id)",
                lane: "",
                start: max(workout.start, dayStart),
                end: min(workout.end, dayEnd),
                label: workout.activitySubtype ?? workout.activityType ?? workout.label,
                icon: AtriaActivityDisplayIcon.icon(activityType: workout.activityType,
                                                    subtype: workout.activitySubtype,
                                                    label: workout.label)
            )
        }
        .sorted {
            if $0.start == $1.start { return $0.id < $1.id }
            return $0.start < $1.start
        }
        let assignments = AtriaActivityTimelineLanePacker.assignments(for: projected.map {
            AtriaActivityTimelineLaneInterval(id: $0.id, start: $0.start, end: $0.end)
        })
        return projected.map {
            AtriaActivityTimelineWorkoutSpan(id: $0.id,
                                             lane: "workout-\(assignments[$0.id] ?? 0)",
                                             start: $0.start,
                                             end: $0.end,
                                             label: $0.label,
                                             icon: $0.icon)
        }
    }
}

/// A real recorded point selected for the compact Activity heart-rate trace.
/// `segment` changes across material capture gaps so Charts never connects two
/// observations through time when the strap was not read.
struct AtriaActivityTimelineHeartRatePoint: Identifiable, Equatable, Sendable {
    let id: Int
    let t: Date
    let bpm: Int
    let segment: Int
    let isOnlyPointInSegment: Bool
}

/// Sendable display snapshot of one measured stress observation. The source
/// history can include restored local readings; this value keeps selected-window
/// reduction off the main actor without changing any recorded timestamp/value.
struct AtriaActivityTimelineStressSample: Equatable, Sendable {
    let t: Date
    let score: Double
    let levelRawValue: Int
    /// Compatibility break marker for a rejected legacy evidence point. All
    /// complete v3 facts—including HR-only estimates—share one numeric line.
    let startsNewSegment: Bool

    init(t: Date,
         score: Double,
         levelRawValue: Int,
         startsNewSegment: Bool = false) {
        self.t = t
        self.score = score
        self.levelRawValue = levelRawValue
        self.startsNewSegment = startsNewSegment
    }
}

/// Immutable COW snapshot transferred to the utility task. Stress history is a
/// value array whose points are immutable; the wrapper documents that ownership
/// boundary without mapping the entire 48-hour ring on MainActor every 30s.
private struct AtriaActivityTimelineStressSourceSnapshot: Sendable {
    let history: [AtriaStressMonitorStore.StressHistoryPoint]
}

/// One honesty policy for Activity's compact timeline and workout detail. Empty
/// retained history, an archive still loading, a failed restore, and a day older
/// than the bounded detailed-history window are different product states.
enum AtriaActivityStressHistoryPresentation {
    static func emptyTimelineMessage(
        loadState: AtriaStressHistoryLoadState,
        interval: DateInterval,
        isCurrentPhysiologicalDay: Bool,
        currentState: AtriaStressState,
        now: Date = Date()
    ) -> String {
        switch loadState {
        case .loading:
            return "Loading saved stress readings…"
        case .unavailable:
            return "Saved stress history couldn’t be read. New measured readings will still appear here."
        case .disabled, .loaded:
            break
        }

        let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        if interval.end <= cutoff {
            return "Detailed stress readings are kept for the past two days; this day is outside that window."
        }
        if isCurrentPhysiologicalDay {
            if currentState.minuteFact?.isHROnly == true
                || currentState.evidenceMode == .cardiacArousal {
                return "An HR-only physiological-stress estimate is available at lower confidence."
            }
            if currentState.kind == .scored {
                return "No measured stress reading has been recorded since waking."
            }
            let detail = AtriaStressPresentation.make(state: currentState).detail
            return detail.isEmpty
                ? "Waiting for a measured stress reading since waking."
                : "Since waking: \(detail)"
        }
        if interval.start < cutoff {
            return "No retained stress readings were recorded in the selected day range."
        }
        return "No measured stress readings were recorded in the selected day range."
    }

    static func workoutEmptyMessage(
        loadState: AtriaStressHistoryLoadState,
        workoutEnd: Date,
        now: Date = Date()
    ) -> String {
        switch loadState {
        case .loading:
            return "Loading saved stress readings…"
        case .unavailable:
            return "Saved stress history couldn’t be read for this workout."
        case .disabled, .loaded:
            let cutoff = now.addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
            if workoutEnd <= cutoff {
                return "Detailed stress readings are kept for the past two days; this workout is outside that window."
            }
            return "No measured stress readings were recorded during this workout."
        }
    }
}

struct AtriaActivityTimelineStressPoint: Identifiable, Equatable, Sendable {
    let id: Int
    let t: Date
    let score: Double
    let levelRawValue: Int
    let segment: Int
    let isOnlyPointInSegment: Bool

    var level: AtriaStressLevel? { AtriaStressLevel(rawValue: levelRawValue) }
}

struct AtriaActivityTimelineHeartRateProjection: Equatable, Sendable {
    let points: [AtriaActivityTimelineHeartRatePoint]
    let measuredSampleCount: Int
    /// Full factual range before visual reduction. The plotted representatives
    /// intentionally suppress isolated spikes, but accessibility must not pair
    /// the full sample count with a range computed from only that reduced set.
    let measuredMinimumBPM: Int?
    let measuredMaximumBPM: Int?

    static let empty = Self(points: [],
                            measuredSampleCount: 0,
                            measuredMinimumBPM: nil,
                            measuredMaximumBPM: nil)
}

struct AtriaActivityTimelineStressProjection: Equatable, Sendable {
    let points: [AtriaActivityTimelineStressPoint]
    let measuredSampleCount: Int

    static let empty = Self(points: [], measuredSampleCount: 0)
}

/// Bounded selected-day projections for the two Activity monitor traces.
/// Reduction selects existing samples at stable indices; it never creates an
/// averaged value or a synthetic timestamp. Each real gap remains a new series.
/// One shared exact-window measured-HR union for every saved/current HR trace.
/// It merges the three real sources — canonical saved-session points, the
/// durable archive, and the retained observed history behind successful minute
/// facts — into one deduplicated, in-window point set. Nothing is interpolated;
/// byte-identical observations collapse; real gaps are left for the segmenter to
/// break so the saved-day HR card and the Overnight HR card cannot disagree.
enum AtriaExactWindowHeartRate {
    static func union(
        canonical: [HistoricalArchive.HeartRatePoint],
        archive: [HistoricalArchive.HeartRatePoint],
        observed: [HistoricalArchive.HeartRatePoint],
        interval: DateInterval
    ) -> [HistoricalArchive.HeartRatePoint] {
        let inWindow = (canonical + archive + observed).filter {
            $0.t >= interval.start && $0.t < interval.end && (25...240).contains($0.bpm)
        }
        let sorted = inWindow.sorted {
            if $0.t != $1.t { return $0.t < $1.t }
            return $0.bpm < $1.bpm
        }
        var result: [HistoricalArchive.HeartRatePoint] = []
        result.reserveCapacity(sorted.count)
        for point in sorted where result.last != point {
            result.append(point)
        }
        return result
    }
}

enum AtriaActivityTimelineSignalProjection {
    /// Ambient/all-day traces may visually join a brief telemetry hiccup. This
    /// is presentation-only: the archive and measured-sample count remain
    /// unchanged, and a larger gap is still a separate Charts series.
    static let ambientHeartRateGapThreshold = AtriaChartVisualGrammar.traceDisplayContinuityGap
    /// Workout traces keep the stricter boundary because a short hole can hide
    /// an interval that materially changes workout load and zone interpretation.
    static let workoutHeartRateGapThreshold: TimeInterval = 2 * 60
    // Display-continuity policy (matches the HR trace and the ambient/live
    // stress card): brief signal hiccups inside a five-minute window read as one
    // continuous run, while a genuine >5-min dropout still ends the run and
    // leaves the interval blank. The strict fact/coverage thresholds
    // (`maximumFactContinuityGap`) are untouched — this governs only the
    // rendered trace. The `startsNewSegment` break below stays a hard boundary.
    static let stressGapThreshold = AtriaChartVisualGrammar.traceDisplayContinuityGap

    static func heartRate(
        samples: [HistoricalArchive.HeartRatePoint],
        interval: DateInterval,
        targetPointCount: Int = 240
    ) -> AtriaActivityTimelineHeartRateProjection {
        guard interval.end > interval.start else { return .empty }
        let measured = samples
            .filter { $0.t >= interval.start && $0.t < interval.end && $0.bpm > 0 }
            .sorted {
                if $0.t != $1.t { return $0.t < $1.t }
                return $0.bpm < $1.bpm
            }
        let runs = segmented(measured, date: \.t, gapThreshold: ambientHeartRateGapThreshold)
        var points: [AtriaActivityTimelineHeartRatePoint] = []
        points.reserveCapacity(min(measured.count, max(targetPointCount, runs.count * 2)))
        var id = 0
        for (segment, run) in runs.enumerated() {
            let selected = selectRepresentativeHeartRateSamples(
                run,
                totalSampleCount: measured.count,
                targetPointCount: targetPointCount
            )
            let singleton = selected.count == 1
            for sample in selected {
                points.append(.init(id: id,
                                    t: sample.t,
                                    bpm: sample.bpm,
                                    segment: segment,
                                    isOnlyPointInSegment: singleton))
                id += 1
            }
        }
        return .init(points: points,
                     measuredSampleCount: measured.count,
                     measuredMinimumBPM: measured.map(\.bpm).min(),
                     measuredMaximumBPM: measured.map(\.bpm).max())
    }

    static func stress(
        samples: [AtriaActivityTimelineStressSample],
        interval: DateInterval,
        targetPointCount: Int = 180
    ) -> AtriaActivityTimelineStressProjection {
        guard interval.end > interval.start else { return .empty }
        let measured = samples
            .filter {
                $0.t >= interval.start && $0.t < interval.end
                    && $0.score.isFinite && (0...3).contains($0.score)
            }
            .sorted {
                if $0.t != $1.t { return $0.t < $1.t }
                return $0.score < $1.score
            }
        let runs = segmentedStress(measured)
        var points: [AtriaActivityTimelineStressPoint] = []
        points.reserveCapacity(min(measured.count, max(targetPointCount, runs.count * 2)))
        var id = 0
        for (segment, run) in runs.enumerated() {
            let selected = selectRealSamples(run,
                                             totalSampleCount: measured.count,
                                             targetPointCount: targetPointCount,
                                             value: { $0.score })
            let singleton = selected.count == 1
            for sample in selected {
                points.append(.init(id: id,
                                    t: sample.t,
                                    score: sample.score,
                                    levelRawValue: sample.levelRawValue,
                                    segment: segment,
                                    isOnlyPointInSegment: singleton))
                id += 1
            }
        }
        return .init(points: points, measuredSampleCount: measured.count)
    }

    private static func segmentedStress(
        _ samples: [AtriaActivityTimelineStressSample]
    ) -> [[AtriaActivityTimelineStressSample]] {
        guard !samples.isEmpty else { return [] }
        var runs: [[AtriaActivityTimelineStressSample]] = []
        var current: [AtriaActivityTimelineStressSample] = []
        for sample in samples {
            if let previous = current.last,
               sample.startsNewSegment
                    || sample.t.timeIntervalSince(previous.t) > stressGapThreshold {
                runs.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func segmented<Sample>(
        _ samples: [Sample],
        date: KeyPath<Sample, Date>,
        gapThreshold: TimeInterval
    ) -> [[Sample]] {
        guard !samples.isEmpty else { return [] }
        var runs: [[Sample]] = []
        var current: [Sample] = []
        for sample in samples {
            if let previous = current.last,
               sample[keyPath: date].timeIntervalSince(previous[keyPath: date]) > gapThreshold {
                runs.append(current)
                current = []
            }
            current.append(sample)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// A compact all-day HR line should show the measured local tendency, not
    /// alternate between every bucket's minimum and maximum. Each interior
    /// bucket therefore contributes the *real observation* nearest its local
    /// mean. No BPM or timestamp is synthesized; source extrema remain in the
    /// underlying data and measured-sample accounting, while the inline trace
    /// becomes readable. First and last observations remain exact anchors.
    private static func selectRepresentativeHeartRateSamples(
        _ samples: [HistoricalArchive.HeartRatePoint],
        totalSampleCount: Int,
        targetPointCount: Int
    ) -> [HistoricalArchive.HeartRatePoint] {
        guard samples.count > 1 else { return samples }
        guard targetPointCount > 1, totalSampleCount > targetPointCount else { return samples }
        let proportional = Int((Double(samples.count) / Double(totalSampleCount)
                                * Double(targetPointCount)).rounded())
        let budget = min(samples.count, max(2, proportional))
        guard samples.count > budget else { return samples }
        guard budget > 2 else { return [samples[0], samples[samples.count - 1]] }

        let interiorCount = samples.count - 2
        let bucketCount = budget - 2
        var selectedIndices = [0]
        selectedIndices.reserveCapacity(budget)
        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }
            let mean = Double(samples[lower..<upper].reduce(0) { $0 + $1.bpm })
                / Double(upper - lower)
            let midpoint = Double(lower + upper - 1) / 2
            let representative = (lower..<upper).min { lhs, rhs in
                let lhsDistance = abs(Double(samples[lhs].bpm) - mean)
                let rhsDistance = abs(Double(samples[rhs].bpm) - mean)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                let lhsTimeDistance = abs(Double(lhs) - midpoint)
                let rhsTimeDistance = abs(Double(rhs) - midpoint)
                if lhsTimeDistance != rhsTimeDistance { return lhsTimeDistance < rhsTimeDistance }
                return lhs < rhs
            }
            if let representative { selectedIndices.append(representative) }
        }
        selectedIndices.append(samples.count - 1)
        return selectedIndices.map { samples[$0] }
    }

    /// Keeps the first/last observation plus real min/max observations from
    /// bounded interior buckets. Peaks survive reduction without averaged
    /// values or synthetic timestamps. A run may receive two points beyond the
    /// nominal proportional budget so it never collapses into a fabricated line.
    private static func selectRealSamples<Sample>(
        _ samples: [Sample],
        totalSampleCount: Int,
        targetPointCount: Int,
        value: (Sample) -> Double
    ) -> [Sample] {
        guard samples.count > 1 else { return samples }
        guard targetPointCount > 1, totalSampleCount > targetPointCount else { return samples }
        let proportional = Int((Double(samples.count) / Double(totalSampleCount)
                                * Double(targetPointCount)).rounded())
        let budget = min(samples.count, max(2, proportional))
        guard samples.count > budget else { return samples }
        guard budget >= 4 else { return [samples[0], samples[samples.count - 1]] }

        let interiorCount = samples.count - 2
        let bucketCount = max(1, (budget - 2) / 2)
        var selectedIndices = [0]
        selectedIndices.reserveCapacity(bucketCount * 2 + 2)
        for bucket in 0..<bucketCount {
            let lower = 1 + bucket * interiorCount / bucketCount
            let upper = 1 + (bucket + 1) * interiorCount / bucketCount
            guard lower < upper else { continue }
            var minimum = lower
            var maximum = lower
            for index in (lower + 1)..<upper {
                if value(samples[index]) < value(samples[minimum]) { minimum = index }
                if value(samples[index]) > value(samples[maximum]) { maximum = index }
            }
            selectedIndices.append(minimum)
            if maximum != minimum { selectedIndices.append(maximum) }
        }
        selectedIndices.append(samples.count - 1)
        return Array(Set(selectedIndices)).sorted().map { samples[$0] }
    }
}

/// Inputs and visible slices for the single Activity marker lane. When saved
/// intervals conflict, a higher-trust interval owns only the overlapping time;
/// the lower-trust event remains visible before/after it and in the row list.
/// No event is shifted to a time at which it did not happen.
struct AtriaActivityTimelineMarkerInterval: Equatable, Sendable {
    let id: String
    let start: Date
    let end: Date
    let priority: Int
}

struct AtriaActivityTimelineMarkerSlice: Equatable, Identifiable, Sendable {
    let id: String
    let sourceID: String
    let start: Date
    let end: Date
}

enum AtriaActivityTimelineMarkerProjection {
    static func nonOverlappingSlices(
        _ intervals: [AtriaActivityTimelineMarkerInterval]
    ) -> [AtriaActivityTimelineMarkerSlice] {
        let ordered = intervals
            .filter { $0.end > $0.start }
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id < $1.id
            }
        var occupied: [(start: Date, end: Date)] = []
        var output: [AtriaActivityTimelineMarkerSlice] = []

        for interval in ordered {
            var visible = [(start: interval.start, end: interval.end)]
            for cover in occupied {
                visible = visible.flatMap { piece in
                    subtract(cover: cover, from: piece)
                }
                if visible.isEmpty { break }
            }
            for (index, piece) in visible.enumerated() where piece.end > piece.start {
                let keepsWholeInterval = visible.count == 1
                    && piece.start == interval.start && piece.end == interval.end
                output.append(.init(id: keepsWholeInterval
                                        ? interval.id
                                        : "\(interval.id)-visible-\(index)",
                                    sourceID: interval.id,
                                    start: piece.start,
                                    end: piece.end))
            }
            occupied = merged(occupied + visible)
        }
        return output.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id < $1.id
        }
    }

    private static func subtract(
        cover: (start: Date, end: Date),
        from piece: (start: Date, end: Date)
    ) -> [(start: Date, end: Date)] {
        guard cover.end > piece.start, cover.start < piece.end else { return [piece] }
        var remainder: [(start: Date, end: Date)] = []
        if cover.start > piece.start {
            remainder.append((piece.start, min(cover.start, piece.end)))
        }
        if cover.end < piece.end {
            remainder.append((max(cover.end, piece.start), piece.end))
        }
        return remainder
    }

    private static func merged(
        _ intervals: [(start: Date, end: Date)]
    ) -> [(start: Date, end: Date)] {
        let ordered = intervals
            .filter { $0.end > $0.start }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
        var result: [(start: Date, end: Date)] = []
        for interval in ordered {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = (last.start, max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }
}

/// Prevents a fast Share tap from racing the asynchronous route read. The tap
/// is retained while the saved route is prepared, then consumed exactly once
/// so a routed workout never opens a map-less social card merely because disk
/// I/O lost a race with the user.
struct AtriaWorkoutSharePresentationGate: Equatable {
    private(set) var routeIsPrepared = false
    private(set) var requestIsPending = false

    /// Returns `true` when the sheet can present immediately. Otherwise the
    /// request remains pending until `completeRoutePreparation()`.
    mutating func requestPresentation() -> Bool {
        guard routeIsPrepared else {
            requestIsPending = true
            return false
        }
        return true
    }

    /// Marks route context authoritative and returns whether a retained tap
    /// should now present. A second completion cannot replay the same request.
    mutating func completeRoutePreparation() -> Bool {
        routeIsPrepared = true
        let shouldPresent = requestIsPending
        requestIsPending = false
        return shouldPresent
    }
}

@MainActor
private enum AtriaWorkoutRouteTransactionRecovery {
    static func recover(
        workouts: [UserConfirmedWorkout]
    ) async -> AtriaWorkoutRouteStore.TransactionRecoveryResult {
        let canonical = workouts.map { workout in
            let resolved = AtriaWorkoutActivityType.resolved(
                activityType: workout.activityType,
                subtype: workout.activitySubtype,
                label: workout.label
            )
            return AtriaWorkoutRouteStore.CanonicalWorkoutState(
                id: workout.id,
                activityType: resolved.rawValue,
                start: workout.start,
                end: workout.end
            )
        }
        return await AtriaWorkoutRouteStore.recoverPendingTransactionAsync(
            canonicalWorkouts: canonical
        )
    }
}

/// Activity Monitor — every logged activity (sleep, naps, workouts) in one
/// place, grouped by day newest-first, each row tappable to review or adjust.
///
/// Replaces the redundant Plan tab, whose two cards already live elsewhere
/// (weekly plan on Today, routine on Journal). All data is read from the live
/// Activity projection; nothing here is fabricated — a metric only renders
/// when the underlying session actually recorded it.
struct AtriaActivityMonitorTab: View {
    // Scene phase remains a low-frequency root dependency so returning from the
    // background recomputes the minute-bounded day-section request. The actual
    // timeline completeness action lives in the narrow timeline leaf below.
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var activityStore: AtriaHomeModel.ActivityStore
    /// Live stress monitor plus its bounded restored history for the selected-day
    /// card at the top of Activity. Activity is the signal + log surface; the
    /// multi-week aggregate remains in the Stress monitor.
    // Lifetime reference only. The high-frequency stress store is observed by
    // `AtriaActivityTimelineHost`, so live pulse/stress publications invalidate
    // only the monitor canvas rather than this whole activity-log hierarchy.
    let stressMonitorStore: AtriaStressMonitorStore
    /// Retained without observation for action sheets, which observe it only
    /// while presented.
    let store: SessionStore
    /// Opens the existing manual-sleep sheet seeded with this night for editing.
    let onEditSleep: (SleepHistorySnapshot.Night) -> Void
    /// Opens the manual-sleep sheet with no seed, to add a fresh sleep or nap.
    let onAddSleep: () -> Void

    @State private var workoutDetail: UserConfirmedWorkout?
    @State private var sleepDetail: SleepHistorySnapshot.Night?
    @State private var showAddWorkout = false
    @State private var reviewWorkoutWindow: ReviewWorkoutWindow?
    /// Day shown in the header timeline (user feedback 2026-07-07: "the top
    /// of activity should have an entire graph with activities listed and
    /// days can be changed").
    @State private var timelineDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var viewingCurrentPhysiologicalDay = true
    @State private var daySectionsCache = AtriaActivitySectionsCache<[DaySection]>()

    private enum TimelineSignal: String, CaseIterable, Hashable {
        case heartRate = "Heart rate"
        case stress = "Stress"
    }

    /// Current-day windows advance each minute, but re-scanning the raw archive
    /// every time the clock or stress store publishes would be unnecessary I/O.
    /// Current windows key by their wake boundary plus the bounded completeness
    /// revision; a fresh live reading extends the plotted trace between those
    /// refresh boundaries.
    private struct TimelineSignalWindowKey: Hashable {
        let start: Date
        let historicalEnd: Date?
        let isCurrent: Bool
        let completenessRevision: UInt64
        // Observed HR history is now a first-class HR source (canonical +
        // archive + observed). Fold its revision into the HR window key so a
        // stable live feed that keeps appending observed minutes re-projects
        // instead of staying stuck on the first sparse read.
        var heartRateHistoryRevision: Int = 0
    }

    private struct TimelineStressRequestKey: Hashable {
        let window: TimelineSignalWindowKey
        let historyRevision: Int
        let loadStateKey: Int
    }

    private enum Entry: Identifiable {
        case sleep(SleepHistorySnapshot.Night)
        case workout(UserConfirmedWorkout)
        case workoutReview(WorkoutReviewCandidate)
        case detection(ActivityDetection)

        var id: String {
            switch self {
            case .sleep(let night): return "sleep-\(night.id)"
            case .workout(let workout): return "workout-\(workout.id)"
            case .workoutReview(let candidate): return "workout-review-\(candidate.id)"
            case .detection(let detection): return "detection-\(detection.id.uuidString)"
            }
        }

        /// Sort anchor: when the activity happened.
        var date: Date {
            switch self {
            case .sleep(let night): return night.start ?? night.end ?? night.day
            case .workout(let workout): return workout.start
            case .workoutReview(let candidate): return candidate.start
            case .detection(let detection): return detection.start
            }
        }
    }

    private struct ReviewWorkoutWindow: Identifiable {
        let id: String
        let start: Date
        let end: Date
    }

    private struct DaySection: Identifiable {
        let id: String
        let date: Date
        let entries: [Entry]
        let recoveryEffects: [String: AtriaActivityRecoveryEffect]
    }

    private struct DaySectionsSourceSnapshot: @unchecked Sendable {
        let sleepSnapshot: SleepHistorySnapshot
        let workouts: [UserConfirmedWorkout]
        let pendingSleepReview: SleepHistorySnapshot.Night?
        let napReviewCandidates: [SleepHistorySnapshot.Night]
        let workoutReview: WorkoutReviewCandidate?
        let detections: [ActivityDetection]
        let rollups: [DailyRollupStoreEntry]
        let selectedDayStart: Date
        let interval: DateInterval
        let calendar: Calendar
        let isCurrentPhysiologicalDay: Bool
    }

    private struct DaySectionsResult: @unchecked Sendable {
        let sections: [DaySection]
    }

    var body: some View {
        let _ = scenePhase
        let calendar = Calendar.current
        let activity = activityStore.state
        let displayWindow = viewingCurrentPhysiologicalDay
            ? AtriaActivityDisplayWindow.current(now: Date(),
                                                 sleepHistory: activity.sleepHistorySnapshot,
                                                 calendar: calendar)
            : AtriaActivityDisplayWindow.historical(
                day: timelineDay,
                sleepHistory: activity.sleepHistorySnapshot,
                calendar: calendar
              )
        let requestKey = AtriaActivitySectionsRequestKey(
            sleepRevision: activity.sleepHistorySnapshotRevision,
            workoutsRevision: activity.confirmedWorkoutsRevision,
            rollupsRevision: activity.dailyRollupHistoryRevision,
            detectionsRevision: activity.historySnapshotRevision,
            reviewFingerprint: activity.reviewFingerprint,
            selectedDay: displayWindow.labelDay,
            interval: displayWindow.interval,
            isCurrentPhysiologicalDay: displayWindow.isCurrentPhysiologicalDay,
            calendar: calendar
        )

        return LazyVStack(alignment: .leading, spacing: 14) {
            activityToolbar

            let sections = daySectionsCache.value(for: requestKey) ?? []
            // Signals are useful even on a day without a saved workout. Keep
            // one monitor mounted for the selected window; its localized empty
            // state distinguishes no captured HR, pending/expired stress history,
            // and an unreadable archive instead of presenting a blank plot.
            AtriaActivityTimelineHost(activity: activity,
                                      timelineDay: timelineDay,
                                      viewingCurrentPhysiologicalDay: viewingCurrentPhysiologicalDay,
                                      stressMonitorStore: stressMonitorStore,
                                      store: store)

            if daySectionsCache.publishedKey != requestKey {
                activityLoadingState
            } else if sections.isEmpty {
                activityEmptyState
            } else {
                ForEach(sections) { section in
                    daySectionCard(section)
                }
            }
        }
        .sheet(item: $sleepDetail) { night in
            AtriaSleepActivityReviewSheet(night: night,
                                          restingBaseline: store.baseline.restingInt,
                                          typicalRestingBand: AtriaOvernightTypical.restingBand(
                                            restingHRs: activity.sleepHistorySnapshot.nights
                                                .filter { $0.confirmed && !$0.isNapEvidence }
                                                .suffix(30)
                                                .compactMap { $0.restingHR }),
                                          overnightSessions: store.sessions,
                                          overnightObservedHeartRate:
                                            stressMonitorStore.heartRateHistory.map {
                                                HistoricalArchive.HeartRatePoint(t: $0.t, bpm: $0.bpm)
                                            }) {
                sleepDetail = nil
                onEditSleep(night)
            }
        }
        .sheet(item: $workoutDetail) { workout in
            AtriaActivityWorkoutDetailSheetHost(store: store,
                                                workout: workout,
                                                stressMonitorStore: stressMonitorStore)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddWorkout) {
            AtriaAddWorkoutSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $reviewWorkoutWindow) { window in
            AtriaAddWorkoutSheet(store: store,
                                 initialStart: window.start,
                                 initialEnd: window.end,
                                 reviewCandidateID: window.id,
                                 settlingCandidateWindow: (start: window.start,
                                                           end: window.end),
                                 onDismissCandidate: {
                                     store.dismissWorkoutCandidate(start: window.start,
                                                                   end: window.end)
                                 })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: requestKey) {
            _ = await AtriaWorkoutRouteTransactionRecovery.recover(
                workouts: activity.confirmedWorkouts
            )
            await refreshDaySections(for: requestKey,
                                     activity: activity,
                                     calendar: calendar)
        }
        .onAppear {
            #if DEBUG
            guard workoutDetail == nil,
                  let fixture = Self.debugWorkoutDetailFixture else { return }
            workoutDetail = fixture
            #endif
        }
    }

    #if DEBUG
    /// Presentation-only fixtures exercise the exact production detail sheet
    /// without mutating the user's workout history or sensor state.
    private static var debugWorkoutDetailFixture: UserConfirmedWorkout? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }

        let hasZoneDistribution: Bool
        switch arguments[valueIndex] {
        case "activity-zone-detail": hasZoneDistribution = true
        case "activity-zone-unavailable": hasZoneDistribution = false
        default: return nil
        }

        let end = Date().addingTimeInterval(-8 * 60)
        let start = end.addingTimeInterval(-52 * 60)
        return UserConfirmedWorkout(
            id: "debug-activity-zone-detail",
            createdAt: end,
            start: start,
            end: end,
            label: hasZoneDistribution ? "Tempo run" : "Strength session",
            source: "debug_fixture",
            confidence: "fixture",
            sessions: 1,
            samples: hasZoneDistribution ? 2_180 : 720,
            avgHR: hasZoneDistribution ? 151 : 122,
            peakHR: hasZoneDistribution ? 181 : 151,
            p95HR: hasZoneDistribution ? 172 : 144,
            p99HR: hasZoneDistribution ? 178 : 149,
            thresholdHR: 128,
            streamCoveragePercent: hasZoneDistribution ? 96 : 54,
            observedDuration: hasZoneDistribution ? 50 * 60 : 28 * 60,
            reason: "debug activity-zone presentation fixture",
            activityType: hasZoneDistribution ? "Running" : "Strength",
            activitySubtype: hasZoneDistribution ? "Tempo" : nil,
            exerciseNames: nil,
            reviewSource: "debug_fixture",
            strain: hasZoneDistribution ? 11.7 : 5.6,
            activeEnergyKilocalories: hasZoneDistribution ? 540 : 280,
            activeEnergyConfidence: "fixture",
            zoneSeconds: hasZoneDistribution
                ? ["warmup": 460, "fatBurn": 720, "aerobic": 1_120, "anaerobic": 620, "max": 200]
                : nil
        )
    }
    #endif

    /// The navigation title already says Activity. Keep day navigation and Add
    /// in one compact control row instead of stacking a duplicate section title
    /// above a second date row.
    private var activityToolbar: some View {
        let calendar = Calendar.current
        return HStack(spacing: 4) {
            Button {
                let base = currentDisplayWindow.labelDay
                if let previous = calendar.date(byAdding: .day, value: -1, to: base) {
                    timelineDay = previous
                    viewingCurrentPhysiologicalDay = false
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Previous day")

            // WHOOP day-capsule grammar (2026-08-05 design-language pass):
            // caps letterspaced label in a capsule, chevrons outside it.
            // Tapping the capsule of a PAST day snaps back to today — the
            // capsule is inert (plain label) when already on today.
            Button {
                timelineDay = currentDisplayWindow.labelDay
                viewingCurrentPhysiologicalDay = true
            } label: {
                Text(viewingCurrentPhysiologicalDay
                     ? "Today"
                     : timelineDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .textCase(.uppercase)
                    .font(.footnote.weight(.bold))
                    .tracking(1.0)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
                    .background(.quaternary.opacity(0.5), in: Capsule(style: .continuous))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(viewingCurrentPhysiologicalDay)
            .accessibilityLabel(timelineDay.formatted(date: .complete, time: .omitted))
            .accessibilityHint(viewingCurrentPhysiologicalDay ? "" : "Returns to today")

            Button {
                let currentDay = AtriaActivityDisplayWindow.current(
                    now: Date(),
                    sleepHistory: activityStore.state.sleepHistorySnapshot,
                    calendar: calendar
                ).labelDay
                let destination = AtriaActivityDayNavigation.next(
                    from: timelineDay,
                    currentPhysiologicalDisplayDay: currentDay,
                    calendar: calendar
                )
                timelineDay = destination.day
                viewingCurrentPhysiologicalDay = destination.viewsCurrentPhysiologicalDay
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.bold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canGoToNextDay)
            .opacity(canGoToNextDay ? 1 : 0.3)
            .accessibilityLabel("Next day")

            Spacer(minLength: 4)
            addActivityMenu
        }
    }

    private var activityLoadingState: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading activity…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    /// An empty day is the most common state on this tab, and it used to be a
    /// thin pill reading "No saved or detected activity" above roughly a
    /// thousand points of blank screen — a bare negative that never said what
    /// the tab is for or what would eventually fill it. The one sentence that
    /// did explain it was the VoiceOver hint, so sighted users were the ones
    /// left without the explanation. Same statement of fact, now with the
    /// answer to "then what goes here?" visible.
    private var activityEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "calendar.badge.plus")
                .font(.title.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(.secondary.opacity(0.10), in: Circle())
                .padding(.bottom, 2)

            Text("No saved or detected activity")
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text("Workouts and sleep land here on their own once they are detected or confirmed. Use Add to log something yourself.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
    }

    private func refreshDaySections(for key: AtriaActivitySectionsRequestKey,
                                    activity: AtriaHomeModel.ActivityState,
                                    calendar: Calendar) async {
        guard let request = daySectionsCache.request(for: key) else { return }
        let source = DaySectionsSourceSnapshot(sleepSnapshot: activity.sleepHistorySnapshot,
                                               workouts: activity.confirmedWorkouts,
                                               pendingSleepReview: activity.pendingSleepReview,
                                               napReviewCandidates: activity.napReviewCandidates,
                                               workoutReview: activity.workoutReviewCandidate,
                                               detections: activity.activityDetections,
                                               rollups: activity.dailyRollupHistory,
                                               selectedDayStart: key.selectedDayStart,
                                               interval: DateInterval(start: key.intervalStart, end: key.intervalEnd),
                                               calendar: calendar,
                                               isCurrentPhysiologicalDay: key.isCurrentPhysiologicalDay)
        let preparation = Task.detached(priority: .utility) {
            Self.makeDaySections(from: source)
        }
        let result = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }
        guard !Task.isCancelled else {
            daySectionsCache.cancel(request)
            return
        }
        let currentActivity = activityStore.state
        let currentKey = AtriaActivitySectionsRequestKey(
            sleepRevision: currentActivity.sleepHistorySnapshotRevision,
            workoutsRevision: currentActivity.confirmedWorkoutsRevision,
            rollupsRevision: currentActivity.dailyRollupHistoryRevision,
            detectionsRevision: currentActivity.historySnapshotRevision,
            reviewFingerprint: currentActivity.reviewFingerprint,
            selectedDay: currentDisplayWindow.labelDay,
            interval: currentDisplayWindow.interval,
            isCurrentPhysiologicalDay: currentDisplayWindow.isCurrentPhysiologicalDay,
            calendar: .current
        )
        guard currentKey == request.key else {
            daySectionsCache.cancel(request)
            return
        }
        daySectionsCache.publish(result.sections, for: request)
    }

    nonisolated private static func makeDaySections(
        from source: DaySectionsSourceSnapshot
    ) -> DaySectionsResult {
        let sleeps = AtriaActivitySelectedDaySleeps.overlapping(
            snapshot: source.sleepSnapshot,
            pendingReview: source.pendingSleepReview,
            napReviewCandidates: source.napReviewCandidates,
            interval: source.interval,
            calendar: source.calendar,
            includeStartBoundarySleep: source.isCurrentPhysiologicalDay,
            mainSleepOwnershipDay: source.isCurrentPhysiologicalDay
                ? nil
                : source.selectedDayStart
        )
            .map(Entry.sleep)
        let selectedWorkouts = AtriaActivitySelectedDayWorkouts.overlapping(
            source.workouts,
            interval: source.interval
        )
        let workouts = selectedWorkouts.map(Entry.workout)
        let workoutReview = AtriaActivityReviewProjection.visibleWorkoutReview(
            source.workoutReview,
            confirmedWorkouts: source.workouts,
            interval: source.interval
        ).map(Entry.workoutReview)
        let detections = AtriaActivityReviewProjection.visibleDetections(
            source.detections,
            workoutReview: source.workoutReview,
            confirmedWorkouts: source.workouts,
            interval: source.interval
        ).map(Entry.detection)
        let entries = (sleeps + workouts + [workoutReview].compactMap { $0 } + detections)
            .sorted { $0.date > $1.date }
        guard !entries.isEmpty else { return DaySectionsResult(sections: []) }
        var recoveryEffects: [String: AtriaActivityRecoveryEffect] = [:]
        for workout in selectedWorkouts {
            recoveryEffects[workout.id] = AtriaActivityRecoveryEffect.make(
                workout: workout,
                rollups: source.rollups,
                sleepHistory: source.sleepSnapshot,
                calendar: source.calendar
            )
        }
        return DaySectionsResult(sections: [
            DaySection(id: String(source.selectedDayStart.timeIntervalSinceReferenceDate),
                       date: source.selectedDayStart,
                       entries: entries,
                       recoveryEffects: recoveryEffects)
        ])
    }

    /// A span of one activity clipped to the selected day, for the header
    /// timeline lanes.
    private struct TimelineSpan: Identifiable {
        let id: String
        let lane: String
        let start: Date
        let end: Date
        let tint: Color
        let label: String
        let icon: String

        var midpoint: Date {
            start.addingTimeInterval(max(0, end.timeIntervalSince(start)) / 2)
        }
    }

    private var canGoToNextDay: Bool {
        !viewingCurrentPhysiologicalDay
    }

    private var currentDisplayWindow: AtriaActivityDisplayWindow {
        let calendar = Calendar.current
        return viewingCurrentPhysiologicalDay
            ? AtriaActivityDisplayWindow.current(now: Date(),
                                                 sleepHistory: activityStore.state.sleepHistorySnapshot,
                                                 calendar: calendar)
            : AtriaActivityDisplayWindow.historical(
                day: timelineDay,
                sleepHistory: activityStore.state.sleepHistorySnapshot,
                calendar: calendar
              )
    }

    /// Owns every high-frequency stress/heart-rate dependency used by the
    /// selected-day signal canvas. Keeping the observation and live-tail state
    /// inside this leaf prevents a pulse tick from rebuilding the surrounding
    /// activity toolbar, async day grouping, and saved activity rows.
    private struct AtriaActivityTimelineHost: View {
        @Environment(\.scenePhase) private var scenePhase

        let activity: AtriaHomeModel.ActivityState
        let timelineDay: Date
        let viewingCurrentPhysiologicalDay: Bool
        @ObservedObject var stressMonitorStore: AtriaStressMonitorStore
        let store: SessionStore

        @State private var activityMemo = AtriaActivityMonitorMemo()
        @State private var selectedSignal: TimelineSignal = .heartRate
        @State private var heartRateProjection = AtriaActivityTimelineHeartRateProjection.empty
        @State private var liveHeartRateTail: [AtriaActivityTimelineHeartRatePoint] = []
        @State private var heartRateLoadState: AtriaActivityHeartRateLoadState = .idle
        @State private var heartRateProjectionWindow: AtriaActivityHeartRateWindowIdentity?
        @State private var heartRateRequestID: UUID?
        @State private var stressProjection = AtriaActivityTimelineStressProjection.empty
        @State private var stressProjectionWindowKey: TimelineSignalWindowKey?
        /// Advances only at a foreground boundary or after SessionStore has
        /// published one complete recovered-data revision. Including this in the
        /// task key backfills signal rows captured while the app was suspended,
        /// without turning per-row archive writes into repeated whole-window scans.
        @State private var timelineCompletenessRevision: UInt64 = 0

        var body: some View {
            dayTimelineCard
                .task(id: timelineSignalWindowKey) {
                    let window = currentDisplayWindow
                    await refreshTimelineHeartRate(window: window,
                                                   requestKey: timelineSignalWindowKey)
                }
                .task(id: timelineStressRequestKey) {
                    let window = currentDisplayWindow
                    await refreshTimelineStress(window: window,
                                                requestKey: timelineStressRequestKey)
                }
                .onChange(of: stressMonitorStore.liveHeartRate) { _, reading in
                    appendFreshLiveHeartRate(reading)
                }
                .onChange(of: scenePhase) { previous, current in
                    guard AtriaActivityTimelineRefreshPolicy.shouldRefresh(
                        previousScenePhase: previous,
                        scenePhase: current
                    ) else { return }
                    advanceTimelineCompletenessRevision()
                }
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: SessionStore.recoveredDataRecomputeDidPublishNotification
                    )
                ) { notification in
                    // Multiple SessionStore instances exist in tests/previews.
                    // Only the store backing this Activity tab may invalidate
                    // its selected physiological day.
                    guard let publishingStore = notification.object as? SessionStore,
                          publishingStore === store else { return }
                    advanceTimelineCompletenessRevision()
                }
        }

        private var timelineSpans: [TimelineSpan] {
            let window = currentDisplayWindow
            return activityMemo.timelineSpans(sleepRevision: activity.sleepHistorySnapshotRevision,
                                              workoutsRevision: activity.confirmedWorkoutsRevision,
                                              detectionsRevision: activity.historySnapshotRevision,
                                              reviewFingerprint: activity.reviewFingerprint,
                                              displayWindow: window,
                                              sleepSnapshot: activity.sleepHistorySnapshot,
                                              pendingSleepReview: activity.pendingSleepReview,
                                              napReviewCandidates: activity.napReviewCandidates,
                                              workouts: activity.confirmedWorkouts,
                                              workoutReview: activity.workoutReviewCandidate,
                                              detections: activity.activityDetections,
                                              calendar: .current)
        }

        private var currentDisplayWindow: AtriaActivityDisplayWindow {
            let calendar = Calendar.current
            return viewingCurrentPhysiologicalDay
                ? AtriaActivityDisplayWindow.current(now: Date(),
                                                     sleepHistory: activity.sleepHistorySnapshot,
                                                     calendar: calendar)
                : AtriaActivityDisplayWindow.historical(
                    day: timelineDay,
                    sleepHistory: activity.sleepHistorySnapshot,
                    calendar: calendar
                  )
        }

        private var timelineSignalWindowKey: TimelineSignalWindowKey {
        let window = currentDisplayWindow
        return TimelineSignalWindowKey(start: window.interval.start,
                                       historicalEnd: window.isCurrentPhysiologicalDay ? nil : window.interval.end,
                                       isCurrent: window.isCurrentPhysiologicalDay,
                                       completenessRevision: timelineCompletenessRevision,
                                       heartRateHistoryRevision:
                                        AtriaActivityHeartRateRefreshPolicy.foldedHistoryRevision(
                                            isCurrent: window.isCurrentPhysiologicalDay,
                                            liveRevision: stressMonitorStore.historyRevision))
    }

    private var timelineStressRequestKey: TimelineStressRequestKey {
        let window = timelineSignalWindowKey
        // A live append cannot change a completed historical civil day. The
        // load-state token still refreshes that day exactly once when restore
        // settles, while the current physiological window follows live revisions.
        let revision = window.isCurrent ? stressMonitorStore.historyRevision : 0
        return TimelineStressRequestKey(window: window,
                                        historyRevision: revision,
                                        loadStateKey: stressHistoryLoadStateKey)
    }

    private var stressHistoryLoadStateKey: Int {
        switch stressMonitorStore.historyLoadState {
        case .disabled: return 0
        case .loading: return 1
        case .loaded: return 2
        case .unavailable: return 3
        }
    }

    private func advanceTimelineCompletenessRevision() {
        timelineCompletenessRevision = AtriaActivityTimelineRefreshPolicy.nextRevision(
            after: timelineCompletenessRevision
        )
    }

    private enum TimelineHeartRateReadResult: Sendable {
        case loaded(AtriaActivityTimelineHeartRateProjection)
        case unavailable
    }

    /// `SavedSession` predates strict Sendable annotations. Capture the resident
    /// value/COW image on MainActor, then read only that immutable image on the
    /// utility worker. The current-cycle path combines it with a bounded recent
    /// archive tail; completed historical days retain the exact-window reader.
    private struct TimelineHeartRateSourceSnapshot: @unchecked Sendable {
        let sessions: [SavedSession]
        /// Retained observed HR behind successful minute facts. Folded in as a
        /// third exact-window source so a stable BPM feed (which stops the live
        /// tail appending) still shows more than one real point.
        let observedHeartRate: [HistoricalArchive.HeartRatePoint]
        let interval: DateInterval
        let isCurrent: Bool
    }

    private nonisolated static func readTimelineHeartRate(
        _ snapshot: TimelineHeartRateSourceSnapshot
    ) -> TimelineHeartRateReadResult {
        if snapshot.isCurrent {
            let canonical = snapshot.sessions
                .filter {
                    $0.end > snapshot.interval.start
                        && $0.start < snapshot.interval.end
                }
                .flatMap { session in
                    session.points.compactMap { point -> HistoricalArchive.HeartRatePoint? in
                        let date = session.start.addingTimeInterval(point.t)
                        guard date >= snapshot.interval.start,
                              date < snapshot.interval.end,
                              (25...240).contains(point.bpm) else { return nil }
                        return .init(t: date, bpm: point.bpm)
                    }
                }
            // The resident session image plus a small recent archive tail fill
            // live/offline rows that reached the archive but not the next settled
            // SessionStore publication. Observed history is the third source: it
            // holds the exact minute-sampled HR behind successful facts even when
            // a stable BPM keeps the change-triggered live tail from appending.
            let recent = HistoricalArchive.metricHeartRatePoints(
                since: snapshot.interval.start,
                limit: 12_000
            )
            let merged = AtriaExactWindowHeartRate.union(
                canonical: canonical,
                archive: recent,
                observed: snapshot.observedHeartRate,
                interval: snapshot.interval
            )
            return .loaded(AtriaActivityTimelineSignalProjection.heartRate(
                samples: merged,
                interval: snapshot.interval
            ))
        }

        // A completed historical day: the exact-window archive read is the
        // authority. Observed history overlapping that window is still unioned so
        // a readable-but-sparse archive gains its real observed rows. Only a nil
        // archive read AND no observed rows is a true unavailable state.
        let archive = HistoricalArchive.metricHeartRatePoints(
            start: snapshot.interval.start,
            end: snapshot.interval.end,
            maximumPoints: 100_000
        )
        if archive == nil, snapshot.observedHeartRate.isEmpty {
            return .unavailable
        }
        let merged = AtriaExactWindowHeartRate.union(
            canonical: [],
            archive: archive?.points ?? [],
            observed: snapshot.observedHeartRate,
            interval: snapshot.interval
        )
        return .loaded(AtriaActivityTimelineSignalProjection.heartRate(
            samples: merged,
            interval: snapshot.interval
        ))
    }

    @MainActor
    private func refreshTimelineHeartRate(window: AtriaActivityDisplayWindow,
                                          requestKey: TimelineSignalWindowKey) async {
        let requestID = UUID()
        let windowIdentity = AtriaActivityHeartRateWindowIdentity(
            start: requestKey.start,
            historicalEnd: requestKey.historicalEnd,
            isCurrent: requestKey.isCurrent
        )
        let preservesProjection = AtriaActivityHeartRateRefreshPolicy.preservesProjection(
            previous: heartRateProjectionWindow,
            next: windowIdentity
        )
        if !preservesProjection {
            heartRateProjection = .empty
            liveHeartRateTail = []
        }
        heartRateProjectionWindow = windowIdentity
        heartRateRequestID = requestID
        heartRateLoadState = .loading
        // Do this before any archive await: an already-observed fresh reading is
        // useful immediately and must not be hidden behind history preparation.
        appendFreshLiveHeartRate(stressMonitorStore.liveHeartRate)

        let end = window.isCurrentPhysiologicalDay ? max(window.interval.end, Date()) : window.interval.end
        let interval = DateInterval(start: window.interval.start,
                                    end: max(end, window.interval.start.addingTimeInterval(1)))
        let snapshot = TimelineHeartRateSourceSnapshot(
            sessions: window.isCurrentPhysiologicalDay ? store.sessions : [],
            observedHeartRate: stressMonitorStore.heartRateHistory.map {
                HistoricalArchive.HeartRatePoint(t: $0.t, bpm: $0.bpm)
            },
            interval: interval,
            isCurrent: window.isCurrentPhysiologicalDay
        )
        let reader = Task.detached(priority: .utility) {
            Self.readTimelineHeartRate(snapshot)
        }
        let result = await withTaskCancellationHandler {
            await reader.value
        } onCancel: {
            reader.cancel()
            Task { @MainActor in
                finishCancelledHeartRateRequest(requestID)
            }
        }

        guard heartRateRequestID == requestID else { return }
        if Task.isCancelled || requestKey != timelineSignalWindowKey {
            finishCancelledHeartRateRequest(requestID)
            return
        }

        heartRateRequestID = nil
        switch result {
        case .loaded(let projection):
            heartRateProjection = projection
            reconcileLiveHeartRateTail(after: projection)
            heartRateLoadState = AtriaActivityHeartRateRefreshPolicy.terminalState(
                readSucceeded: true
            )
        case .unavailable:
            // Same-window refreshes intentionally retain the last visible trace;
            // the state still says the new history read was unavailable.
            heartRateLoadState = AtriaActivityHeartRateRefreshPolicy.terminalState(
                readSucceeded: false
            )
        }
        appendFreshLiveHeartRate(stressMonitorStore.liveHeartRate)
    }

    @MainActor
    private func finishCancelledHeartRateRequest(_ requestID: UUID) {
        guard heartRateRequestID == requestID else { return }
        heartRateRequestID = nil
        heartRateLoadState = AtriaActivityHeartRateRefreshPolicy.cancellationState(
            hasVisiblePoints: !timelineHeartRatePoints.isEmpty
        )
    }

    @MainActor
    private func reconcileLiveHeartRateTail(
        after projection: AtriaActivityTimelineHeartRateProjection
    ) {
        let archiveEnd = projection.points.last?.t ?? .distantPast
        let retained = liveHeartRateTail
            .filter { $0.t > archiveEnd }
            .sorted { $0.t < $1.t }
        guard !retained.isEmpty else {
            liveHeartRateTail = []
            return
        }

        var rebuilt: [AtriaActivityTimelineHeartRatePoint] = []
        rebuilt.reserveCapacity(retained.count)
        var previous = projection.points.last
        var nextID = (projection.points.last?.id ?? -1) + 1
        for point in retained {
            let startsNewSegment = previous.map {
                point.t.timeIntervalSince($0.t)
                    > AtriaActivityTimelineSignalProjection.ambientHeartRateGapThreshold
            } ?? true
            let segment = startsNewSegment ? (previous?.segment ?? -1) + 1 : (previous?.segment ?? 0)
            if let lastIndex = rebuilt.indices.last,
               rebuilt[lastIndex].segment == segment,
               rebuilt[lastIndex].isOnlyPointInSegment {
                let last = rebuilt[lastIndex]
                rebuilt[lastIndex] = .init(id: last.id,
                                           t: last.t,
                                           bpm: last.bpm,
                                           segment: last.segment,
                                           isOnlyPointInSegment: false)
            }
            let next = AtriaActivityTimelineHeartRatePoint(
                id: nextID,
                t: point.t,
                bpm: point.bpm,
                segment: segment,
                isOnlyPointInSegment: startsNewSegment
            )
            rebuilt.append(next)
            previous = next
            nextID += 1
        }
        liveHeartRateTail = rebuilt
    }

    @MainActor
    private func refreshTimelineStress(window: AtriaActivityDisplayWindow,
                                       requestKey: TimelineStressRequestKey) async {
        // Preserve the visible trace across same-window live revisions. A day
        // change clears immediately so readings from the prior day are never
        // shown under the newly selected date while utility work completes.
        if stressProjectionWindowKey != requestKey.window {
            stressProjection = .empty
            stressProjectionWindowKey = requestKey.window
        }
        let end = window.isCurrentPhysiologicalDay ? max(window.interval.end, Date()) : window.interval.end
        let interval = DateInterval(start: window.interval.start,
                                    end: max(end, window.interval.start.addingTimeInterval(1)))
        let snapshot = AtriaActivityTimelineStressSourceSnapshot(
            history: stressMonitorStore.history
        )
        let result = await Task.detached(priority: .utility) {
            var samples: [AtriaActivityTimelineStressSample] = []
            var omittedEvidenceSincePreviousStress = false
            var hasStressSample = false
            for point in snapshot.history where point.t >= interval.start && point.t < interval.end {
                guard let score = point.evidenceProjection.numericStressScore else {
                    if hasStressSample {
                        omittedEvidenceSincePreviousStress = true
                    }
                    continue
                }
                samples.append(AtriaActivityTimelineStressSample(
                    t: point.t,
                    score: score,
                    levelRawValue: point.level.rawValue,
                    startsNewSegment: omittedEvidenceSincePreviousStress
                ))
                hasStressSample = true
                omittedEvidenceSincePreviousStress = false
            }
            return AtriaActivityTimelineSignalProjection.stress(samples: samples,
                                                                interval: interval)
        }.value
        guard !Task.isCancelled, requestKey == timelineStressRequestKey else { return }
        stressProjection = result
        stressProjectionWindowKey = requestKey.window
    }

    @MainActor
    private func appendFreshLiveHeartRate(_ reading: AtriaStressMonitorStore.LiveHeartRateReading?) {
        guard let reading,
              currentDisplayWindow.isCurrentPhysiologicalDay,
              reading.isFresh(),
              reading.bpm > 0,
              reading.at >= currentDisplayWindow.interval.start else { return }
        let existingLast = liveHeartRateTail.last ?? heartRateProjection.points.last
        if let latest = existingLast {
            guard reading.at > latest.t,
                  reading.at.timeIntervalSince(latest.t) >= 5 * 60 else { return }
        }
        var tail = liveHeartRateTail
        let segment = existingLast.map {
            reading.at.timeIntervalSince($0.t) > AtriaActivityTimelineSignalProjection.ambientHeartRateGapThreshold
                ? $0.segment + 1 : $0.segment
        } ?? 0
        if let last = tail.last, last.segment == segment, last.isOnlyPointInSegment {
            tail[tail.count - 1] = .init(id: last.id,
                                         t: last.t,
                                         bpm: last.bpm,
                                         segment: last.segment,
                                         isOnlyPointInSegment: false)
        }
        let nextID = max(heartRateProjection.points.last?.id ?? -1,
                         tail.last?.id ?? -1) + 1
        tail.append(.init(id: nextID,
                          t: reading.at,
                          bpm: reading.bpm,
                          segment: segment,
                          isOnlyPointInSegment: existingLast?.segment != segment))
        // One real point per five minutes keeps a full bounded physiological
        // cycle (<=28h) at <=336 appended points. Nothing is trimmed, so a
        // mounted all-day trace cannot lose its earlier live observations.
        liveHeartRateTail = tail
    }

    private var timelineHeartRatePoints: [AtriaActivityTimelineHeartRatePoint] {
        heartRateProjection.points + liveHeartRateTail
    }

    private var dayTimelineCard: some View {
        let calendar = Calendar.current
        let window = currentDisplayWindow
        let liveEnd = window.isCurrentPhysiologicalDay ? max(window.interval.end, Date()) : window.interval.end
        let plotEnd = max(liveEnd, window.interval.start.addingTimeInterval(60))
        let plotRange = window.interval.start...plotEnd
        let spans = timelineSpans
        let axisTicks = AtriaActivityTimelineAxis.ticks(
                                                        interval: DateInterval(start: window.interval.start,
                                                                               end: plotEnd),
                                                        isCurrent: window.isCurrentPhysiologicalDay,
                                                        calendar: calendar)

        return VStack(alignment: .leading, spacing: 8) {
            AtriaTextSelector(items: TimelineSignal.allCases,
                              title: { $0.rawValue },
                              selection: $selectedSignal)

            HStack(spacing: 8) {
                Text(timelineSignalUpdatedText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timelineSignalValueText)
                    .font(.subheadline.weight(.black).monospacedDigit())
                    .foregroundStyle(selectedSignal == .stress ? Metrics.electricStress : Color.red)
                    .lineLimit(1)
            }

            // Activity spans (Sleep / Strength / …) sit in a dedicated band ABOVE
            // the plot rather than floating inside it, with a leading inset that
            // matches the chart's Y-axis so each pill aligns to its time window.
            if !spans.isEmpty {
                timelineActivitySpanStrip(spans: spans, range: plotRange)
            }

            if selectedSignal == .heartRate {
                heartRateTimelineChart(range: plotRange,
                                       axisTicks: axisTicks,
                                       spans: spans)
            } else {
                stressTimelineChart(range: plotRange,
                                    axisTicks: axisTicks,
                                    spans: spans)
            }
        }
        .padding(12)
        .atriaCard(emphasis: .soft)
        .atriaInspectableGraph(timelineSignalInspector)
    }

    /// A time-aligned activity band rendered ABOVE the plot. Each span is
    /// positioned by its fraction of the visible time range; the leading inset
    /// approximates the chart's leading Y-axis width so pills line up with the
    /// data below them. Icons live here, outside the plot surface.
    private func timelineActivitySpanStrip(
        spans: [TimelineSpan],
        range: ClosedRange<Date>
    ) -> some View {
        let total = max(1, range.upperBound.timeIntervalSince(range.lowerBound))
        return GeometryReader { geometry in
            let width = geometry.size.width
            ForEach(spans) { span in
                let startFraction = min(max(0,
                    span.start.timeIntervalSince(range.lowerBound) / total), 1)
                let endFraction = min(max(0,
                    span.end.timeIntervalSince(range.lowerBound) / total), 1)
                let x0 = CGFloat(startFraction) * width
                let x1 = CGFloat(endFraction) * width
                let pillWidth = max(16, x1 - x0)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(span.tint.opacity(0.28))
                    .overlay {
                        if pillWidth >= 54 {
                            Label(span.label, systemImage: span.icon)
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                        } else {
                            Image(systemName: span.icon)
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(span.tint.opacity(0.42), lineWidth: 0.75)
                    }
                    .frame(width: pillWidth, height: 18)
                    .position(x: x0 + pillWidth / 2, y: 10)
            }
        }
        .frame(height: 20)
        .padding(.leading, 22)
        .padding(.trailing, 2)
        .accessibilityHidden(true)
    }

    private func heartRateTimelineChart(
        range: ClosedRange<Date>,
        axisTicks: [AtriaActivityTimelineAxisTick],
        spans: [TimelineSpan]
    ) -> some View {
        let points = timelineHeartRatePoints
        let domain = AtriaHeartRateChartSeries.yDomain(for: points.map {
            .init(t: $0.t, bpm: $0.bpm)
        })
        return Chart {
            ForEach(points) { point in
                // Translucent fill descending to the x-axis, matching the Vitals
                // Live-monitor HR chart. Same per-segment series as the line so it
                // never fills across a real gap.
                AreaMark(x: .value("Time", point.t),
                         y: .value("Heart rate", point.bpm),
                         series: .value("Observed run", "hr-\(point.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [.red.opacity(0.18),
                                                              .red.opacity(0.02)],
                                                     startPoint: .bottom,
                                                     endPoint: .top))
                LineMark(x: .value("Time", point.t),
                         y: .value("Heart rate", point.bpm),
                         series: .value("Observed run", "hr-\(point.segment)"))
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(.linearGradient(colors: [.red, .orange],
                                                     startPoint: .bottom,
                                                     endPoint: .top))
                if point.isOnlyPointInSegment {
                    PointMark(x: .value("Time", point.t),
                              y: .value("Heart rate", point.bpm))
                        .foregroundStyle(.red)
                        .symbolSize(16)
                }
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
                AxisValueLabel().font(.system(size: 9, weight: .medium, design: .rounded))
            }
        }
        .chartXAxis { timelineXAxis(axisTicks) }
        // Clip the plot area (and its translucent AreaMark fill) to the rounded
        // plot surface, matching the Stress chart — without this the gradient
        // fill and trace bleed past the graph edges.
        .atriaGraphPlotSurface()
        .frame(height: 154)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                timelinePlotOverlay(proxy: proxy,
                                    geometry: geometry,
                                    spans: spans,
                                    emptyMessage: heartRateEmptyMessage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate and activity timeline")
        .accessibilityValue(heartRateAccessibilityValue(spans: spans))
    }

    private func stressTimelineChart(
        range: ClosedRange<Date>,
        axisTicks: [AtriaActivityTimelineAxisTick],
        spans: [TimelineSpan]
    ) -> some View {
        let points = stressProjection.points
        return Chart {
            ForEach(points) { point in
                // Translucent fill descending to the x-axis, matching the Vitals
                // monitor. Same per-segment series as the line so a real >5-min
                // dropout is never filled across.
                AreaMark(x: .value("Time", point.t),
                         y: .value("Stress", point.score),
                         series: .value("Observed run", "stress-\(point.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen.opacity(0.16),
                                                              Metrics.electricRed.opacity(0.03)],
                                                     startPoint: .bottom,
                                                     endPoint: .top))
                LineMark(x: .value("Time", point.t),
                         y: .value("Stress", point.score),
                         series: .value("Observed run", "stress-\(point.segment)"))
                    // Continuous green→yellow→red read, matching the HR and
                    // per-workout stress traces. .monotone joins samples inside
                    // the display-continuity window without inventing a value;
                    // genuine >5-min dropouts still break as a new Charts series.
                    .interpolationMethod(.monotone)
                    .lineStyle(AtriaChartVisualGrammar.traceLine)
                    .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen,
                                                              Metrics.electricYellow,
                                                              Metrics.electricRed],
                                                     startPoint: .bottom,
                                                     endPoint: .top))
                if point.isOnlyPointInSegment {
                    PointMark(x: .value("Time", point.t),
                              y: .value("Stress", point.score))
                        .foregroundStyle(.linearGradient(colors: [Metrics.electricGreen,
                                                                  Metrics.electricYellow,
                                                                  Metrics.electricRed],
                                                         startPoint: .bottom,
                                                         endPoint: .top))
                        .symbolSize(16)
                }
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: 0...3)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 1, 2, 3]) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
                AxisValueLabel().font(.system(size: 9, weight: .medium, design: .rounded))
            }
        }
        .chartXAxis { timelineXAxis(axisTicks) }
        .atriaGraphPlotSurface()
        .frame(height: 154)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                timelinePlotOverlay(proxy: proxy,
                                    geometry: geometry,
                                    spans: spans,
                                    emptyMessage: stressEmptyMessage)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stress and activity timeline")
        .accessibilityValue(stressAccessibilityValue(spans: spans))
    }

    @AxisContentBuilder
    private func timelineXAxis(
        _ axisTicks: [AtriaActivityTimelineAxisTick]
    ) -> some AxisContent {
        AxisMarks(values: axisTicks.map(\.date)) { value in
            AxisGridLine().foregroundStyle(.secondary.opacity(0.10))
            AxisValueLabel {
                if let date = value.as(Date.self),
                   let tick = AtriaActivityTimelineAxis.tick(at: date, in: axisTicks) {
                    Text(tick.label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(tick.accessibilityLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func timelinePlotOverlay(
        proxy: ChartProxy,
        geometry: GeometryProxy,
        spans: [TimelineSpan],
        emptyMessage: String?
    ) -> some View {
        if let plotFrame = proxy.plotFrame {
            let frame = geometry[plotFrame]
            // Activity spans now render in the band ABOVE the plot
            // (`timelineActivitySpanStrip`); the plot overlay only carries the
            // terminal empty/blocker message so the trace surface stays clean.
            ZStack(alignment: .topLeading) {
                if let emptyMessage {
                    Text(emptyMessage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(width: max(0, frame.width - 24))
                        .position(x: frame.midX, y: frame.midY + 8)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var timelineSignalValueText: String {
        switch selectedSignal {
        case .heartRate:
            if currentDisplayWindow.isCurrentPhysiologicalDay,
               let live = stressMonitorStore.liveHeartRate,
               live.isFresh(), live.at >= currentDisplayWindow.interval.start {
                return "\(live.bpm) bpm"
            }
            return timelineHeartRatePoints.last.map { "\($0.bpm) bpm" } ?? "-- bpm"
        case .stress:
            guard let latest = stressProjection.points.last else { return "--" }
            let level = latest.level?.title ?? "Observed"
            return "\(level) \(String(format: "%.1f", latest.score))"
        }
    }

    private var timelineSignalUpdatedText: String {
        let date: Date?
        switch selectedSignal {
        case .heartRate: date = timelineHeartRatePoints.last?.t
        case .stress: date = stressProjection.points.last?.t
        }
        if let date { return "Last updated \(date.formatted(date: .omitted, time: .shortened))" }
        if selectedSignal == .heartRate, heartRateLoadState == .loading {
            return "Loading recorded signal"
        }
        return currentDisplayWindow.isCurrentPhysiologicalDay ? "Since waking" : "Selected day"
    }

    private var heartRateEmptyMessage: String? {
        guard timelineHeartRatePoints.isEmpty else { return nil }
        switch heartRateLoadState {
        case .idle: return "Heart-rate history has not loaded yet."
        case .loading: return "Loading recorded heart rate…"
        case .loaded: return "No heart-rate samples were captured in this window."
        case .unavailable: return "Heart-rate history couldn’t be read for this window."
        case .interrupted: return "Heart-rate history refresh stopped before this window was available."
        }
    }

    private var stressEmptyMessage: String? {
        guard stressProjection.points.isEmpty else { return nil }
        let window = currentDisplayWindow
        return AtriaActivityStressHistoryPresentation.emptyTimelineMessage(
            loadState: stressMonitorStore.historyLoadState,
            interval: window.interval,
            isCurrentPhysiologicalDay: window.isCurrentPhysiologicalDay,
            currentState: stressMonitorStore.state
        )
    }

    private func heartRateAccessibilityValue(spans: [TimelineSpan]) -> String {
        let signal: String
        let factualRange = [
            heartRateProjection.measuredMinimumBPM,
            heartRateProjection.measuredMaximumBPM
        ].compactMap { $0 } + liveHeartRateTail.map(\.bpm)
        if let low = factualRange.min(),
           let high = factualRange.max() {
            signal = "\(heartRateProjection.measuredSampleCount + liveHeartRateTail.count) measured samples, \(low) to \(high) beats per minute."
        } else {
            signal = heartRateEmptyMessage ?? "No measured heart rate."
        }
        return signal + activityAccessibilityValue(spans)
    }

    private func stressAccessibilityValue(spans: [TimelineSpan]) -> String {
        var signal: String
        if let low = stressProjection.points.map(\.score).min(),
           let high = stressProjection.points.map(\.score).max() {
            signal = String(format: "%d measured readings, %.1f to %.1f on a 0 to 3 scale.",
                            stressProjection.measuredSampleCount, low, high)
            let runCount = Set(stressProjection.points.map(\.segment)).count
            if runCount > 1 {
                signal += " \(runCount) measured runs; gaps contain no recorded stress score."
            }
        } else {
            signal = stressEmptyMessage ?? "No measured stress."
        }
        let cutoff = Date().addingTimeInterval(-AtriaStressHistoryArchive.retentionWindow)
        if currentDisplayWindow.interval.start < cutoff,
           stressMonitorStore.historyLoadState != .loading {
            signal += " Earlier detailed history is outside the two-day retention window."
        }
        if stressMonitorStore.historyLoadState == .unavailable,
           !stressProjection.points.isEmpty {
            signal += " Earlier saved stress history could not be read."
        }
        return signal + activityAccessibilityValue(spans)
    }

    private func activityAccessibilityValue(_ spans: [TimelineSpan]) -> String {
        guard !spans.isEmpty else { return " No activity markers." }
        return " Activities: " + spans.map {
            "\($0.label), \(AtriaActivityMonitorTab.timeRange(start: $0.start, end: $0.end))"
        }.joined(separator: "; ")
    }

    private var timelineSignalInspector: AtriaInspectableGraph? {
        let subtitle = currentDisplayWindow.isCurrentPhysiologicalDay
            ? "Since waking"
            : currentDisplayWindow.labelDay.formatted(date: .long, time: .omitted)
        switch selectedSignal {
        case .heartRate:
            guard !timelineHeartRatePoints.isEmpty else { return nil }
            return AtriaInspectableGraph(
                title: "Heart rate",
                subtitle: subtitle,
                content: .timeSeries([.init(title: "Heart rate",
                                            unit: "bpm",
                                            tint: .red,
                                            points: timelineHeartRatePoints.map {
                                                .init(id: "activity-hr-\($0.id)",
                                                      date: $0.t,
                                                      value: Double($0.bpm),
                                                      segment: $0.segment)
                                            })])
            )
        case .stress:
            guard !stressProjection.points.isEmpty else { return nil }
            return AtriaInspectableGraph(
                title: "Stress",
                subtitle: subtitle,
                content: .timeSeries([.init(title: "Stress",
                                            unit: "score",
                                            tint: Metrics.electricStress,
                                            points: stressProjection.points.map {
                                                .init(id: "activity-stress-\($0.id)",
                                                      date: $0.t,
                                                      value: $0.score,
                                                      segment: $0.segment)
                                            })])
            )
        }
    }

    }

    private var addActivityMenu: some View {
        Menu {
            Button { showAddWorkout = true } label: {
                Label("Add workout", systemImage: "figure.mixed.cardio")
            }
            Button { onAddSleep() } label: {
                Label("Add sleep or nap", systemImage: "bed.double.fill")
            }
        } label: {
            Label("Add", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(Metrics.electricStrain)
        .accessibilityLabel("Add activity")
        .accessibilityHint("Log a workout, or a sleep/nap the strap missed.")
    }

    private func daySectionCard(_ section: DaySection) -> some View {
        VStack(spacing: 8) {
            ForEach(section.entries) { entry in
                entryRow(entry)
            }
        }
        .padding(10)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .sleep(let night):
            // Review-first (user feedback 2026-08-06: tapping a sleep opened
            // the bare time editor with no visualization). The review sheet
            // hosts the shared hypnogram + stage breakdown; editing is a
            // button inside it.
            Button { sleepDetail = night } label: { sleepRow(night) }
                .buttonStyle(.plain)
        case .workout(let workout):
            Button { workoutDetail = workout } label: {
                workoutRow(workout)
            }
                .buttonStyle(.plain)
        case .workoutReview(let candidate):
            Button {
                reviewWorkoutWindow = ReviewWorkoutWindow(id: candidate.id,
                                                          start: candidate.start,
                                                          end: candidate.end)
            } label: {
                workoutReviewRow(candidate)
            }
            .buttonStyle(.plain)
        case .detection(let detection):
            Button {
                reviewWorkoutWindow = ReviewWorkoutWindow(id: detection.id.uuidString,
                                                          start: detection.start,
                                                          end: detection.end)
            } label: {
                detectionRow(detection)
            }
            .buttonStyle(.plain)
        }
    }

    private func sleepRow(_ night: SleepHistorySnapshot.Night) -> some View {
        let isNap = night.isNapEvidence
        let tint: Color = isNap ? .indigo : Metrics.electricSleep
        return activityRow(icon: isNap ? "moon.zzz.fill" : "bed.double.fill",
                           tint: tint,
                           title: isNap ? "Nap" : "Sleep",
                           subtitle: Self.timeRange(start: night.start, end: night.end),
                           value: night.durationText,
                           badge: AtriaActivitySleepStatusPresentation.badge(
                            confirmed: night.confirmed,
                            confidence: night.confidence
                           ),
                           context: nil,
                           contextTint: .secondary)
            .accessibilityLabel("\(isNap ? "Nap" : "Sleep"), \(night.durationText), \(Self.timeRange(start: night.start, end: night.end)). Tap to adjust.")
    }

    private func workoutRow(_ workout: UserConfirmedWorkout) -> some View {
        return activityRow(icon: Self.activityIcon(for: workout),
                    tint: Self.activityTint(for: workout),
                    title: workout.label,
                    subtitle: Self.timeRange(start: workout.start, end: workout.end),
                    value: Self.durationText(workout.duration),
                    badge: Self.strainBadge(for: workout),
                    context: nil,
                    contextTint: .secondary)
            .accessibilityLabel(workoutAccessibilityLabel(workout))
    }

    private func workoutReviewRow(_ candidate: WorkoutReviewCandidate) -> some View {
        let presentation = AtriaDetectedActivityPresentation.make(
            kind: candidate.kind,
            suggestedActivityType: candidate.suggestedActivityType
        )
        return activityRow(icon: presentation.icon,
                    tint: .orange,
                    title: presentation.title,
                    subtitle: Self.timeRange(start: candidate.start, end: candidate.end),
                    value: Self.durationText(candidate.duration),
                    badge: "Review",
                    context: candidate.avgHR > 0 ? "\(candidate.avgHR) bpm avg" : nil,
                    contextTint: .secondary)
            .accessibilityLabel("Activity detected, \(Self.durationText(candidate.duration)), \(Self.timeRange(start: candidate.start, end: candidate.end)). Review activity type.")
    }

    private func detectionRow(_ detection: ActivityDetection) -> some View {
        let presentation = AtriaDetectedActivityPresentation.make(
            kind: detection.kind,
            suggestedActivityType: detection.suggestedActivityType
        )
        return activityRow(icon: presentation.icon,
                           tint: .orange,
                           title: presentation.title,
                           subtitle: Self.timeRange(start: detection.start, end: detection.end),
                           value: Self.durationText(detection.duration),
                           badge: "Review",
                           context: detection.avgHR > 0 ? "\(detection.avgHR) bpm avg" : nil,
                           contextTint: .secondary)
            .accessibilityLabel("\(presentation.title), \(Self.durationText(detection.duration)), \(Self.timeRange(start: detection.start, end: detection.end)). Review activity type.")
    }

    private func workoutAccessibilityLabel(_ workout: UserConfirmedWorkout) -> String {
        if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
            return "\(workout.label), \(Self.durationText(workout.duration)), \(AtriaWorkoutMetricPresentation.compactStatus(workout)). Tap for details."
        }
        return "\(workout.label), \(Self.durationText(workout.duration)), average \(workout.avgHR) bpm. Tap for details."
    }

    private static func activityIcon(for workout: UserConfirmedWorkout) -> String {
        AtriaActivityDisplayIcon.icon(activityType: workout.activityType,
                                      subtype: workout.activitySubtype,
                                      label: workout.label)
    }

    private static func activityTint(for workout: UserConfirmedWorkout) -> Color {
        let type = AtriaWorkoutActivityType.resolved(activityType: workout.activityType,
                                                     subtype: workout.activitySubtype,
                                                     label: workout.label)
        // Category-driven for the 77-type catalog (2026-08-05): specific
        // overrides stay for the original set; everything else tints by its
        // catalog category so new types never fall through to a compile
        // error or a mismatched color.
        switch type {
        case .walking, .hiking: return .mint
        case .running, .hiit, .jumpRope: return .orange
        case .cycling, .rowing, .swimming: return .cyan
        case .strength, .functionalFitness, .boxing, .climbing: return Metrics.electricStrain
        case .yoga, .pilates, .mobility: return .indigo
        case .dance, .sport, .basketball, .football, .cricket, .tennis,
             .badminton, .volleyball, .golf, .martialArts: return .pink
        case .cardio, .elliptical, .stairClimber: return .red
        case .other: return .secondary
        default:
            switch type.category {
            case .training: return Metrics.electricStrain
            case .cardio: return .red
            case .sports: return .pink
            case .outdoor: return .mint
            case .winter: return .cyan
            case .combat: return Metrics.electricStrain
            case .mindBody: return .indigo
            case .recovery: return .teal
            case .daily: return .secondary
            }
        }
    }

    /// Strain magnitude is not a proxy for whether HR exists. A short or gentle
    /// workout can legitimately have strain below 0.1 while still containing
    /// hundreds of samples. Only the recorded sample metadata may declare the
    /// signal absent; sparse windows keep their explicit incomplete qualifier.
    static func strainBadge(for workout: UserConfirmedWorkout) -> String {
        guard workout.samples > 0, workout.avgHR > 0 else { return "No HR data" }
        if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
            return AtriaWorkoutMetricPresentation.compactStatus(workout)
        }
        guard let strain = workout.strain else { return "\(workout.avgHR) bpm avg" }
        return "Strain \(String(format: "%.1f", strain))"
    }

    private func activityRow(icon: String,
                             tint: Color,
                             title: String,
                             subtitle: String,
                             value: String,
                             badge: String,
                             context: String?,
                             contextTint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.callout.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                // User-editable workout names get a scale guard + priority so
                // the fixed trailing column yields (UX audit 2026-07-07).
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let context {
                    Text(context)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(contextTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(value)
                    .font(.subheadline.weight(.black).monospacedDigit())
                Text(badge)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .fixedSize()

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .atriaInsetCard(tint: tint)
        .contentShape(Rectangle())
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter
    }()

    private static func timeRange(start: Date?, end: Date?) -> String {
        switch (start, end) {
        case let (start?, end?):
            return "\(timeFormatter.string(from: start)) – \(timeFormatter.string(from: end))"
        case let (start?, nil):
            return timeFormatter.string(from: start)
        case let (nil, end?):
            return "until \(timeFormatter.string(from: end))"
        case (nil, nil):
            return "time not recorded"
        }
    }

    private static func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    /// Read-through cache for the lightweight timeline derivation. Day-section
    /// grouping and sorting use the asynchronous cache above.
    private final class AtriaActivityMonitorMemo {
        private struct SourceKey: Equatable {
            let sleepRevision: Int
            let workoutsRevision: Int
            let detectionsRevision: Int
            let reviewFingerprint: String
            let calendarIdentifier: String
            let timeZoneIdentifier: String
        }

        private struct TimelineKey: Equatable {
            let source: SourceKey
            let interval: DateInterval
            let isCurrent: Bool
        }

        private var timelineKey: TimelineKey?
        private var timelineValue: [TimelineSpan] = []

        func timelineSpans(sleepRevision: Int,
                           workoutsRevision: Int,
                           detectionsRevision: Int,
                           reviewFingerprint: String,
                           displayWindow: AtriaActivityDisplayWindow,
                           sleepSnapshot: SleepHistorySnapshot,
                           pendingSleepReview: SleepHistorySnapshot.Night?,
                           napReviewCandidates: [SleepHistorySnapshot.Night],
                           workouts: [UserConfirmedWorkout],
                           workoutReview: WorkoutReviewCandidate?,
                           detections: [ActivityDetection],
                           calendar: Calendar) -> [TimelineSpan] {
            let source = sourceKey(sleepRevision: sleepRevision,
                                   workoutsRevision: workoutsRevision,
                                   detectionsRevision: detectionsRevision,
                                   reviewFingerprint: reviewFingerprint,
                                   calendar: calendar)
            let dayStart = displayWindow.interval.start
            let dayEnd = displayWindow.interval.end
            let key = TimelineKey(source: source,
                                  interval: displayWindow.interval,
                                  isCurrent: displayWindow.isCurrentPhysiologicalDay)
            if timelineKey == key {
                return timelineValue
            }
            var spans: [TimelineSpan] = []
            let visibleSleeps = AtriaActivitySelectedDaySleeps.overlapping(
                snapshot: sleepSnapshot,
                pendingReview: pendingSleepReview,
                napReviewCandidates: napReviewCandidates,
                interval: displayWindow.interval,
                calendar: calendar,
                mainSleepOwnershipDay: displayWindow.isCurrentPhysiologicalDay
                    ? nil
                    : displayWindow.labelDay
            ).compactMap { night -> (SleepHistorySnapshot.Night, Date, Date)? in
                guard let start = night.start, let end = night.end,
                      end > dayStart, start < dayEnd else { return nil }
                return (night, max(start, dayStart), min(end, dayEnd))
            }
            let sleepAssignments = AtriaActivityTimelineLanePacker.assignments(for: visibleSleeps.map {
                AtriaActivityTimelineLaneInterval(id: "sleep-\($0.0.id)", start: $0.1, end: $0.2)
            })
            for (night, start, end) in visibleSleeps {
                let id = "sleep-\(night.id)"
                spans.append(TimelineSpan(id: id,
                                          lane: "sleep-\(sleepAssignments[id] ?? 0)",
                                          start: start,
                                          end: end,
                                          tint: Metrics.electricSleep,
                                          label: night.isNapEvidence ? "Nap" : "Sleep",
                                          icon: night.isNapEvidence ? "moon.zzz.fill" : "bed.double.fill"))
            }
            let workoutSpans = AtriaActivityTimelineBuilder.workoutSpans(
                workouts: workouts,
                interval: displayWindow.interval
            )
            let workoutByID = Dictionary(uniqueKeysWithValues: workouts.map { ("workout-\($0.id)", $0) })
            for workoutSpan in workoutSpans {
                guard let workout = workoutByID[workoutSpan.id] else { continue }
                spans.append(TimelineSpan(id: workoutSpan.id,
                                          lane: workoutSpan.lane,
                                          start: workoutSpan.start,
                                          end: workoutSpan.end,
                                          tint: AtriaActivityMonitorTab.activityTint(for: workout),
                                          label: workoutSpan.label,
                                          icon: workoutSpan.icon))
            }
            let visibleReview = AtriaActivityReviewProjection.visibleWorkoutReview(
                workoutReview,
                confirmedWorkouts: workouts,
                interval: displayWindow.interval
            )
            let visibleDetections = AtriaActivityReviewProjection.visibleDetections(
                detections,
                workoutReview: workoutReview,
                confirmedWorkouts: workouts,
                interval: displayWindow.interval
            )
            var reviewIntervals: [(id: String, start: Date, end: Date, label: String, icon: String)] = []
            if let candidate = visibleReview {
                let presentation = AtriaDetectedActivityPresentation.make(
                    kind: candidate.kind,
                    suggestedActivityType: candidate.suggestedActivityType
                )
                reviewIntervals.append(("workout-review-\(candidate.id)",
                                        max(candidate.start, dayStart),
                                        min(candidate.end, dayEnd),
                                        presentation.title,
                                        presentation.icon))
            }
            reviewIntervals.append(contentsOf: visibleDetections.map {
                let presentation = AtriaDetectedActivityPresentation.make(
                    kind: $0.kind,
                    suggestedActivityType: $0.suggestedActivityType
                )
                return ("detection-\($0.id.uuidString)",
                        max($0.start, dayStart),
                        min($0.end, dayEnd),
                        presentation.title,
                        presentation.icon)
            })
            let reviewAssignments = AtriaActivityTimelineLanePacker.assignments(for: reviewIntervals.map {
                AtriaActivityTimelineLaneInterval(id: $0.id, start: $0.start, end: $0.end)
            })
            spans.append(contentsOf: reviewIntervals.map {
                TimelineSpan(id: $0.id,
                             lane: "review-\(reviewAssignments[$0.id] ?? 0)",
                             start: $0.start,
                             end: $0.end,
                             tint: .orange,
                             label: $0.label,
                             icon: $0.icon)
            })
            // A person has one activity state at a time, so the monitor uses
            // one translucent marker lane. Confirmed workouts own conflicts,
            // then saved sleep, then unsaved review evidence. Lower-priority
            // events are clipped only where they conflict; their remaining
            // real time and their tappable row stay visible.
            let sourceByID = Dictionary(uniqueKeysWithValues: spans.map { ($0.id, $0) })
            let slices = AtriaActivityTimelineMarkerProjection.nonOverlappingSlices(
                spans.map { span in
                    let priority: Int
                    if span.id.hasPrefix("workout-") && !span.id.hasPrefix("workout-review-") {
                        priority = 400
                    } else if span.id.hasPrefix("sleep-") {
                        priority = 300
                    } else if span.id.hasPrefix("workout-review-") {
                        priority = 200
                    } else {
                        priority = 100
                    }
                    return AtriaActivityTimelineMarkerInterval(id: span.id,
                                                               start: span.start,
                                                               end: span.end,
                                                               priority: priority)
                }
            )
            let compacted = slices.compactMap { slice -> TimelineSpan? in
                guard let source = sourceByID[slice.sourceID] else { return nil }
                return TimelineSpan(id: slice.id,
                                    lane: "activity",
                                    start: slice.start,
                                    end: slice.end,
                                    tint: source.tint,
                                    label: source.label,
                                    icon: source.icon)
            }
            timelineKey = key
            timelineValue = compacted
            return compacted
        }

        private func sourceKey(sleepRevision: Int,
                               workoutsRevision: Int,
                               detectionsRevision: Int,
                               reviewFingerprint: String,
                               calendar: Calendar) -> SourceKey {
            SourceKey(sleepRevision: sleepRevision,
                      workoutsRevision: workoutsRevision,
                      detectionsRevision: detectionsRevision,
                      reviewFingerprint: reviewFingerprint,
                      calendarIdentifier: String(describing: calendar.identifier),
                      timeZoneIdentifier: calendar.timeZone.identifier)
        }
    }
}

/// Converts only readings measured inside one confirmed workout. Kept pure so
/// the sheet-only observer can refresh without leaking stress observation back
/// into the Activity tab root, and so the inclusive boundary semantics remain
/// regression-testable.
enum AtriaActivityWorkoutStressProjection {
    static func readings(
        history: [AtriaStressMonitorStore.StressHistoryPoint],
        start: Date,
        end: Date
    ) -> [AtriaStressDetailReading] {
        history.compactMap { point in
            guard point.t >= start, point.t <= end else { return nil }
            return AtriaStressDetailReading(historyPoint: point)
        }
    }

    static func evidence(
        history: [AtriaStressMonitorStore.StressHistoryPoint],
        start: Date,
        end: Date
    ) -> AtriaStressTimelineEvidenceProjection {
        AtriaStressTimelineEvidenceProjection.make(
            readings: readings(history: history, start: start, end: end)
        )
    }

    static func evidence(
        readings: [AtriaStressDetailReading]
    ) -> AtriaStressTimelineEvidenceProjection {
        AtriaStressTimelineEvidenceProjection.make(readings: readings)
    }
}

/// Stress history is relevant only while a workout detail is presented. Retain
/// the store without broad observation and subscribe to its two history tokens,
/// so live pulse/state updates do not repeatedly filter the 48-hour ring.
private struct AtriaActivityWorkoutDetailSheetHost: View {
    let store: SessionStore
    let workout: UserConfirmedWorkout
    let stressMonitorStore: AtriaStressMonitorStore

    @State private var stressReadings: [AtriaStressDetailReading] = []
    @State private var stressHistoryLoadState: AtriaStressHistoryLoadState = .loading

    var body: some View {
        AtriaActivityWorkoutDetailSheet(
            store: store,
            workout: workout,
            stressReadings: stressReadings,
            stressHistoryLoadState: stressHistoryLoadState
        )
        .task(id: workout.id) { refreshStressReadings() }
        .onReceive(stressMonitorStore.$historyRevision.removeDuplicates()) { _ in
            refreshStressReadings()
        }
        .onReceive(stressMonitorStore.$historyLoadState.removeDuplicates()) { state in
            stressHistoryLoadState = state
            refreshStressReadings()
        }
    }

    private func refreshStressReadings() {
        stressReadings = AtriaActivityWorkoutStressProjection.readings(
            history: stressMonitorStore.history,
            start: workout.start,
            end: workout.end
        )
    }
}

/// Detail + editor for a confirmed workout in the Activity Monitor. The measured
/// stats (HR, strain, calories) are read-only — they come straight
/// from the recorded session and are never estimated. Editable: the name, the
/// activity type (Run / Walk / Dance …), the time window (re-derives metrics from
/// the strap samples in the new window), and removal (delete a wrong detection).
private struct AtriaActivityWorkoutDetailSheet: View {
    private struct StrengthExerciseSummary: Identifiable {
        let exercise: String
        let setCount: Int
        var id: String { exercise }
    }

    let store: SessionStore
    let workout: UserConfirmedWorkout
    /// Restored or live measured readings overlapping the workout window.
    /// Load/retention authority stays separate so an empty array never has to
    /// pretend corruption, pending hydration, and no samples are the same state.
    let stressReadings: [AtriaStressDetailReading]
    let stressHistoryLoadState: AtriaStressHistoryLoadState
    private let recoveryEffect: AtriaActivityRecoveryEffect
    @Environment(\.dismiss) private var dismiss

    @State private var label: String
    @State private var activityType: String
    @State private var activitySubtype: String?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var showDeleteConfirm = false
    @State private var saveError: String?
    @State private var showShareSheet = false
    @State private var route: AtriaWorkoutRoute?
    @State private var routeSegments: [[CLLocationCoordinate2D]] = []
    @State private var routeFileURL: URL?
    @State private var routeSharePreviewPoints: [AtriaWorkoutShareSnapshot.RoutePoint] = []
    @State private var sharePresentationGate = AtriaWorkoutSharePresentationGate()
    @State private var showsHeartRateAndRecovery = false
    @State private var isRouteTransactionInFlight = false

    /// Common activity types offered in the type picker (real workout kinds, not
    /// fabricated data — just labels for what the effort was).
    static let activityTypes = AtriaWorkoutActivityType.allCases.map(\.rawValue)

    init(store: SessionStore,
         workout: UserConfirmedWorkout,
         stressReadings: [AtriaStressDetailReading] = [],
         stressHistoryLoadState: AtriaStressHistoryLoadState = .disabled) {
        self.store = store
        self.workout = workout
        self.stressReadings = stressReadings
        self.stressHistoryLoadState = stressHistoryLoadState
        recoveryEffect = AtriaActivityRecoveryEffect.make(
            workout: workout,
            rollups: store.dailyRollupHistory,
            confirmedSleeps: store.confirmedSleeps,
            calendar: .current
        )
        _label = State(initialValue: workout.label)
        _activityType = State(initialValue: workout.activityType ?? "")
        let initialType = AtriaWorkoutActivityType(rawValue: workout.activityType ?? "")
        _activitySubtype = State(initialValue: initialType?.normalizedSubtype(workout.activitySubtype))
        _startTime = State(initialValue: workout.start)
        _endTime = State(initialValue: workout.end)
    }

    /// The workout window's real recorded HR samples from the saved sessions
    /// that overlap it. Empty when no session covered the window (e.g. a manually
    /// added workout) — the card then doesn't render. Cached in `tracePoints`
    /// because this scan is O(sessions × points): recomputing it on every ~1 Hz
    /// store publish while the sheet is open was a hang, and a completed workout's
    /// overlapping samples never change (2026-07-08).
    @State private var tracePoints: [AtriaHomeModel.HeartRateChartPoint] = []
    /// WHOOP-style in-activity chart switcher (2026-08-05 user directive):
    /// one card, segmented Heart rate / Stress.
    private enum TraceChartMode: String, CaseIterable, Identifiable {
        case heartRate = "Heart rate"
        case stress = "Stress"
        var id: String { rawValue }
    }
    @State private var traceChartMode: TraceChartMode = .heartRate
    @State private var isPreparingTrace = false
    @State private var hasPreparedTrace = false

    /// `SavedSession` predates strict concurrency. Capturing the store itself in
    /// detached work would race its main-actor publishes, so take a value/COW
    /// snapshot first and expose only immutable reads to the worker.
    private struct HeartRateTraceSourceSnapshot: @unchecked Sendable {
        let sessions: [SavedSession]
        let workoutStart: Date
        let workoutEnd: Date

        var mayContainRenderableTrace: Bool {
            var candidatePointCount = 0
            for session in sessions
            where session.end > workoutStart && session.start < workoutEnd {
                candidatePointCount += session.points.count
                if candidatePointCount >= 30 { return true }
            }
            return false
        }
    }

    /// The chart point type is immutable but also predates Sendable annotations;
    /// keep its cross-actor transfer confined to this result wrapper.
    private struct PreparedHeartRateTrace: @unchecked Sendable {
        let points: [AtriaHomeModel.HeartRateChartPoint]
    }

    private nonisolated static func prepareHeartRateTrace(
        from snapshot: HeartRateTraceSourceSnapshot
    ) -> PreparedHeartRateTrace {
        let points = snapshot.sessions
            .filter { $0.end > snapshot.workoutStart && $0.start < snapshot.workoutEnd }
            .flatMap { session in
                session.points.compactMap { point -> AtriaHomeModel.HeartRateChartPoint? in
                    let time = session.start.addingTimeInterval(point.t)
                    guard time >= snapshot.workoutStart,
                          time <= snapshot.workoutEnd,
                          point.bpm > 0 else { return nil }
                    return AtriaHomeModel.HeartRateChartPoint(t: time, bpm: point.bpm)
                }
            }
            .sorted { $0.t < $1.t }
        return PreparedHeartRateTrace(points: points)
    }

    private var workoutStressProjection: AtriaStressTimelineEvidenceProjection {
        AtriaActivityWorkoutStressProjection.evidence(readings: stressReadings)
    }

    private var hasWorkoutStressEvidence: Bool {
        workoutStressProjection.presentation != .empty
    }

    private var workoutStressAccessibilityLabel: String {
        switch workoutStressProjection.presentation {
        case .physiologicalStress:
            return "Physiological stress trace, \(workoutStressProjection.stressPoints.count) measured readings during this workout; HR-only readings are lower confidence."
        case .cardiacArousal:
            return "Physiological stress trace, \(workoutStressProjection.cardiacArousalPoints.count) legacy HR-only estimates during this workout; lower confidence."
        case .empty:
            return "No measured physiological-stress readings during this workout."
        }
    }

    /// Per-workout HR trace (design backlog item 6). Reuses the shared axis
    /// chart, which auto-smooths dense windows into an average + min-max
    /// band per the 2026-07-07 feedback.
    @ViewBuilder
    private var heartRateTraceCard: some View {
        let points = tracePoints
        if isPreparingTrace {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 36)
                .accessibilityLabel("Preparing heart-rate trace")
        } else if points.count >= 30 || hasWorkoutStressEvidence {
            VStack(alignment: .leading, spacing: 8) {
                // Native-clean (design 2026-08-05): plain-text selector replaces
                // the boxed segmented control, matching the app-wide style.
                AtriaTextSelector(items: TraceChartMode.allCases,
                                  title: { $0.rawValue },
                                  selection: $traceChartMode)
                switch traceChartMode {
                case .heartRate:
                    if points.count >= 30 {
                        AtriaHeartRateAxisChart(points: points,
                                                yDomain: AtriaHeartRateChartSeries.yDomain(for: points),
                                                displayContinuity: .workout,
                                                selectedTime: .constant(nil))
                            .frame(height: 150)
                            .clipped()
                            // Full-bleed plot (2026-08-05 width audit).
                            .padding(.horizontal, -12)
                    } else {
                        Text("No heart-rate samples recorded during this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                case .stress:
                    switch workoutStressProjection.presentation {
                    case .physiologicalStress:
                        AtriaWorkoutStressTraceChart(
                            readings: workoutStressProjection.stressPoints.map(\.reading)
                        )
                            .frame(height: 150)
                            // Full-bleed plot (2026-08-05 width audit).
                            .padding(.horizontal, -12)

                    case .cardiacArousal:
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Physiological stress · HR-only estimate")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                            AtriaCardiacArousalTimelineChart(
                                points: workoutStressProjection.cardiacArousalPoints,
                                referenceDate: workout.end,
                                window: max(1, workout.end.timeIntervalSince(workout.start))
                            )
                            Text("0–3 estimate · lower confidence")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 150)
                        .padding(.horizontal, -12)

                    case .empty:
                        Text(AtriaActivityStressHistoryPresentation.workoutEmptyMessage(
                            loadState: stressHistoryLoadState,
                            workoutEnd: workout.end
                        ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
            .padding(12)
            .atriaInsetCard(tint: traceChartMode == .stress ? Metrics.electricStress : .red)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(traceChartMode == .heartRate
                ? "Heart-rate trace, \(points.count) samples during this workout."
                : workoutStressAccessibilityLabel)
        }
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedLabel.isEmpty && endTime > startTime
    }

    private var strengthExerciseSummaries: [StrengthExerciseSummary] {
        Dictionary(grouping: workout.strengthSets ?? [], by: \.exercise)
            .map { StrengthExerciseSummary(exercise: $0.key, setCount: $0.value.count) }
            .sorted { $0.exercise.localizedStandardCompare($1.exercise) == .orderedAscending }
    }

    private var pausedWorkoutSeconds: TimeInterval {
        (workout.excludedIntervals ?? []).reduce(0) { total, interval in
            total + max(0, interval.end.timeIntervalSince(interval.start))
        }
    }

    private var muscularLoadReceipt: AtriaStrengthLog.MuscularLoadReceipt? {
        workout.muscularLoadReceipt
            ?? AtriaStrengthLog.muscularLoadReceipt(for: workout.strengthSets ?? [])
    }

    private var muscularLoadReceiptIsFrozen: Bool {
        workout.muscularLoadReceipt != nil
    }

    @ViewBuilder
    private var strengthSetSummaryCard: some View {
        if !strengthExerciseSummaries.isEmpty || pausedWorkoutSeconds > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Label("Workout log", systemImage: "dumbbell.fill")
                    .font(.subheadline.weight(.bold))
                ForEach(strengthExerciseSummaries) { summary in
                    HStack {
                        Text(summary.exercise)
                        Spacer()
                        Text("\(summary.setCount) set\(summary.setCount == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.semibold))
                }
                if pausedWorkoutSeconds > 0 {
                    Label("\(Int((pausedWorkoutSeconds / 60).rounded())) min paused",
                          systemImage: "pause.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let muscularLoadReceipt {
                    Divider()
                    AtriaMuscularLoadSummary(receipt: muscularLoadReceipt,
                                             isFrozen: muscularLoadReceiptIsFrozen)
                }
            }
            .padding(12)
            .atriaInsetCard(tint: .orange)
        }
    }

    /// Sharing always represents a persisted workout. Keeping it unavailable
    /// while editor fields differ prevents a mixed snapshot where the icon uses
    /// the draft activity type but duration, metrics, and title still come from
    /// the previously saved workout.
    private var hasUnsavedChanges: Bool {
        trimmedLabel != workout.label.trimmingCharacters(in: .whitespacesAndNewlines)
            || activityType.trimmingCharacters(in: .whitespacesAndNewlines)
                != (workout.activityType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || activitySubtype != AtriaWorkoutActivityType(rawValue: workout.activityType ?? "")?
                .normalizedSubtype(workout.activitySubtype)
            || abs(startTime.timeIntervalSince(workout.start)) >= 0.5
            || abs(endTime.timeIntervalSince(workout.end)) >= 0.5
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Workout name", text: $label)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)

                        Divider()

                        Menu {
                            ForEach(Self.activityTypes, id: \.self) { type in
                                Button {
                                    activityType = type
                                    activitySubtype = AtriaWorkoutActivityType(rawValue: type)?
                                        .normalizedSubtype(activitySubtype)
                                } label: {
                                    Label(type,
                                          systemImage: AtriaWorkoutActivityType(rawValue: type)?.icon
                                              ?? AtriaWorkoutActivityType.other.icon)
                                }
                            }
                            if !activityType.isEmpty {
                                Button("Clear", role: .destructive) {
                                    activityType = ""
                                    activitySubtype = nil
                                }
                            }
                        } label: {
                            HStack {
                                Text("Activity")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: AtriaWorkoutActivityType(rawValue: activityType)?.icon
                                      ?? AtriaWorkoutActivityType.other.icon)
                                    .foregroundStyle(.secondary)
                                Text(activityType.isEmpty ? "Choose" : activityType)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }

                        if let selectedType = AtriaWorkoutActivityType(rawValue: activityType),
                           !selectedType.subtypeOptions.isEmpty {
                            Divider()
                            Menu {
                                ForEach(selectedType.subtypeOptions, id: \.self) { subtype in
                                    Button {
                                        activitySubtype = subtype
                                    } label: {
                                        if activitySubtype == subtype {
                                            Label(subtype, systemImage: "checkmark")
                                        } else {
                                            Text(subtype)
                                        }
                                    }
                                }
                                if activitySubtype != nil {
                                    Button("Clear style", role: .destructive) {
                                        activitySubtype = nil
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("Style")
                                    Spacer()
                                    Text(activitySubtype ?? "Choose")
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                        }

                        Divider()

                        VStack(spacing: 6) {
                            DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                            DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(14)
                    .atriaCard(emphasis: .soft)

                    routeCard
                    strengthSetSummaryCard

                    if let saveError {
                        Label(saveError, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        if workout.strain != nil {
                            statTile("Strain",
                                     AtriaWorkoutMetricPresentation.strainText(workout),
                                     tint: Metrics.electricStrain)
                        }
                        statTile("Duration", durationText(workout.duration), tint: Metrics.electricStrain)
                        if let steps = completedWorkoutStepsPresentation {
                            statTile("Steps",
                                     steps.valueText,
                                     detail: steps.detailText,
                                     tint: .mint)
                        }
                        if AtriaWorkoutMetricPresentation.hasHeartRateData(workout) {
                            statTile("Avg HR",
                                     AtriaWorkoutMetricPresentation.averageHeartRateText(workout),
                                     tint: .pink)
                            statTile("Peak HR",
                                     AtriaWorkoutMetricPresentation.peakHeartRateText(workout),
                                     tint: .red)
                        }
                        if workout.activeEnergyKilocalories != nil {
                            statTile("Calories",
                                     AtriaWorkoutMetricPresentation.energyText(workout),
                                     tint: .orange)
                        }
                    }

                    workoutZoneDistributionCard

                    if workout.samples == 0 {
                        Label("Saved without strap metrics", systemImage: "heart.slash")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if AtriaWorkoutMetricPresentation.metricsAreIncomplete(workout) {
                        Label(AtriaWorkoutMetricPresentation.compactStatus(workout),
                              systemImage: "waveform.path.badge.minus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHint("The recorded workout window is saved. Strain, average heart rate, and energy are waiting for enough strap coverage.")
                    } else if workout.streamCoveragePercent < 75 {
                        Label("\(workout.streamCoveragePercent)% strap coverage",
                              systemImage: "waveform.path.badge.minus")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityHint("Strain reflects only the recorded heart-rate portion and may under-read the full effort.")
                    }

                    DisclosureGroup(isExpanded: $showsHeartRateAndRecovery) {
                        VStack(spacing: 12) {
                            heartRateTraceCard
                            recoveryEffectCard
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Details", systemImage: "waveform.path.ecg")
                            .font(.subheadline.weight(.semibold))
                    }
                    .tint(.secondary)
                }
                .padding(16)
            }
            .navigationTitle("Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if sharePresentationGate.requestPresentation() {
                            showShareSheet = true
                        }
                    } label: {
                        if sharePresentationGate.requestIsPending {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    .disabled(hasUnsavedChanges
                              || sharePresentationGate.requestIsPending
                              || isRouteTransactionInFlight)
                    .accessibilityLabel("Share workout")
                    .accessibilityHint(hasUnsavedChanges
                                       ? "Save your changes before sharing."
                                       : (sharePresentationGate.requestIsPending
                                          ? "Preparing the saved route."
                                          : "Share the saved workout summary."))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete workout", systemImage: "trash", role: .destructive) {
                            showDeleteConfirm = true
                        }
                        .disabled(isRouteTransactionInFlight)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Workout actions")
                }

                // Keep destructive actions and the commit action visually
                // independent. Without a fixed toolbar spacer iOS 26 merges
                // adjacent trailing items into one nested Liquid Glass pill.
                ToolbarSpacer(.fixed, placement: .topBarTrailing)

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: saveAll)
                        .fontWeight(.bold)
                        .disabled(!canSave || isRouteTransactionInFlight)
                }
            }
            .confirmationDialog("Delete this workout?",
                                isPresented: $showDeleteConfirm,
                                titleVisibility: .visible) {
                Button("Delete workout", role: .destructive) {
                    deleteWorkout()
                }
                .disabled(isRouteTransactionInFlight)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes it from Activity history. Recorded strap data and day strain remain.")
            }
            .alert("Couldn’t update workout",
                   isPresented: Binding(
                    get: { saveError != nil },
                    set: { if !$0 { saveError = nil } }
                   )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "Try again.")
            }
            .sheet(isPresented: $showShareSheet) {
                AtriaWorkoutShareSheet(snapshot: shareSnapshot)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .task(id: workout.id) {
                guard !sharePresentationGate.routeIsPrepared else { return }
                _ = await AtriaWorkoutRouteTransactionRecovery.recover(
                    workouts: store.confirmedWorkouts
                )
                let prepared = await AtriaWorkoutRouteStore.loadPreparedPresentationAsync(
                    workoutID: workout.id
                )
                guard !Task.isCancelled else { return }
                route = prepared.route
                routeSegments = prepared.segments
                routeFileURL = prepared.gpxURL
                routeSharePreviewPoints = prepared.sharePreviewPoints
                if sharePresentationGate.completeRoutePreparation() {
                    showShareSheet = true
                }
            }
            // The editor opens on the controls and route without touching the
            // potentially large saved-session archive. Prepare the trace only
            // when the user asks for the collapsed analysis section.
            .task(id: showsHeartRateAndRecovery) {
                guard showsHeartRateAndRecovery, !hasPreparedTrace else { return }
                let snapshot = HeartRateTraceSourceSnapshot(sessions: store.sessions,
                                                            workoutStart: workout.start,
                                                            workoutEnd: workout.end)
                guard snapshot.mayContainRenderableTrace else {
                    tracePoints = []
                    isPreparingTrace = false
                    hasPreparedTrace = true
                    return
                }

                isPreparingTrace = true
                let preparation = Task.detached(priority: .userInitiated) {
                    Self.prepareHeartRateTrace(from: snapshot)
                }
                let prepared = await withTaskCancellationHandler {
                    await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                guard !Task.isCancelled else { return }
                tracePoints = prepared.points
                isPreparingTrace = false
                hasPreparedTrace = true
            }
        }
    }

    @ViewBuilder
    private var recoveryEffectCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Recovery after this activity", systemImage: "heart.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(recoveryEffect.tint)
            Text(recoveryEffect.valueText)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(recoveryEffect.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: recoveryEffect.tint)
    }

    private func saveAll() {
        guard !isRouteTransactionInFlight else { return }
        isRouteTransactionInFlight = true
        Task { @MainActor in
            await saveAllAsync()
        }
    }

    private func saveAllAsync() async {
        defer { isRouteTransactionInFlight = false }
        saveError = nil
        let requestedType = AtriaWorkoutActivityType.resolved(
            activityType: activityType,
            subtype: activitySubtype,
            label: label
        )
        let originalType = AtriaWorkoutActivityType.resolved(
            activityType: workout.activityType,
            subtype: workout.activitySubtype,
            label: workout.label
        )
        let routeIdentityChanged = requestedType != originalType
            || startTime != workout.start
            || endTime != workout.end
        if !routeIdentityChanged {
            switch await store.editConfirmedWorkout(id: workout.id,
                                              label: label,
                                              activityType: activityType,
                                              activitySubtype: activitySubtype,
                                              start: startTime,
                                              end: endTime,
                                              rest: store.baseline.restingInt ?? 60,
                                              maxHR: store.profile.maxHR) {
            case .success:
                dismiss()
            case .failure(let error):
                saveError = error.userMessage
            }
            return
        }
        let pendingRecovery = await AtriaWorkoutRouteTransactionRecovery.recover(
            workouts: store.confirmedWorkouts
        )
        guard pendingRecovery != .failed, pendingRecovery != .deferred else {
            saveError = "Atria is still recovering an earlier route update. Close and reopen Activity, then try Save again."
            return
        }
        let expectedWorkoutID = expectedEditedWorkoutID(start: startTime, end: endTime)
        let originalState = AtriaWorkoutRouteStore.CanonicalWorkoutState(
            id: workout.id,
            activityType: originalType.rawValue,
            start: workout.start,
            end: workout.end
        )
        guard await AtriaWorkoutRouteStore.beginEditTransactionAsync(
            from: originalState,
            to: expectedWorkoutID,
            activityType: requestedType,
            start: startTime,
            end: endTime
        ) else {
            saveError = "Atria couldn’t prepare this route update safely. Nothing was changed; try Save again."
            return
        }
        let result = await store.editConfirmedWorkout(id: workout.id,
                                                label: label,
                                                activityType: activityType,
                                                activitySubtype: activitySubtype,
                                                start: startTime,
                                                end: endTime,
                                                rest: store.baseline.restingInt ?? 60,
                                                maxHR: store.profile.maxHR)
        switch result {
        case .success(let savedWorkout):
            guard savedWorkout.id == expectedWorkoutID else {
                // This should be unreachable because the canonical ID is a
                // pure function of the edited window. Retain the marker and
                // fail closed rather than associating a route by guesswork.
                saveError = "Atria saved an unexpected workout identity. Close and reopen Activity so it can recover safely."
                return
            }
            let resolvedType = AtriaWorkoutActivityType.resolved(
                activityType: savedWorkout.activityType,
                subtype: savedWorkout.activitySubtype,
                label: savedWorkout.label
            )
            switch await AtriaWorkoutRouteStore.reconcileAsync(
                from: workout.id,
                to: savedWorkout.id,
                activityType: resolvedType,
                start: savedWorkout.start,
                end: savedWorkout.end
            ) {
            case .success:
                _ = await AtriaWorkoutRouteStore.clearPendingTransactionAsync()
                dismiss()
            case .failure:
                // Route persistence is a separate file from the canonical
                // workout list. Restore the original metadata before reporting
                // failure so Save cannot silently leave the visible workout at
                // a new ID while its route remains attached to the old one.
                let rollback = await store.editConfirmedWorkout(
                    id: savedWorkout.id,
                    label: workout.label,
                    activityType: workout.activityType ?? "",
                    activitySubtype: workout.activitySubtype,
                    start: workout.start,
                    end: workout.end,
                    rest: store.baseline.restingInt ?? 60,
                    maxHR: store.profile.maxHR
                )
                switch rollback {
                case .success(let rolledBackWorkout):
                    let restoredType = AtriaWorkoutActivityType.resolved(
                        activityType: rolledBackWorkout.activityType,
                        subtype: rolledBackWorkout.activitySubtype,
                        label: rolledBackWorkout.label
                    )
                    // Recovery recognizes the rolled-back canonical metadata,
                    // including the rare legacy case where rebuilding the old
                    // window gives it a different deterministic ID.
                    let recovery = await AtriaWorkoutRouteStore.recoverPendingTransactionAsync(
                        canonicalWorkouts: [
                            .init(id: rolledBackWorkout.id,
                                  activityType: restoredType.rawValue,
                                  start: rolledBackWorkout.start,
                                  end: rolledBackWorkout.end)
                        ]
                    )
                    if recovery == .completed || recovery == .noTransaction {
                        saveError = "Atria couldn’t update the saved route, so your original workout was kept unchanged. Try Save again."
                    } else {
                        saveError = "Atria restored the workout details and will finish restoring its route when Activity reopens."
                    }
                case .failure:
                    saveError = "The workout details saved, but its route could not be updated. Close and reopen Activity before trying again."
                }
            }
        case .failure(let error):
            _ = await AtriaWorkoutRouteStore.clearPendingTransactionAsync()
            saveError = error.userMessage
        }
    }

    private func expectedEditedWorkoutID(start: Date, end: Date) -> String {
        let windowChanged = abs(start.timeIntervalSince(workout.start)) >= 0.5
            || abs(end.timeIntervalSince(workout.end)) >= 0.5
        guard windowChanged else { return workout.id }
        return "\(Int(start.timeIntervalSince1970.rounded()))-\(Int(end.timeIntervalSince1970.rounded()))-live_workout_window"
    }

    private func deleteWorkout() {
        guard !isRouteTransactionInFlight else { return }
        isRouteTransactionInFlight = true
        Task { @MainActor in
            await deleteWorkoutAsync()
        }
    }

    private func deleteWorkoutAsync() async {
        defer { isRouteTransactionInFlight = false }
        saveError = nil
        let pendingRecovery = await AtriaWorkoutRouteTransactionRecovery.recover(
            workouts: store.confirmedWorkouts
        )
        guard pendingRecovery != .failed, pendingRecovery != .deferred else {
            saveError = "Atria is still recovering an earlier route update. Close and reopen Activity, then try Delete again."
            return
        }
        guard await AtriaWorkoutRouteStore.beginDeleteTransactionAsync(
            workoutID: workout.id
        ) else {
            saveError = "Atria couldn’t prepare this deletion safely. Nothing was deleted; try again."
            return
        }
        guard await store.deleteConfirmedWorkout(id: workout.id) else {
            _ = await AtriaWorkoutRouteStore.clearPendingTransactionAsync()
            saveError = "Atria couldn’t remove this workout. Nothing was deleted; try again."
            return
        }
        // Metadata is authoritative and must be durably removed first. A route
        // is never discarded while its Activity record may still be present.
        if await AtriaWorkoutRouteStore.deleteAsync(workoutID: workout.id) {
            _ = await AtriaWorkoutRouteStore.clearPendingTransactionAsync()
        }
        dismiss()
    }

    @ViewBuilder
    private var routeCard: some View {
        if let route, route.points.count >= 2 {
            VStack(alignment: .leading, spacing: 10) {
                AtriaSavedWorkoutRouteMap(routeID: route.id,
                                          segments: routeSegments)
                    .equatable()
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 12) {
                    Label(routeDistanceText(route.distanceMeters), systemImage: "location.fill")
                    if let pace = route.averagePaceSecondsPerKilometer {
                        Label(routePaceText(pace), systemImage: "speedometer")
                    }
                    Spacer(minLength: 0)
                    if let routeFileURL {
                        ShareLink(item: routeFileURL) {
                            Label("GPX", systemImage: "square.and.arrow.up")
                                .font(.caption.weight(.bold))
                        }
                    }
                }
                .font(.caption.weight(.semibold).monospacedDigit())
            }
            .padding(12)
            .atriaInsetCard(tint: .cyan)
        }
    }

    private func routeDistanceText(_ meters: Double) -> String {
        meters >= 1_000 ? String(format: "%.2f km", meters / 1_000) : "\(Int(meters.rounded())) m"
    }

    private func routePaceText(_ seconds: TimeInterval) -> String {
        "\(Int(seconds) / 60):\(String(format: "%02d", Int(seconds) % 60))/km"
    }

    private var shareSnapshot: AtriaWorkoutShareSnapshot {
        let shareMetrics = AtriaWorkoutMetricPresentation.shareMetrics(workout)
        let zoneKeys = ["warmup", "fatBurn", "aerobic", "anaerobic", "max"]
        let zoneTints = ["#56d7ff", "#42f59b", "#f5d142", "#ff8a3d", "#ff4f7b"]
        let zones = shareMetrics.includesZoneMinutes ? zoneKeys.enumerated().map({ offset, key in
            AtriaWorkoutShareSnapshot.ZoneMinute(
                id: offset + 1,
                label: "Z\(offset + 1)",
                minutes: Int(((workout.zoneSeconds?[key] ?? 0) / 60).rounded()),
                tintHex: zoneTints[offset]
            )
        }) : []
        let resolvedActivity = AtriaWorkoutActivityType.resolved(activityType: activityType,
                                                                  subtype: workout.activitySubtype,
                                                                  label: workout.label)
        let steps = AtriaWorkoutSharePresentation.completedStepsText(
            count: workout.workoutSteps,
            isEstimated: workout.workoutStepsAreEstimated,
            capturedAt: workout.workoutStepsCapturedAt,
            workoutEndedAt: workout.end,
            activity: resolvedActivity
        )
        return AtriaWorkoutShareSnapshot(
            date: workout.end,
            activity: workout.activitySubtype ?? workout.activityType ?? workout.label,
            duration: durationText(workout.duration),
            strain: shareMetrics.strain,
            peakHeartRate: shareMetrics.peakHeartRate,
            zoneMinutes: zones,
            averageHeartRate: shareMetrics.averageHeartRate,
            distance: route.map { routeDistanceText($0.distanceMeters) },
            pace: route?.averagePaceSecondsPerKilometer.map(routePaceText),
            steps: steps,
            activitySystemImage: AtriaActivityDisplayIcon.icon(
                activityType: workout.activityType,
                subtype: workout.activitySubtype,
                label: workout.label
            ),
            routeFileURL: routeFileURL,
            routePoints: routeSharePreviewPoints
        )
    }

    private var completedWorkoutStepsText: String? {
        guard completedWorkoutStepsPresentation?.isAvailable == true else { return nil }
        return completedWorkoutStepsPresentation?.valueText
    }

    private var completedWorkoutStepsPresentation: AtriaWorkoutSharePresentation.CompletedSteps? {
        let resolvedActivity = AtriaWorkoutActivityType.resolved(
            activityType: workout.activityType,
            subtype: workout.activitySubtype,
            label: workout.label
        )
        return AtriaWorkoutSharePresentation.completedStepsPresentation(
            count: workout.workoutSteps,
            isEstimated: workout.workoutStepsAreEstimated,
            capturedAt: workout.workoutStepsCapturedAt,
            workoutEndedAt: workout.end,
            activity: resolvedActivity
        )
    }

    private func statTile(_ title: String,
                          _ value: String,
                          detail: String? = nil,
                          tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
    }

    private var workoutZoneRows: [(key: String, label: String, range: String, tint: Color, seconds: TimeInterval)] {
        let zones = workout.zoneSeconds ?? [:]
        func range(_ zone: HRZone) -> String {
            workout.zoneBoundaries?.rangeText(for: zone) ?? "Legacy range"
        }
        return [
            ("max", "Z5 · Max", range(.max), Metrics.heartRateZoneTint(5), zones["max"] ?? 0),
            ("anaerobic", "Z4 · Anaerobic", range(.anaerobic), Metrics.heartRateZoneTint(4), zones["anaerobic"] ?? 0),
            ("aerobic", "Z3 · Aerobic", range(.aerobic), Metrics.heartRateZoneTint(3), zones["aerobic"] ?? 0),
            ("fatBurn", "Z2 · Fat burn", range(.fatBurn), Metrics.heartRateZoneTint(2), zones["fatBurn"] ?? 0),
            ("warmup", "Z1 · Warm-up", range(.warmup), Metrics.heartRateZoneTint(1), zones["warmup"] ?? 0),
            ("rest", "Z0 · Restorative", range(.rest), Metrics.heartRateZoneTint(0), zones["rest"] ?? 0)
        ]
    }

    private var recordedZoneSeconds: TimeInterval {
        workoutZoneRows.reduce(0) { $0 + $1.seconds }
    }

    @ViewBuilder
    private var workoutZoneDistributionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Time in heart-rate zones")
                            .font(.headline.weight(.bold))
                        Text(workout.zoneBoundaries == nil
                             ? "Legacy ranges · recorded heart-rate time"
                             : "Frozen HR-reserve ranges · recorded heart-rate time")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if recordedZoneSeconds > 0 {
                        Text(durationText(recordedZoneSeconds))
                            .font(.subheadline.weight(.black).monospacedDigit())
                            .foregroundStyle(Metrics.electricStrain)
                    }
                }

                if recordedZoneSeconds > 0 {
                    ForEach(workoutZoneRows, id: \.key) { zone in
                        workoutZoneRow(zone)
                    }
                } else {
                    Label("Zone distribution is unavailable for this recording. Atria saved the workout summary, but not enough heart-rate samples to place time in zones.",
                          systemImage: "waveform.path.ecg.rectangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                }
        }
        .padding(14)
        .atriaInsetCard(tint: Metrics.electricStrain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(recordedZoneSeconds > 0
                            ? zoneDistributionAccessibilityLabel
                            : "Time in heart-rate zones unavailable. Workout summary saved, but heart-rate zone samples were not recorded.")
    }

    private func workoutZoneRow(_ zone: (key: String, label: String, range: String, tint: Color, seconds: TimeInterval)) -> some View {
        let fraction = min(max(zone.seconds / recordedZoneSeconds, 0), 1)
        let percent = Int((fraction * 100).rounded())
        return VStack(spacing: 5) {
            HStack(spacing: 8) {
                Text(zone.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(zone.range)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Text("\(percent)%")
                    .font(.caption2.weight(.black).monospacedDigit())
                    .foregroundStyle(zone.tint)
                Text(durationText(zone.seconds))
                    .font(.caption.weight(.bold).monospacedDigit())
                    .frame(minWidth: 42, alignment: .trailing)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(zone.tint)
                        .frame(width: max(0, proxy.size.width * fraction))
                }
            }
            .frame(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(zone.label), \(zone.range), \(percent) percent, \(durationText(zone.seconds))")
    }

    private var zoneDistributionAccessibilityLabel: String {
        let summary = workoutZoneRows
            .filter { $0.seconds > 0 }
            .map { "\($0.label) \(durationText($0.seconds))" }
            .joined(separator: ", ")
        return "Time in heart-rate zones. \(durationText(recordedZoneSeconds)) of recorded heart-rate time. \(summary)"
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let totalMinutes = Int((interval / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d · h:mm a"
        return formatter
    }()

    private static func rangeText(_ workout: UserConfirmedWorkout) -> String {
        rangeFormatter.string(from: workout.start)
    }
}

/// Keeps MapKit's route overlay independent from name/type/time editor state.
/// Coordinates are converted once when the detail sheet is initialized; the
/// Equatable boundary then prevents unrelated editor writes from rebuilding the
/// map hierarchy or its polyline.
private struct AtriaSavedWorkoutRouteMap: View, Equatable {
    let routeID: String
    let segments: [[CLLocationCoordinate2D]]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.routeID == rhs.routeID
    }

    var body: some View {
        Map {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, coordinates in
                MapPolyline(coordinates: coordinates)
                    .stroke(.cyan,
                            style: StrokeStyle(lineWidth: 5,
                                               lineCap: .round,
                                               lineJoin: .round))
            }
            if let start = segments.first?.first {
                Marker("Start", systemImage: "flag.fill", coordinate: start)
                    .tint(.green)
            }
            if let finish = segments.last?.last {
                Marker("Finish", systemImage: "flag.checkered", coordinate: finish)
                    .tint(.red)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }
}

struct AtriaActivityRecoveryEffect: Equatable {
    enum Status: Equatable {
        case observed(delta: Int, recovery: Int, baseline: Int, samples: Int)
        case pending
        case learning
        case unavailable
    }

    let status: Status

    static func make(workout: UserConfirmedWorkout,
                     rollups: [DailyRollupStoreEntry],
                     confirmedSleeps: [UserConfirmedSleep],
                     calendar: Calendar,
                     now: Date = Date()) -> Self {
        guard let recoverySleep = AtriaHistoricalPhysiologicalCycle.followingRecoverySleep(
            for: workout,
            confirmedSleeps: confirmedSleeps,
            calendar: calendar
        ) else {
            let isPending = AtriaHistoricalPhysiologicalCycle.recoveryAttributionIsPending(
                for: workout,
                confirmedSleeps: confirmedSleeps,
                now: now,
                calendar: calendar
            )
            return Self(status: isPending ? .pending : .unavailable)
        }
        return make(rollups: rollups,
                    recoverySleep: recoverySleep,
                    calendar: calendar,
                    now: now)
    }

    static func make(workout: UserConfirmedWorkout,
                     rollups: [DailyRollupStoreEntry],
                     sleepHistory: SleepHistorySnapshot,
                     calendar: Calendar,
                     now: Date = Date()) -> Self {
        guard let recoverySleep = AtriaHistoricalPhysiologicalCycle.followingRecoverySleep(
            for: workout,
            sleepHistory: sleepHistory,
            calendar: calendar
        ) else {
            let isPending = AtriaHistoricalPhysiologicalCycle.recoveryAttributionIsPending(
                for: workout,
                sleepHistory: sleepHistory,
                now: now,
                calendar: calendar
            )
            return Self(status: isPending ? .pending : .unavailable)
        }
        return make(rollups: rollups,
                    recoverySleep: recoverySleep,
                    calendar: calendar,
                    now: now)
    }

    private static func make(rollups: [DailyRollupStoreEntry],
                             recoverySleep: UserConfirmedSleep,
                             calendar: Calendar,
                             now: Date) -> Self {
        let recoveryDay = EventCivilTime.day(
            containing: recoverySleep.end,
            eventTimeZoneIdentifier: recoverySleep.eventTimeZoneIdentifier,
            outputCalendar: calendar
        )
        let observed = rollups.first {
            calendar.isDate($0.day, inSameDayAs: recoveryDay) && $0.recovery != nil
        }?.recovery
        guard let observed else {
            return Self(status: recoveryDay >= calendar.startOfDay(for: now) ? .pending : .learning)
        }
        let baselineScores = rollups
            .filter { $0.day < recoveryDay && $0.day >= (calendar.date(byAdding: .day, value: -14, to: recoveryDay) ?? .distantPast) }
            .sorted { $0.day > $1.day }
            .compactMap(\.recovery)
            .prefix(7)
        guard baselineScores.count >= 3 else { return Self(status: .learning) }
        let baseline = Int((Double(baselineScores.reduce(0, +)) / Double(baselineScores.count)).rounded())
        return Self(status: .observed(delta: observed - baseline,
                                      recovery: observed,
                                      baseline: baseline,
                                      samples: baselineScores.count))
    }

    var valueText: String {
        switch status {
        case let .observed(delta, recovery, _, _):
            return "\(recovery)% · \(String(format: "%+d", delta)) pts"
        case .pending: return "After your next sleep"
        case .learning: return "Learning your response"
        case .unavailable: return "Not available"
        }
    }

    var detail: String {
        switch status {
        case let .observed(_, _, baseline, samples):
            return "Next-morning recovery versus your preceding \(samples)-day average of \(baseline)%. This is a personal association, not proof the activity caused the change."
        case .pending:
            return "A confirmed main sleep must close this physiological day before Atria can attach recovery."
        case .learning:
            return "At least three prior recovery days are needed for a useful personal comparison."
        case .unavailable:
            return "No confirmed main sleep closed this physiological day before its no-sleep rollover, so no recovery score is attached."
        }
    }

    var tint: Color {
        switch status {
        case let .observed(delta, _, _, _): return delta >= 0 ? .green : .orange
        case .pending: return .blue
        case .learning, .unavailable: return .secondary
        }
    }
}

/// Manually log a workout for a past window the strap recorded but the detector
/// didn't surface (e.g. a walk or dance you wore the strap for). Metrics are
/// derived from the strap samples in that window — if there were none, it can't
/// be saved, because Atria never invents heart rate or strain.
struct AtriaAddWorkoutSheet: View {
    let store: SessionStore
    private let reviewCandidateID: String?
    private let settlingCandidateWindow: (start: Date, end: Date)?
    private let onDismissCandidate: (() -> Bool)?
    @Environment(\.dismiss) private var dismiss

    @State private var activityLabel: String
    @State private var activityType: String
    @State private var activitySubtype: String?
    @State private var startTime: Date
    @State private var endTime: Date
    @State private var failed = false
    @State private var isSaving = false
    @State private var showDismissConfirmation = false
    @State private var dismissFailed = false

    /// A detector-backed sheet is editing an existing suggestion, while the
    /// plain flow creates a new item. Keep the commit verb aligned with the
    /// sleep/nap review lifecycle instead of presenting the same operation as
    /// “Add” in one Activity surface and “Save” in another.
    private var commitTitle: String {
        settlingCandidateWindow == nil ? "Add workout" : "Save"
    }

    private var navigationTitle: String {
        settlingCandidateWindow == nil ? "Add workout" : "Review activity"
    }

    /// Seedable window (2026-07-07): the detections inbox opens this sheet
    /// pre-filled with a detected-but-unsaved window. Internal (not private)
    /// for that same reason.
    init(store: SessionStore,
         initialStart: Date? = nil,
         initialEnd: Date? = nil,
         reviewCandidateID: String? = nil,
         settlingCandidateWindow: (start: Date, end: Date)? = nil,
         onDismissCandidate: (() -> Bool)? = nil) {
        self.store = store
        self.reviewCandidateID = reviewCandidateID
        self.settlingCandidateWindow = settlingCandidateWindow
        self.onDismissCandidate = onDismissCandidate
        let now = Date()
        let isDetectorReview = reviewCandidateID != nil || settlingCandidateWindow != nil
        _activityLabel = State(initialValue: isDetectorReview
            ? ""
            : AtriaWorkoutActivityType.walking.rawValue)
        _activityType = State(initialValue: isDetectorReview
            ? ""
            : AtriaWorkoutActivityType.walking.rawValue)
        _endTime = State(initialValue: initialEnd ?? now)
        _startTime = State(initialValue: initialStart ?? (initialEnd ?? now).addingTimeInterval(-45 * 60))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Activity name", text: $activityLabel)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.done)

                        Divider()

                        Menu {
                            ForEach(AtriaActivityWorkoutDetailSheet.activityTypes, id: \.self) { type in
                                Button {
                                    let previousType = activityType
                                    activityType = type
                                    activitySubtype = AtriaWorkoutActivityType(rawValue: type)?
                                        .normalizedSubtype(activitySubtype)
                                    if activityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .localizedCaseInsensitiveCompare(previousType) == .orderedSame {
                                        activityLabel = type
                                    }
                                } label: {
                                    Label(type,
                                          systemImage: AtriaWorkoutActivityType(rawValue: type)?.icon
                                              ?? AtriaWorkoutActivityType.other.icon)
                                }
                            }
                        } label: {
                            HStack {
                                Text("Activity")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: AtriaWorkoutActivityType(rawValue: activityType)?.icon
                                      ?? AtriaWorkoutActivityType.other.icon)
                                    .foregroundStyle(.secondary)
                                Text(activityType.isEmpty ? "Choose" : activityType)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }

                        if let selectedType = AtriaWorkoutActivityType(rawValue: activityType),
                           !selectedType.subtypeOptions.isEmpty {
                            Divider()

                            Menu {
                                ForEach(selectedType.subtypeOptions, id: \.self) { subtype in
                                    Button {
                                        activitySubtype = subtype
                                    } label: {
                                        if activitySubtype == subtype {
                                            Label(subtype, systemImage: "checkmark")
                                        } else {
                                            Text(subtype)
                                        }
                                    }
                                }
                                if activitySubtype != nil {
                                    Button("Clear style", role: .destructive) {
                                        activitySubtype = nil
                                    }
                                }
                            } label: {
                                HStack {
                                    Text("Style")
                                    Spacer()
                                    Text(activitySubtype ?? "Choose")
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                            }
                        }

                        Divider()

                        VStack(spacing: 6) {
                            DatePicker("Start", selection: $startTime, displayedComponents: [.date, .hourAndMinute])
                            DatePicker("End", selection: $endTime, in: startTime..., displayedComponents: [.date, .hourAndMinute])
                        }
                        .font(.subheadline.weight(.semibold))

                        if endTime > startTime {
                            AtriaEventWindowTimeline(title: "Workout window",
                                                     start: startTime,
                                                     end: endTime,
                                                     tint: Metrics.electricStrain)
                        }
                    }
                    .padding(14)
                    .atriaCard(emphasis: .soft)

                    if failed {
                        Text("Couldn't save this workout. Try again.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: add) {
                        HStack(spacing: 8) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isSaving ? "Saving…" : commitTitle)
                                .font(.subheadline.weight(.bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Metrics.electricStrain)
                    .disabled(isSaving
                              || endTime <= startTime
                              || activityType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || activityLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                if onDismissCandidate != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Dismiss suggestion", systemImage: "trash", role: .destructive) {
                                showDismissConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("Suggestion actions")
                        .disabled(isSaving)
                    }
                }
            }
            .confirmationDialog("Dismiss this activity suggestion?",
                                isPresented: $showDismissConfirmation,
                                titleVisibility: .visible) {
                Button("Dismiss suggestion", role: .destructive) {
                    guard let onDismissCandidate else { return }
                    if onDismissCandidate() {
                        dismiss()
                    } else {
                        dismissFailed = true
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes this suggestion from Activity without deleting recorded strap data or day strain.")
            }
            .alert("Couldn't dismiss activity", isPresented: $dismissFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The suggestion is still available. Please try again.")
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private func add() {
        guard !isSaving, endTime > startTime else { return }
        let requestedStart = startTime
        let requestedEnd = endTime
        let requestedLabel = activityLabel
        let requestedType = activityType
        let requestedSubtype = activitySubtype
        let candidateID = reviewCandidateID
        let candidateWindow = settlingCandidateWindow
        let rest = store.baseline.restingInt ?? 60
        let maximumHeartRate = store.profile.maxHR
        failed = false
        isSaving = true
        Task { @MainActor in
            let result = await store.confirmWorkoutWindowForUIAsync(
                start: requestedStart,
                end: requestedEnd,
                rest: rest,
                maxHR: maximumHeartRate,
                source: "manual_activity_add",
                preserveUserDeclaredActivityWithoutHeartRate: true,
                activityLabel: requestedLabel,
                activityType: requestedType,
                activitySubtype: requestedSubtype,
                reviewSource: candidateID == nil ? nil : "detected_activity_review",
                reviewCandidateID: candidateID,
                settlingCandidateWindow: candidateWindow
            )
            isSaving = false
            if result != nil {
                // Candidate settlement is part of the canonical store operation
                // above. Keep `onDismissCandidate` exclusively for the explicit
                // destructive action so Save can never become a second UI-owned
                // persistence sequence. A plain manual Add passes no candidate
                // window and retains its existing re-add semantics.
                dismiss()
            } else {
                failed = true
            }
        }
    }
}

struct AtriaWorkoutStressTraceSummary: Equatable {
    let points: [AtriaStressTimelinePoint]

    init(readings: [AtriaStressDetailReading]) {
        // Display-continuity policy: brief signal hiccups (≤5 min) read as one
        // smooth run; only a genuine >5-min dropout still splits the trace and
        // stays blank. The strict fact-continuity default is left untouched for
        // consumers that need it.
        self.points = AtriaStressTimelinePoint.segment(
            readings,
            gapThreshold: AtriaChartVisualGrammar.traceDisplayContinuityGap)
    }

    var readingCount: Int { points.count }
    var low: Double? { points.map(\.reading.score).min() }
    var high: Double? { points.map(\.reading.score).max() }
}

/// In-activity physiological-stress trace: the same continuous 0–3 v3 scale,
/// real gaps, and lower-confidence HR-only provenance as the live timeline.
struct AtriaWorkoutStressTraceChart: View {
    let readings: [AtriaStressDetailReading]

    private var summary: AtriaWorkoutStressTraceSummary {
        AtriaWorkoutStressTraceSummary(readings: readings)
    }

    private var points: [AtriaStressTimelinePoint] { summary.points }
    private var low: Double { summary.low ?? 0 }
    private var high: Double { summary.high ?? 0 }
    private var singletonSegmentIDs: Set<Int> {
        Set(Dictionary(grouping: points, by: \.segment)
            .filter { $0.value.count == 1 }
            .map { $0.key })
    }

    var body: some View {
        let singletonSegments = singletonSegmentIDs
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.1f min", low))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Metrics.electricGreen)
                Spacer()
                Text(String(format: "max %.1f", high))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Metrics.electricRed)
            }
            Chart {
                RectangleMark(xStart: .value("Calm start", points.first?.reading.date ?? .distantPast),
                              xEnd: .value("Calm end", points.last?.reading.date ?? .distantFuture),
                              yStart: .value("Calm floor", 0),
                              yEnd: .value("Calm ceiling", 1))
                    .foregroundStyle(Metrics.electricGreen.opacity(0.055))
                RectangleMark(xStart: .value("Moderate start", points.first?.reading.date ?? .distantPast),
                              xEnd: .value("Moderate end", points.last?.reading.date ?? .distantFuture),
                              yStart: .value("Moderate floor", 1),
                              yEnd: .value("Moderate ceiling", 2))
                    .foregroundStyle(Metrics.electricYellow.opacity(0.045))
                RectangleMark(xStart: .value("High start", points.first?.reading.date ?? .distantPast),
                              xEnd: .value("High end", points.last?.reading.date ?? .distantFuture),
                              yStart: .value("High floor", 2),
                              yEnd: .value("High ceiling", 3))
                    .foregroundStyle(Metrics.electricRed.opacity(0.045))
                RuleMark(y: .value("Calm to moderate", 1))
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
                    .foregroundStyle(.secondary.opacity(0.18))
                RuleMark(y: .value("Moderate to high", 2))
                    .lineStyle(StrokeStyle(lineWidth: 0.75))
                    .foregroundStyle(.secondary.opacity(0.18))

                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.reading.date),
                             y: .value("Stress", point.reading.score),
                             series: .value("Segment", point.segment))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.linearGradient(
                            colors: [Metrics.electricGreen.opacity(0.04),
                                     Metrics.electricYellow.opacity(0.10),
                                     Metrics.electricRed.opacity(0.16)],
                            startPoint: .bottom,
                            endPoint: .top
                        ))
                    LineMark(x: .value("Time", point.reading.date),
                             y: .value("Stress", point.reading.score),
                             series: .value("Segment", point.segment))
                        // The app now favors a continuous read: .monotone joins
                        // the real endpoint scores smoothly (matching the live
                        // and ambient stress traces). It is shape-preserving, so
                        // it never bridges a genuine >5-min gap — those still
                        // break as separate segments and stay blank.
                        .interpolationMethod(.monotone)
                        .lineStyle(AtriaChartVisualGrammar.traceLine)
                        .foregroundStyle(
                            .linearGradient(colors: [Metrics.electricGreen,
                                                     Metrics.electricYellow,
                                                     Metrics.electricRed],
                                            startPoint: .bottom,
                                            endPoint: .top)
                        )
                    if singletonSegments.contains(point.segment) {
                        PointMark(x: .value("Time", point.reading.date),
                                  y: .value("Stress", point.reading.score))
                            .foregroundStyle(point.reading.score >= 2
                                ? Metrics.electricRed
                                : Metrics.electricGreen)
                            .symbolSize(20)
                    }
                }
            }
            .chartYScale(domain: 0...AtriaStressEvidenceProjection.maximumDisplayValue)
            .chartYAxis {
                AxisMarks(values: [0, 1, 2, 3]) { _ in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.caption2)
                }
            }
            .atriaGraphPlotSurface()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(workoutStressAccessibilityLabel)
    }

    private var workoutStressAccessibilityLabel: String {
        let runCount = Set(points.map(\.segment)).count
        let gapText = runCount > 1
            ? " \(runCount) measured runs; gaps contain no recorded stress score."
            : ""
        return String(format: "%d measured stress readings during this workout, %.1f to %.1f on a 0 to 3 scale.",
                      summary.readingCount, low, high) + gapText
    }
}

/// Review-first sleep sheet for the Activity list (2026-08-06 user feedback:
/// tapping a sleep opened only the bare time editor). Hosts the SHARED
/// hypnogram card — which renders its own honest needs-motion / building /
/// manual states — plus a WHOOP-style stage breakdown and the night's
/// measured vitals. Every row is evidence-gated: stages render only when
/// display segments exist, efficiency uses the honesty-gated display value,
/// and absent vitals show the canonical "--" token.
/// Logged muscular input for a completed strength workout. Extracted from the
/// workout summary so it is independently renderable/testable (GAP-09): it
/// distinguishes measured external load from a body-mass estimate and states
/// outright that it is separate from cardiovascular Strain.
struct AtriaMuscularLoadSummary: View {
    let receipt: AtriaStrengthLog.MuscularLoadReceipt
    let isFrozen: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logged muscular input")
                        .font(.caption.weight(.bold))
                    Text("\(Int(receipt.volumeKg.rounded())) kg volume · \(receipt.qualifiedSetCount) loaded sets\(receipt.densityBonusFraction > 0 ? " · observed superset density" : "")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(receipt.loadBasisText,
                          systemImage: receipt.includesBodyweightEstimate ? "scalemass" : "dumbbell")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(receipt.includesBodyweightEstimate ? Color.orange.opacity(0.85) : Color.secondary)
                    Text(receipt.rpeCoverageText)
                        .font(.caption2)
                        .foregroundStyle(receipt.hasCompleteEffortEvidence ? Color.secondary : Color.orange)
                }
                Spacer()
                if let score = receipt.score {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(score.rounded()))")
                            .font(.title3.weight(.black).monospacedDigit())
                            .foregroundStyle(.orange)
                        Text("relative input")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Add RPE")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            Text(receipt.hasCompleteEffortEvidence
                 ? "\(isFrozen ? "Frozen with this workout" : "Legacy recomputation") · separate from cardiovascular Strain"
                 : "Add RPE to every loaded set for a relative input estimate. It never changes cardiovascular Strain.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct AtriaSleepActivityReviewSheet: View {
    let night: SleepHistorySnapshot.Night
    /// Personal resting-HR baseline, threaded from the presenting store so the
    /// overnight HR-load trace here reads the same resting reference the Health
    /// screen uses. Falls back to the night's own measured resting HR.
    var restingBaseline: Int? = nil
    /// GAP-07: the user's typical overnight resting-HR band, shaded behind the
    /// heart-rate trace when enough qualified nights exist.
    var typicalRestingBand: ClosedRange<Double>? = nil
    /// Canonical saved-session points and observed HR history for this night's
    /// window, threaded from the presenting store so the overnight HR trace
    /// unions the same exact-window evidence as the Activity day timeline. Empty
    /// by default keeps existing presentations archive-only with no regression.
    var overnightSessions: [SavedSession] = []
    var overnightObservedHeartRate: [HistoricalArchive.HeartRatePoint] = []
    let onEditTimes: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// GAP-07: the exact same overnight HR trace / HR-load reading shown on the
    /// Health screen, now surfaced in the Sleep detail from this night's real
    /// archived heart-rate rows. Missing wear stays a gap; nothing is inferred.
    @State private var overnightHRProjection = AtriaSleepStressProjection.unavailable

    private var spanSeconds: TimeInterval {
        guard let start = night.start, let end = night.end, end > start else {
            return night.duration
        }
        return end.timeIntervalSince(start)
    }

    private var stageRows: [(stage: SleepStageKind, seconds: TimeInterval)] {
        guard !night.displayStageSegments.isEmpty else { return [] }
        return SleepStageKind.displayOrder.compactMap { stage in
            let seconds = night.stageDuration(stage)
                + (stage == .deep ? night.stageDuration(.sws) : 0)
            guard seconds > 0 else { return nil }
            return (stage, seconds)
        }
    }

    private static func hoursMinutes(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) m" : "\(minutes) m"
    }

    /// The night's recorded event timezone (GAP-07): a travel night renders in
    /// the clock it was slept in, not the phone's current zone. Falls back to the
    /// device zone for legacy nights without a recorded identifier.
    private var eventTimeZone: TimeZone {
        night.eventTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// Short local clock text in the night's event zone. Uses an explicit
    /// FormatStyle timeZone rather than the SwiftUI environment, which a bare
    /// `.formatted()` string does not consult.
    private func clockText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: eventTimeZone))
    }

    private struct OvernightTraceKey: Equatable {
        let id: String
        let start: Date?
        let end: Date?
        let resting: Int?
    }

    private var overnightTraceKey: OvernightTraceKey {
        OvernightTraceKey(id: night.id,
                          start: night.start,
                          end: night.end,
                          resting: restingBaseline ?? night.restingHR)
    }

    /// Reads this night's real archived heart-rate rows over the exact saved
    /// sleep window (its own timestamps, so travel nights are not reinterpreted
    /// against the phone's current clock) and builds the same 5-minute-bucket
    /// projection the Health screen uses. Missing wear stays a gap.
    @MainActor
    private func refreshOvernightHRProjection() async {
        guard let start = night.start, let end = night.end, end > start else {
            overnightHRProjection = .unavailable
            return
        }
        let resting = restingBaseline ?? night.restingHR
        let sessions = overnightSessions
        let observed = overnightObservedHeartRate
        if overnightHRProjection.availability != .ready {
            overnightHRProjection = .loading
        }
        let projection = await Task.detached(priority: .utility) {
            AtriaSleepStressArchiveProjection.load(
                sleepStart: start,
                sleepEnd: end,
                restingHeartRate: resting,
                sessions: sessions,
                observed: observed
            )
        }.value
        guard !Task.isCancelled else { return }
        overnightHRProjection = projection
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    AtriaSleepHypnogramCard(night: night)
                    if !stageRows.isEmpty {
                        stageBreakdown
                    }
                    nightVitals
                    AtriaSleepStressCard(projection: overnightHRProjection,
                                         displayTimeZone: eventTimeZone,
                                         typicalRestingBand: typicalRestingBand)
                    Button(action: onEditTimes) {
                        Label("Edit sleep times", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(prominent: false, tint: Metrics.electricSleep)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .task(id: overnightTraceKey) { await refreshOvernightHRProjection() }
            .navigationTitle("Sleep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.hoursMinutes(night.duration))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            if let start = night.start, let end = night.end {
                Text("\(clockText(start)) – \(clockText(end)) · \(night.stageEvidence.label)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(night.stageEvidence.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var stageBreakdown: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("STAGES")
                .font(.caption2.weight(.black))
                .foregroundStyle(.tertiary)
                .kerning(0.8)
            ForEach(stageRows, id: \.stage) { row in
                let fraction = spanSeconds > 0 ? row.seconds / spanSeconds : 0
                HStack(spacing: 10) {
                    Text(row.stage.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AtriaSleepHypnogramCard.color(for: row.stage).opacity(0.18))
                            Capsule()
                                .fill(AtriaSleepHypnogramCard.color(for: row.stage))
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 8)
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text(Self.hoursMinutes(row.seconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: Metrics.electricSleep)
    }

    private var nightVitals: some View {
        HStack(spacing: 0) {
            vitalsCell("Efficiency",
                       night.displaySleepEfficiency.map { "\(Int(($0 * 100).rounded()))%" } ?? "--",
                       footnote: night.displaySleepEfficiency == nil ? night.sleepEfficiencyFootnote : nil)
            vitalsCell("RHR", night.restingHR.map { "\($0)" } ?? "--")
            vitalsCell("HRV", night.hrv.map { "\($0)" } ?? "--")
            vitalsCell("Resp", night.respiratoryRate.map { String(format: "%.1f", $0) } ?? "--")
        }
        .padding(.vertical, 10)
        .atriaInsetCard(tint: Metrics.electricSleep)
    }

    private func vitalsCell(_ title: String, _ value: String, footnote: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
