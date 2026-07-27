import SwiftUI
import Charts
import MapKit

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
                    isCurrentPhysiologicalDay: true)
    }

    static func historical(day: Date, calendar: Calendar = .current) -> Self {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return Self(interval: DateInterval(start: start, end: end),
                    labelDay: start,
                    isCurrentPhysiologicalDay: false)
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
        workouts.filter { $0.end > $0.start && $0.end > interval.start && $0.start < interval.end }
    }
    static func overlapping(_ workouts: [UserConfirmedWorkout],
                            selectedDay: Date,
                            calendar: Calendar) -> [UserConfirmedWorkout] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            return []
        }
        return workouts.filter {
            $0.end > $0.start && $0.end > dayStart && $0.start < dayEnd
        }
    }
}

/// One canonical sleep/nap projection for the Activity row list and timeline.
/// A pending detector window that substantially overlaps an already-saved
/// night is not a second activity, and a cross-midnight sleep must remain
/// selectable on every day where its timeline marker is visible.
enum AtriaActivitySelectedDaySleeps {
    static func canonical(snapshot: SleepHistorySnapshot,
                          pendingReview: SleepHistorySnapshot.Night?) -> [SleepHistorySnapshot.Night] {
        var byID = (snapshot.nights + snapshot.additionalMainNights + snapshot.napNights)
            .reduce(into: [String: SleepHistorySnapshot.Night]()) { result, night in
                result[night.id] = night
            }
        if let pendingReview,
           !pendingReview.confirmed,
           !byID.values.contains(where: { substantiallyOverlaps($0, pendingReview) }) {
            byID[pendingReview.id] = pendingReview
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
                            selectedDay: Date,
                            calendar: Calendar) -> [SleepHistorySnapshot.Night] {
        let dayStart = calendar.startOfDay(for: selectedDay)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return canonical(snapshot: snapshot, pendingReview: pendingReview).filter { night in
            if let start = night.start, let end = night.end, end > start {
                return end > dayStart && start < dayEnd
            }
            // Legacy summaries may not carry exact bounds. Their attributed
            // civil day remains the only truthful placement available.
            return calendar.isDate(night.day, inSameDayAs: dayStart)
        }
    }

    static func overlapping(snapshot: SleepHistorySnapshot,
                            pendingReview: SleepHistorySnapshot.Night?,
                            interval: DateInterval,
                            calendar: Calendar) -> [SleepHistorySnapshot.Night] {
        canonical(snapshot: snapshot, pendingReview: pendingReview).filter { night in
            if let start = night.start, let end = night.end, end > start {
                return end > interval.start && start < interval.end
            }
            return calendar.isDate(night.day, inSameDayAs: interval.start)
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
    @ObservedObject var activityStore: AtriaHomeModel.ActivityStore
    /// Retained without observation for action sheets, which observe it only
    /// while presented.
    let store: SessionStore
    /// Opens the existing manual-sleep sheet seeded with this night for editing.
    let onEditSleep: (SleepHistorySnapshot.Night) -> Void
    /// Opens the manual-sleep sheet with no seed, to add a fresh sleep or nap.
    let onAddSleep: () -> Void

    @State private var workoutDetail: UserConfirmedWorkout?
    @State private var showAddWorkout = false
    @State private var reviewWorkoutWindow: ReviewWorkoutWindow?
    /// Day shown in the header timeline (user feedback 2026-07-07: "the top
    /// of activity should have an entire graph with activities listed and
    /// days can be changed").
    @State private var timelineDay: Date = Calendar.current.startOfDay(for: Date())
    @State private var viewingCurrentPhysiologicalDay = true
    @State private var activityMemo = AtriaActivityMonitorMemo()
    @State private var daySectionsCache = AtriaActivitySectionsCache<[DaySection]>()

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
        let workoutReview: WorkoutReviewCandidate?
        let detections: [ActivityDetection]
        let rollups: [DailyRollupStoreEntry]
        let selectedDayStart: Date
        let interval: DateInterval
        let calendar: Calendar
    }

    private struct DaySectionsResult: @unchecked Sendable {
        let sections: [DaySection]
    }

    var body: some View {
        let calendar = Calendar.current
        let activity = activityStore.state
        let displayWindow = viewingCurrentPhysiologicalDay
            ? AtriaActivityDisplayWindow.current(now: Date(),
                                                 sleepHistory: activity.sleepHistorySnapshot,
                                                 calendar: calendar)
            : AtriaActivityDisplayWindow.historical(day: timelineDay, calendar: calendar)
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

            dayTimelineCard

            let sections = daySectionsCache.value(for: requestKey) ?? []
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
        .sheet(item: $workoutDetail) { workout in
            AtriaActivityWorkoutDetailSheet(store: store, workout: workout)
                .presentationDetents([.medium, .large])
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
    }

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

            Text(viewingCurrentPhysiologicalDay
                 ? "Today"
                 : timelineDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityLabel(timelineDay.formatted(date: .complete, time: .omitted))

            Button {
                if let next = calendar.date(byAdding: .day, value: 1, to: timelineDay) {
                    if next >= currentDisplayWindow.labelDay {
                        timelineDay = currentDisplayWindow.labelDay
                        viewingCurrentPhysiologicalDay = true
                    } else {
                        timelineDay = next
                    }
                }
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
                                               workoutReview: activity.workoutReviewCandidate,
                                               detections: activity.activityDetections,
                                               rollups: activity.dailyRollupHistory,
                                               selectedDayStart: key.selectedDayStart,
                                               interval: DateInterval(start: key.intervalStart, end: key.intervalEnd),
                                               calendar: calendar)
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
            interval: source.interval,
            calendar: source.calendar
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
        // Every workout on a given day has the same next-morning comparison.
        // Derive it once per day off-main, then make row lookup O(1).
        var recoveryEffectsByDay: [Date: AtriaActivityRecoveryEffect] = [:]
        var recoveryEffects: [String: AtriaActivityRecoveryEffect] = [:]
        for workout in selectedWorkouts {
            let day = source.calendar.startOfDay(for: workout.start)
            let effect: AtriaActivityRecoveryEffect
            if let cached = recoveryEffectsByDay[day] {
                effect = cached
            } else {
                effect = AtriaActivityRecoveryEffect.make(workout: workout,
                                                          rollups: source.rollups,
                                                          calendar: source.calendar)
                recoveryEffectsByDay[day] = effect
            }
            recoveryEffects[workout.id] = effect
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

    private var timelineSpans: [TimelineSpan] {
        let activity = activityStore.state
        let window = currentDisplayWindow
        return activityMemo.timelineSpans(sleepRevision: activity.sleepHistorySnapshotRevision,
                                          workoutsRevision: activity.confirmedWorkoutsRevision,
                                          detectionsRevision: activity.historySnapshotRevision,
                                          reviewFingerprint: activity.reviewFingerprint,
                                          displayWindow: window,
                                          sleepSnapshot: activity.sleepHistorySnapshot,
                                          pendingSleepReview: activity.pendingSleepReview,
                                          workouts: activity.confirmedWorkouts,
                                          workoutReview: activity.workoutReviewCandidate,
                                          detections: activity.activityDetections,
                                          calendar: .current)
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
            : AtriaActivityDisplayWindow.historical(day: timelineDay, calendar: calendar)
    }

    private var dayTimelineCard: some View {
        let calendar = Calendar.current
        let window = currentDisplayWindow
        let dayStart = window.interval.start
        let dayEnd = window.interval.end
        let spans = timelineSpans
        let axisTicks = AtriaActivityTimelineAxis.ticks(interval: window.interval,
                                                        isCurrent: window.isCurrentPhysiologicalDay,
                                                        calendar: calendar)

        return VStack(alignment: .leading, spacing: 0) {
            if spans.isEmpty {
                Chart {
                    RuleMark(y: .value("Lane", 0))
                        .foregroundStyle(.clear)
                }
                .chartXScale(domain: dayStart...dayEnd)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: axisTicks.map(\.date)) { value in
                        AxisGridLine().foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel(centered: true) {
                            if let date = value.as(Date.self),
                               let tick = AtriaActivityTimelineAxis.tick(at: date, in: axisTicks) {
                                Text(tick.label)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(height: 44)
                .accessibilityLabel("No recorded activity for this day")
            } else {
                Chart(spans) { span in
                    BarMark(xStart: .value("Start", span.start),
                            xEnd: .value("End", span.end),
                            y: .value("Lane", span.lane))
                        .foregroundStyle(span.tint.opacity(0.85))
                        .cornerRadius(4)

                    // A true-duration bar can be sub-pixel for a one-minute
                    // activity on a 24-hour axis. Keep duration honest while
                    // guaranteeing every saved activity has a visible marker.
                    PointMark(x: .value("Activity", span.midpoint),
                              y: .value("Lane", span.lane))
                        .foregroundStyle(span.tint)
                        .symbolSize(360)
                        .annotation(position: .overlay, spacing: 0) {
                            Image(systemName: span.icon)
                                .font(.caption.weight(.black))
                                .foregroundStyle(.white)
                                .accessibilityHidden(true)
                        }
                }
                .chartXScale(domain: dayStart...dayEnd)
                // Four hours makes adjacent activities readable instead of
                // compressing a whole physiological day into one tiny strip.
                // The remaining day stays available via native horizontal
                // scrolling; full-screen inspection also supports pinch zoom.
                .chartScrollableAxes(.horizontal)
                .chartXVisibleDomain(length: 4 * 60 * 60)
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: axisTicks.map(\.date)) { value in
                        AxisGridLine()
                            .foregroundStyle(.secondary.opacity(0.12))
                        AxisValueLabel(centered: true) {
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
                .frame(height: max(62, CGFloat(Set(spans.map(\.lane)).count) * 30 + 18))
                .clipped()
                .accessibilityLabel("Activity timeline")
                .accessibilityValue(spans.map {
                    "\($0.label), \(Self.timeRange(start: $0.start, end: $0.end))"
                }.joined(separator: "; "))
            }
        }
        .padding(8)
        .atriaCard(emphasis: .soft)
        .atriaInspectableGraph(spans.isEmpty ? nil : AtriaInspectableGraph(
            title: "Activity timeline",
            subtitle: window.isCurrentPhysiologicalDay
                ? "Since waking"
                : window.labelDay.formatted(date: .long, time: .omitted),
            content: .intervals(spans.map { span in
                .init(id: span.id,
                      lane: span.lane,
                      label: span.label,
                      start: span.start,
                      end: span.end,
                      tint: span.tint)
            }, domain: dayStart...dayEnd),
            preferredVisibleDuration: 4 * 60 * 60
        ))
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
            Button { onEditSleep(night) } label: { sleepRow(night) }
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
                interval: displayWindow.interval,
                calendar: calendar
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
            // Repack every category together for presentation. Separate
            // sleep/workout/review prefixes previously forced non-overlapping
            // events into stacked vertical bands and made an ordinary day
            // consume far more space than its actual overlap required.
            let compactAssignments = AtriaActivityTimelineLanePacker.assignments(for: spans.map {
                AtriaActivityTimelineLaneInterval(id: $0.id, start: $0.start, end: $0.end)
            })
            let compacted = spans.map {
                TimelineSpan(id: $0.id,
                             lane: "timeline-\(compactAssignments[$0.id] ?? 0)",
                             start: $0.start,
                             end: $0.end,
                             tint: $0.tint,
                             label: $0.label,
                             icon: $0.icon)
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

    init(store: SessionStore, workout: UserConfirmedWorkout) {
        self.store = store
        self.workout = workout
        recoveryEffect = AtriaActivityRecoveryEffect.make(workout: workout,
                                                          rollups: store.dailyRollupHistory,
                                                          calendar: .current)
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
        } else if points.count >= 30 {
            VStack(alignment: .leading, spacing: 8) {
                Text("Heart-rate trace")
                    .font(.subheadline.weight(.semibold))
                AtriaHeartRateAxisChart(points: points,
                                        yDomain: AtriaHeartRateChartSeries.yDomain(for: points),
                                        selectedTime: .constant(nil))
                    .frame(height: 150)
                    .clipped()
            }
            .padding(12)
            .atriaInsetCard(tint: .red)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Heart-rate trace, \(points.count) samples during this workout.")
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
                        if let steps = completedWorkoutStepsText {
                            statTile("Steps", steps, tint: .mint)
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
            switch store.editConfirmedWorkout(id: workout.id,
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
        let result = store.editConfirmedWorkout(id: workout.id,
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
                let rollback = store.editConfirmedWorkout(
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
        guard store.deleteConfirmedWorkout(id: workout.id) else {
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
        let resolvedActivity = AtriaWorkoutActivityType.resolved(
            activityType: workout.activityType,
            subtype: workout.activitySubtype,
            label: workout.label
        )
        return AtriaWorkoutSharePresentation.completedStepsText(
            count: workout.workoutSteps,
            isEstimated: workout.workoutStepsAreEstimated,
            capturedAt: workout.workoutStepsCapturedAt,
            workoutEndedAt: workout.end,
            activity: resolvedActivity
        )
    }

    private func statTile(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetCard(tint: tint)
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
    }

    let status: Status

    static func make(workout: UserConfirmedWorkout,
                     rollups: [DailyRollupStoreEntry],
                     calendar: Calendar) -> Self {
        let workoutDay = calendar.startOfDay(for: workout.start)
        guard let recoveryDay = calendar.date(byAdding: .day, value: 1, to: workoutDay) else {
            return Self(status: .learning)
        }
        let observed = rollups.first {
            calendar.isDate($0.day, inSameDayAs: recoveryDay) && $0.recovery != nil
        }?.recovery
        guard let observed else {
            return Self(status: recoveryDay >= calendar.startOfDay(for: Date()) ? .pending : .learning)
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
        case .pending: return "Available next morning"
        case .learning: return "Learning your response"
        }
    }

    var detail: String {
        switch status {
        case let .observed(_, _, baseline, samples):
            return "Next-morning recovery versus your preceding \(samples)-day average of \(baseline)%. This is a personal association, not proof the activity caused the change."
        case .pending:
            return "Atria freezes morning recovery once daily, then attaches it to the prior day's activity."
        case .learning:
            return "At least three prior recovery days are needed for a useful personal comparison."
        }
    }

    var tint: Color {
        switch status {
        case let .observed(delta, _, _, _): return delta >= 0 ? .green : .orange
        case .pending: return .blue
        case .learning: return .secondary
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
