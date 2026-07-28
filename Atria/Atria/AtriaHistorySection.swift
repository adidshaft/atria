import SwiftUI
import Combine

// MARK: - Value model

/// Per-day join of a stored rollup with that day's confirmed workouts/sleeps.
/// Built once per `AtriaHistoryModel.make` call -- never mutated in place.
struct AtriaHistoryDay: Identifiable, Equatable {
    enum DayState: Equatable {
        case confirmed
        case review
        case sleepOnly
        case none

        /// Precedence: confirmed > review > sleepOnly > none.
        var tint: Color {
            switch self {
            case .confirmed: return .orange
            case .review: return .cyan
            case .sleepOnly: return Metrics.electricSleep
            case .none: return Color.secondary.opacity(0.4)
            }
        }
    }

    let date: Date
    let strain: Double?
    let recovery: Int?
    let rhrInt: Int?
    let hrvMs: Double?
    let sleepSeconds: TimeInterval?
    let sleepPerformance: Int?
    let confirmedWorkoutCount: Int
    let confirmedSleepCount: Int
    let savedDurationSeconds: TimeInterval
    /// Genuine unconfirmed detector candidates whose start falls on this day.
    let reviewPending: Int
    let state: DayState

    var id: Date { date }
}

/// A trailing-14-day median snapshot used by the day-detail sheet's delta rows.
/// Any field is `nil` when the window has fewer than 3 non-nil samples for that
/// metric ("building" -- never a fabricated comparison off too few points).
struct AtriaHistoryMedians: Equatable {
    let recovery: Double?
    let rhr: Double?
    let hrvMs: Double?
    let sleepSeconds: Double?
    let strain: Double?

    static let empty = AtriaHistoryMedians(recovery: nil, rhr: nil, hrvMs: nil, sleepSeconds: nil, strain: nil)

    fileprivate static func median(_ values: [Double]) -> Double? {
        guard values.count >= 3 else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }
}

/// Small immutable projection of the genuine review queue. History only needs
/// a civil day and count; retaining the full candidates here would couple its
/// off-main model preparation to the detector's much heavier value objects.
struct AtriaHistoryReviewCandidateDay: Equatable, Hashable, Sendable {
    let day: Date
    let count: Int

    static func make(candidates: [WorkoutReviewCandidate],
                     calendar: Calendar = .current) -> [Self] {
        Dictionary(grouping: candidates) {
            calendar.startOfDay(for: $0.start)
        }
        .map { Self(day: $0.key, count: $0.value.count) }
        .sorted { $0.day > $1.day }
    }
}

struct AtriaHistoryModel: Equatable {
    let days: [AtriaHistoryDay]
    let sessionsCount: Int
    /// Real count of detection-log activity: ring-buffer size (last 20
    /// events) -- never fabricated, sourced from `DetectionEventLog`.
    let detectedCount: Int
    let baselineReady: Int
    let baselineTarget: Int
    /// Newest-first ring buffer of detection events, read straight from
    /// `DetectionEventLog` -- purely additive, has zero effect on detection
    /// logic itself.
    let detections: [DetectionEvent]

    static let empty = AtriaHistoryModel(days: [], sessionsCount: 0, detectedCount: 0, baselineReady: 0, baselineTarget: 14, detections: [])

    static func make(rollups: [DailyRollupStoreEntry],
                      workouts: [UserConfirmedWorkout],
                      sleeps: [UserConfirmedSleep],
                      reviewCandidateDays: [AtriaHistoryReviewCandidateDay] = [],
                      calendar: Calendar = .current) -> AtriaHistoryModel {
        let rollupsByDay = Dictionary(grouping: rollups) {
            calendar.startOfDay(for: $0.day)
        }.compactMapValues(\.first)
        let workoutsByDay = Dictionary(grouping: workouts) {
            EventCivilTime.day(containing: $0.start,
                               eventTimeZoneIdentifier: $0.eventTimeZoneIdentifier,
                               outputCalendar: calendar)
        }
        // A main sleep belongs to the morning it completed, matching recovery,
        // Sleep History and the physiological wake boundary. Grouping it by
        // bedtime made a successfully saved overnight disappear from today's
        // Activity Center (and appear on yesterday only after a rollup existed).
        let sleepsByDay = Dictionary(grouping: sleeps) {
            EventCivilTime.day(containing: $0.end,
                               eventTimeZoneIdentifier: $0.eventTimeZoneIdentifier,
                               outputCalendar: calendar)
        }
        let reviewPendingByDay = Dictionary(grouping: reviewCandidateDays) {
            calendar.startOfDay(for: $0.day)
        }.mapValues { $0.reduce(0) { $0 + max(0, $1.count) } }
        // Saved activity is authoritative even before the asynchronous metric
        // rollup is minted. Build the list from the union so Save immediately
        // produces an editable Activity day instead of an apparently empty tab.
        let activityDays = Set(rollupsByDay.keys)
            .union(workoutsByDay.keys)
            .union(sleepsByDay.keys)
            .union(reviewPendingByDay.keys)

        let days: [AtriaHistoryDay] = activityDays.sorted(by: >).map { day in
            let rollup = rollupsByDay[day]
            let dayWorkouts = workoutsByDay[day] ?? []
            let daySleeps = sleepsByDay[day] ?? []
            let confirmedWorkoutCount = dayWorkouts.count
            let confirmedSleepCount = daySleeps.count
            let reviewPending = reviewPendingByDay[day] ?? 0

            let state: AtriaHistoryDay.DayState
            if confirmedWorkoutCount > 0 {
                state = .confirmed
            } else if reviewPending > 0 {
                state = .review
            } else if confirmedSleepCount > 0 {
                state = .sleepOnly
            } else {
                state = .none
            }

            let confirmedSleepSeconds = daySleeps.reduce(0) { $0 + $1.duration }
            return AtriaHistoryDay(date: day,
                                    strain: rollup?.strain,
                                    recovery: rollup?.recovery,
                                    rhrInt: rollup?.rhr,
                                    hrvMs: rollup?.lnRMSSD.map(exp),
                                    sleepSeconds: confirmedSleepSeconds > 0
                                        ? confirmedSleepSeconds
                                        : rollup?.sleepSeconds,
                                    sleepPerformance: rollup?.sleepPerformance,
                                    confirmedWorkoutCount: confirmedWorkoutCount,
                                    confirmedSleepCount: confirmedSleepCount,
                                    savedDurationSeconds: dayWorkouts.reduce(0) { $0 + $1.duration },
                                    reviewPending: reviewPending,
                                    state: state)
        }

        let baselineReady = rollups.prefix(14).filter { $0.recovery != nil }.count
        let detections = DetectionEventLog.load()

        return AtriaHistoryModel(days: days,
                                  sessionsCount: workouts.count,
                                  detectedCount: detections.count,
                                  baselineReady: baselineReady,
                                  baselineTarget: 14,
                                  detections: detections)
    }

    /// Trailing 14 calendar days ending on (and including) `day`.
    func medianWindow(around day: AtriaHistoryDay, calendar: Calendar = .current) -> AtriaHistoryMedians {
        guard let start = calendar.date(byAdding: .day, value: -13, to: day.date) else { return .empty }
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: day.date)
        let window = days.filter { $0.date >= startDay && $0.date <= endDay }

        return AtriaHistoryMedians(recovery: AtriaHistoryMedians.median(window.compactMap { $0.recovery.map(Double.init) }),
                                    rhr: AtriaHistoryMedians.median(window.compactMap { $0.rhrInt.map(Double.init) }),
                                    hrvMs: AtriaHistoryMedians.median(window.compactMap { $0.hrvMs }),
                                    sleepSeconds: AtriaHistoryMedians.median(window.compactMap { $0.sleepSeconds }),
                                    strain: AtriaHistoryMedians.median(window.compactMap { $0.strain }))
    }
}

struct AtriaHistoryRevisionKey: Equatable, Hashable, Sendable {
    let rollup: Int
    let workouts: Int
    let sleep: Int
    let detections: Int
    let reviewCandidateDays: [AtriaHistoryReviewCandidateDay]
}

struct AtriaHistoryProjectionInput: @unchecked Sendable {
    let key: AtriaHistoryRevisionKey
    let rollups: [DailyRollupStoreEntry]
    let workouts: [UserConfirmedWorkout]
    let sleeps: [UserConfirmedSleep]
    let reviewCandidateDays: [AtriaHistoryReviewCandidateDay]
}

struct AtriaHistoryProjection: Equatable {
    let key: AtriaHistoryRevisionKey?
    let model: AtriaHistoryModel

    static let empty = AtriaHistoryProjection(key: nil, model: .empty)
}

/// Builds the immutable History value model away from SwiftUI's render path.
/// A requested revision never clears the published projection, so the section
/// keeps rendering its previous complete model until the replacement is ready.
@MainActor
final class AtriaVitalsHistoryProjectionStore: ObservableObject {
    @Published private(set) var projection: AtriaHistoryProjection

    private var requestedKey: AtriaHistoryRevisionKey?

    init(projection: AtriaHistoryProjection = .empty) {
        self.projection = projection
    }

    func refresh(from input: AtriaHistoryProjectionInput) async {
        guard begin(input.key) else { return }

        let preparation = Task.detached(priority: .utility) {
            AtriaHistoryModel.make(rollups: input.rollups,
                                   workouts: input.workouts,
                                   sleeps: input.sleeps,
                                   reviewCandidateDays: input.reviewCandidateDays)
        }
        let model = await withTaskCancellationHandler {
            await preparation.value
        } onCancel: {
            preparation.cancel()
        }

        guard !Task.isCancelled else {
            cancel(input.key)
            return
        }
        _ = accept(model, for: input.key)
    }

    @discardableResult
    func begin(_ key: AtriaHistoryRevisionKey) -> Bool {
        guard key != requestedKey, key != projection.key else { return false }
        requestedKey = key
        return true
    }

    @discardableResult
    func accept(_ model: AtriaHistoryModel, for key: AtriaHistoryRevisionKey) -> Bool {
        guard requestedKey == key else { return false }
        projection = AtriaHistoryProjection(key: key, model: model)
        return true
    }

    func cancel(_ key: AtriaHistoryRevisionKey) {
        guard requestedKey == key, projection.key != key else { return }
        requestedKey = nil
    }
}

// MARK: - Inline section (memoized subtree)

/// The compact, inline History card shown in the Vitals tab: hero stat chips,
/// a 14-day activity-rhythm strip, and the last 14 tappable rollup rows, with
/// a push to the full ≤400-row history list.
///
/// The parent supplies an immutable, off-main projection. Equality follows the
/// published revision (not an in-flight request), keeping the previous subtree
/// unchanged until its replacement is complete.
struct AtriaHistorySection: View, Equatable {
    let model: AtriaHistoryModel
    let revisionKey: AtriaHistoryRevisionKey?

    @State private var selectedDay: AtriaHistoryDay?
    @State private var showAllDetections = false

    /// Store access for the detections inbox's Adjust routing only —
    /// deliberately NOT part of ==, which memoizes on the revisions.
    let store: SessionStore

    static func == (lhs: AtriaHistorySection, rhs: AtriaHistorySection) -> Bool {
        lhs.revisionKey == rhs.revisionKey
    }

    var body: some View {
        VStack(spacing: 16) {
            historyHeroCard
            if !model.detections.isEmpty {
                detectionsCard
            }
            if model.days.isEmpty {
                emptyStateCard
            } else {
                activityRhythmCard
                recentRowsCard
            }
        }
        .sheet(item: $selectedDay) { day in
            AtriaHistoryDayDetailSheet(day: day, medians: model.medianWindow(around: day))
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAllDetections) {
            AtriaDetectionsListSheet(detections: model.detections, store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var historyHeroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The big trailing number duplicated the Sessions chip directly
            // below it (UX audit 2026-07-07) -- the chip keeps the value.
            AtriaPanelSectionHeader(title: "History", subtitle: "Saved sessions, trends, and local activity evidence")
            HStack(spacing: 10) {
                AtriaHistoryStatChip(label: "Sessions", value: "\(model.sessionsCount)", tint: Metrics.electricStrain)
                Button {
                    showAllDetections = true
                } label: {
                    AtriaHistoryStatChip(label: "Detected", value: "\(model.detectedCount)", tint: .cyan)
                }
                .buttonStyle(.plain)
                AtriaHistoryStatChip(label: "Baseline", value: "\(model.baselineReady)/\(model.baselineTarget)", tint: Metrics.electricGreen)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var rhythmWindow: [AtriaHistoryDay] {
        Array(model.days.prefix(14))
    }

    private var activityRhythmCard: some View {
        let confirmedCount = rhythmWindow.filter { $0.state == .confirmed }.count
        let reviewCount = rhythmWindow.filter { $0.state == .review }.count
        let sleepCount = rhythmWindow.filter { $0.state == .sleepOnly }.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(Metrics.electricStrain)
                Text("Activity rhythm")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                Text("14d")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            AtriaActivityRhythmStrip(days: Array(rhythmWindow.reversed()))
            HStack(spacing: 8) {
                if confirmedCount > 0 {
                    AtriaVitalsHintChip(text: "\(confirmedCount) Saved", tint: .orange)
                }
                if reviewCount > 0 {
                    AtriaVitalsHintChip(text: "\(reviewCount) Review", tint: .cyan)
                }
                if sleepCount > 0 {
                    AtriaVitalsHintChip(text: "\(sleepCount) Sleep", tint: Metrics.electricSleep)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    /// Newest-first list of the last few detection events. Purely a read of
    /// `DetectionEventLog` via `model.detections` -- rendering this card has
    /// zero effect on detection logic. Hidden entirely when the log is empty.
    private var detectionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Detections", subtitle: "What the app detected and why")
            VStack(spacing: 8) {
                // 3-row preview (UX audit density): the full log lives one
                // tap away behind "See all".
                ForEach(model.detections.prefix(3)) { event in
                    AtriaDetectionRow(event: event)
                }
            }
            if model.detections.count > 5 {
                Button {
                    showAllDetections = true
                } label: {
                    HStack {
                        Text("See all detections")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var recentRowsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent days")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVStack(spacing: 8) {
                // 7 rows before "See all history" (UX audit density): 14
                // tappable inset rows made the card a second scroll.
                ForEach(model.days.prefix(7)) { day in
                    Button {
                        selectedDay = day
                    } label: {
                        AtriaHistoryDayRow(day: day)
                    }
                    .buttonStyle(.plain)
                }
            }
            if model.days.count > 14 {
                NavigationLink {
                    AtriaHistoryFullScreen(model: model, onSelect: { selectedDay = $0 })
                } label: {
                    HStack {
                        Text("See all history")
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary)
                    .padding(12)
                    .atriaInsetCard(cornerRadius: 16, tint: Color.secondary.opacity(0.08))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var emptyStateCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No saved days yet")
                .font(.subheadline.weight(.semibold))
            Text("Recovery, sleep, and strain appear here after your first overnight and workout.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaHistoryStatChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .atriaInsetCard(cornerRadius: 16, tint: tint)
    }
}

/// 14-column rhythm strip: bar height ∝ strain normalized to the window max,
/// dot below tinted by that day's `DayState`. Bars with no strain draw only
/// the faint track -- never a fabricated height.
struct AtriaActivityRhythmStrip: View {
    let days: [AtriaHistoryDay]

    private static let barHeight: CGFloat = 56
    private static let barWidth: CGFloat = 8

    private var maxStrain: Double {
        days.compactMap { $0.strain }.max() ?? 0
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(days) { day in
                VStack(spacing: 6) {
                    ZStack(alignment: .bottom) {
                        Capsule(style: .continuous)
                            .fill(Color.secondary.opacity(0.14))
                            .frame(width: Self.barWidth, height: Self.barHeight)
                        if let strain = day.strain, maxStrain > 0 {
                            Capsule(style: .continuous)
                                .fill(Metrics.electricStrain)
                                .frame(width: Self.barWidth,
                                       height: max(4, Self.barHeight * CGFloat(strain / maxStrain)))
                        }
                    }
                    Circle()
                        .fill(day.state.tint)
                        .frame(width: 6, height: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Day row (shared by inline + full history list)

struct AtriaHistoryDayRow: View, Equatable {
    let day: AtriaHistoryDay

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: day.confirmedWorkoutCount > 0 ? "figure.mixed.cardio" : "calendar")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(day.state.tint)
                .frame(width: 30, height: 30)
                .background(day.state.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(day.date.formatted(.dateTime.month(.wide).day().year()))
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                chipRow
            }

            Spacer(minLength: 8)

            Text(day.strain.map { "\(AtriaMetricFormat.strain($0)) strain" } ?? "—")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(day.strain != nil ? Metrics.electricStrain : .secondary)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: day.state == .none ? Color.clear : day.state.tint.opacity(0.5))
    }

    /// At most two chips render inline (UX audit 2026-07-07): an active day
    /// used to pack four chips into the row and everything shrank/cropped. An
    /// honest "+N" chip stands in for the overflow; the day sheet has it all.
    private var chipItems: [(text: String, tint: Color)] {
        var items: [(String, Color)] = []
        if day.savedDurationSeconds > 0 {
            items.append(("\(SleepHistorySnapshot.formatDuration(day.savedDurationSeconds)) Saved", .orange))
        }
        if day.confirmedWorkoutCount > 0 {
            items.append(("\(day.confirmedWorkoutCount) Confirmed", .orange))
        }
        if day.confirmedSleepCount > 0 {
            items.append(("\(day.confirmedSleepCount) Sleep", .blue))
        }
        if day.reviewPending > 0 {
            items.append(("\(day.reviewPending) Review", .cyan))
        }
        return items
    }

    @ViewBuilder
    private var chipRow: some View {
        let items = chipItems
        HStack(spacing: 6) {
            ForEach(Array(items.prefix(2).enumerated()), id: \.offset) { _, item in
                AtriaVitalsHintChip(text: item.text, tint: item.tint)
            }
            if items.count > 2 {
                AtriaVitalsHintChip(text: "+\(items.count - 2)", tint: .secondary)
            }
        }
    }
}

// MARK: - Detections (visible detection ring buffer)

/// One row in the Detections card / full-list sheet: an SF Symbol by kind,
/// the honest reason line (never fabricated -- `DetectionReasonCopy` only
/// maps codes the pipeline itself already produced), and a relative
/// timestamp.
struct AtriaDetectionRow: View, Equatable {
    let event: DetectionEvent

    private var systemImage: String {
        switch event.kind {
        case "sleepAutoConfirmed": return "moon.fill"
        case "workoutDetected": return "bolt.fill"
        case "workoutSuppressed": return "bolt.slash"
        case "sleepCandidateSkipped": return "xmark.circle"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch event.kind {
        case "sleepAutoConfirmed": return Metrics.electricSleep
        case "workoutDetected": return .cyan
        case "workoutSuppressed": return .secondary
        case "sleepCandidateSkipped": return .secondary
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(DetectionReasonCopy.text(for: event))
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(event.date.formatted(.relative(presentation: .named)))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: tint.opacity(0.4))
    }
}

/// Full ring-buffer list (up to 20 events), presented from the hero
/// "Detected" chip or the detections card's "See all" row.
struct AtriaDetectionsListSheet: View {
    let detections: [DetectionEvent]
    /// Optional so render tests can exercise the plain log without a store;
    /// the Adjust routing only exists when a store is present.
    var store: SessionStore? = nil
    @State private var adjustmentNight: SleepHistorySnapshot.Night?
    @State private var addWorkoutSeed: DetectionEvent?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    if detections.isEmpty {
                        Text("No detections yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 40)
                    } else {
                        ForEach(detections) { event in
                            // Actionable inbox (design handoff): a sleep
                            // auto-confirm whose night is UNIQUELY locatable
                            // gets an Adjust route; anything ambiguous stays a
                            // plain log row (fail closed — never route to a
                            // guessed night).
                            if let night = uniqueNight(for: event) {
                                VStack(alignment: .leading, spacing: 8) {
                                    AtriaDetectionRow(event: event)
                                    Button {
                                        adjustmentNight = night
                                    } label: {
                                        Label("Adjust this sleep", systemImage: "slider.horizontal.3")
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 32)
                                    }
                                    .atriaCardAction(prominent: false, tint: Metrics.electricSleep)
                                }
                            } else if isSaveableWorkout(event) {
                                // Workout rows became actionable once events
                                // carry their real window (2026-07-07):
                                // detected-but-unsaved windows offer a
                                // pre-filled save; anything without a window
                                // or already saved stays a plain log row.
                                VStack(alignment: .leading, spacing: 8) {
                                    AtriaDetectionRow(event: event)
                                    Button {
                                        addWorkoutSeed = event
                                    } label: {
                                        Label("Save as workout", systemImage: "plus.circle")
                                            .font(.caption.weight(.semibold))
                                            .frame(maxWidth: .infinity, minHeight: 32)
                                    }
                                    .atriaCardAction(prominent: false, tint: Metrics.electricStrain)
                                }
                            } else {
                                AtriaDetectionRow(event: event)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Detections")
            .sheet(item: $addWorkoutSeed) { event in
                if let store,
                   let start = event.windowStart,
                   let end = event.windowEnd {
                    AtriaAddWorkoutSheet(store: store,
                                         initialStart: start,
                                         initialEnd: end,
                                         reviewCandidateID: event.id.uuidString,
                                         settlingCandidateWindow: (start: start, end: end))
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
            }
            .sheet(item: $adjustmentNight) { night in
                if let store {
                    AtriaManualSleepSheet(initialStart: night.start,
                                          initialEnd: night.end,
                                          initialIsNap: night.isNapEvidence,
                                          preservesSensorStages: true,
                                          evidenceNight: night,
                                          evidencePerformancePercent: store.sleepHistorySnapshot.sleepPerformancePercent(for: night,
                                                                                                                         baseNeedHours: SessionStore.configuredSleepBaseNeedHours())) { start, end, isNap in
                        let saved = await store.saveSleepReviewNightForUI(
                            night,
                            start: start,
                            end: end,
                            isNap: isNap,
                            rest: store.baseline.restingInt ?? 60,
                            source: "detections_inbox_adjust"
                        ) != nil
                        if saved { adjustmentNight = nil }
                        return saved
                    }
                }
            }
        }
    }

    /// The night this auto-confirm event refers to, or nil unless the match
    /// is unambiguous: auto-confirms fire shortly after the night ends, so a
    /// night qualifies when the event lands within [end - 1h, end + 12h] —
    /// and exactly ONE night may qualify.
    /// A workout detection is saveable when it carries its real window, the
    /// store is present, and no confirmed workout already overlaps that
    /// window (those were either saved from review or would duplicate).
    private func isSaveableWorkout(_ event: DetectionEvent) -> Bool {
        guard event.kind == "workoutDetected",
              event.reason != "confirmed",
              let start = event.windowStart,
              let end = event.windowEnd,
              end > start,
              let store else { return false }
        return !store.confirmedWorkouts.contains { $0.end > start && $0.start < end }
    }

    private func uniqueNight(for event: DetectionEvent) -> SleepHistorySnapshot.Night? {
        guard let store, event.kind == "sleepAutoConfirmed" else { return nil }
        let snapshot = store.sleepHistorySnapshot
        let allSleepsByID = (snapshot.nights + snapshot.additionalMainNights + snapshot.napNights)
            .reduce(into: [String: SleepHistorySnapshot.Night]()) { result, night in
                result[night.id] = night
            }
        let matches = allSleepsByID.values.filter { night in
            guard let end = night.end else { return false }
            let delta = event.date.timeIntervalSince(end)
            return delta >= -3_600 && delta <= 12 * 3_600
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

// MARK: - Detected activities (unconfirmed review candidates + dismissed undo)

/// Slow-moving snapshot for the history "Detected activities" surface: the
/// qualifying unconfirmed review windows plus the dismissed-window tombstones
/// (for visible, reversible dismissal). Values come straight from
/// SessionStore's fail-closed review cache — nothing here is recomputed or
/// embellished at the view layer.
struct AtriaDetectedActivitiesState: Equatable {
    let candidates: [WorkoutReviewCandidate]
    let dismissedWindows: [AtriaDismissedWorkoutCandidate]

    static let empty = AtriaDetectedActivitiesState(candidates: [], dismissedWindows: [])

    var isEmpty: Bool { candidates.isEmpty && dismissedWindows.isEmpty }
    var candidateDays: [AtriaHistoryReviewCandidateDay] {
        AtriaHistoryReviewCandidateDay.make(candidates: candidates)
    }
}

/// Narrow observation boundary for the Detected activities card. Vitals
/// deliberately never observes SessionStore at its root (see
/// AtriaVitalsSessionProjectionStore); this store subscribes only to
/// `dashboardRevision` — which the review cache bumps on publish and the
/// dismiss/restore actions bump on write — and republishes only when the
/// rendered snapshot actually changed.
@MainActor
final class AtriaDetectedActivitiesProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaDetectedActivitiesState = .empty

    private let store: SessionStore
    /// Same resting-HR source Home uses for its review banner so both
    /// surfaces request the identical review-cache key (a mismatch would make
    /// the two surfaces endlessly invalidate each other's cache).
    private let restingHeartRateFallback: () -> Int
    private var cancellables = Set<AnyCancellable>()
    private var refreshScheduled = false

    init(store: SessionStore, restingHeartRateFallback: @escaping () -> Int) {
        self.store = store
        self.restingHeartRateFallback = restingHeartRateFallback

        // @Published sends during willSet; coalesce one main-runloop turn so
        // the refresh reads committed store values.
        store.$dashboardRevision
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        refresh()
    }

    @discardableResult
    func refresh() -> Bool {
        let rest = store.baseline.restingInt ?? restingHeartRateFallback()
        let next = AtriaDetectedActivitiesState(
            candidates: store.workoutReviewCandidatesForUI(rest: rest,
                                                           maxHR: store.profile.maxHR),
            dismissedWindows: store.dismissedWorkoutCandidatesForUI
        )
        guard next != state else { return false }
        state = next
        return true
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }
}

/// Owns the projection store so AtriaHealthScreen's chart-heavy body never
/// observes candidate publications directly (AtriaHealthMonitorLiveHost idiom).
struct AtriaDetectedActivitiesHost: View {
    @StateObject private var projectionStore: AtriaDetectedActivitiesProjectionStore
    private let store: SessionStore
    private let onCandidateDaysChange: ([AtriaHistoryReviewCandidateDay]) -> Void

    init(store: SessionStore,
         restingHeartRateFallback: @escaping () -> Int,
         onCandidateDaysChange: @escaping ([AtriaHistoryReviewCandidateDay]) -> Void = { _ in }) {
        _projectionStore = StateObject(wrappedValue: AtriaDetectedActivitiesProjectionStore(
            store: store,
            restingHeartRateFallback: restingHeartRateFallback
        ))
        self.store = store
        self.onCandidateDaysChange = onCandidateDaysChange
    }

    var body: some View {
        let state = debugFixtureState ?? projectionStore.state
        AtriaDetectedActivitiesSection(state: state,
                                       store: store)
            .onAppear {
                projectionStore.refresh()
                onCandidateDaysChange(state.candidateDays)
            }
            .onChange(of: state) { _, updated in
                onCandidateDaysChange(updated.candidateDays)
            }
    }

    #if DEBUG
    private var debugFixtureState: AtriaDetectedActivitiesState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "detected-activities" else { return nil }
        let now = Date()
        let morningEnd = now.addingTimeInterval(-9 * 3600)
        let eveningEnd = now.addingTimeInterval(-40 * 60)
        return AtriaDetectedActivitiesState(
            candidates: [
                WorkoutReviewCandidate(id: "debug-detected-evening",
                                       start: eveningEnd.addingTimeInterval(-52 * 60),
                                       end: eveningEnd,
                                       kind: .activityCandidate,
                                       confidence: .medium,
                                       duration: 52 * 60,
                                       avgHR: 132,
                                       peakHR: 161,
                                       streamCoveragePercent: 92,
                                       observedDuration: 48 * 60,
                                       droppedGapSeconds: 4 * 60,
                                       maxSampleGap: 90,
                                       gapCount: 1,
                                       reason: "sustained_elevated_hr"),
                WorkoutReviewCandidate(id: "debug-detected-morning",
                                       start: morningEnd.addingTimeInterval(-38 * 60),
                                       end: morningEnd,
                                       kind: .activityCandidate,
                                       confidence: .low,
                                       duration: 38 * 60,
                                       avgHR: 116,
                                       peakHR: 141,
                                       streamCoveragePercent: 54,
                                       observedDuration: 21 * 60,
                                       droppedGapSeconds: 17 * 60,
                                       maxSampleGap: 6 * 60,
                                       gapCount: 3,
                                       reason: "elevated_seconds_below_required")
            ],
            dismissedWindows: [
                AtriaDismissedWorkoutCandidate(start: now.addingTimeInterval(-20 * 3600),
                                               end: now.addingTimeInterval(-19 * 3600))
            ]
        )
    }
    #else
    private var debugFixtureState: AtriaDetectedActivitiesState? { nil }
    #endif
}

/// Compact "Detected activities" card for the history area. HONEST copy only:
/// an HR-only window is an "Activity candidate", never a found workout; the
/// row shows the real coverage/avg/peak/duration evidence and the pipeline's
/// own reason code when confidence is low. No strain, calories, or steps are
/// synthesized for these windows. Dismissals are visible and reversible via
/// the "Dismissed detections" list below the candidates.
struct AtriaDetectedActivitiesSection: View {
    let state: AtriaDetectedActivitiesState
    /// Store access for actions only (dismiss/restore + review routing); every
    /// rendered value comes from the immutable `state` snapshot.
    var store: SessionStore? = nil

    @State private var showDismissed = false

    var body: some View {
        if !state.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                AtriaPanelSectionHeader(title: "Detected activities",
                                        subtitle: "Heart-rate windows Atria noticed but has not counted. Confirm what happened, or dismiss.")
                if state.candidates.isEmpty {
                    Text("No unconfirmed detections right now")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(state.candidates, id: \.id) { candidate in
                            candidateRow(candidate)
                        }
                    }
                }
                if !state.dismissedWindows.isEmpty {
                    dismissedList
                }
            }
            .padding(16)
            .atriaCard(cornerRadius: 24, emphasis: .soft)
        }
    }

    private func candidateRow(_ candidate: WorkoutReviewCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.cyan)
                    .frame(width: 30, height: 30)
                    .background(Color.cyan.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity candidate")
                        .font(.subheadline.weight(.semibold))
                    Text("\(Self.timeRangeText(start: candidate.start, end: candidate.end)) · \(SleepHistorySnapshot.formatDuration(candidate.duration)) from strap HR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }
                Spacer(minLength: 8)
            }

            Text("Coverage \(candidate.streamCoveragePercent)% · Avg \(candidate.avgHR) · Peak \(candidate.peakHR) bpm")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            if candidate.confidence == .medium {
                Text("Medium confidence: sustained strap-HR evidence; confirm the activity type")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("Low confidence: \(Self.reasonText(candidate.reason))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 10) {
                Button {
                    requestReview(candidate)
                } label: {
                    Text("Confirm type")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .atriaCardAction(prominent: false, tint: .cyan)

                Button {
                    _ = store?.dismissWorkoutCandidate(start: candidate.start,
                                                       end: candidate.end)
                } label: {
                    Text("Dismiss")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: Color.cyan.opacity(0.4))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity candidate, \(Self.timeRangeText(start: candidate.start, end: candidate.end)), \(SleepHistorySnapshot.formatDuration(candidate.duration)) from strap heart rate. Coverage \(candidate.streamCoveragePercent) percent, average \(candidate.avgHR), peak \(candidate.peakHR) beats per minute. Confirm the type before it counts.")
    }

    /// Visible, reversible dismissal (2026-07-17): an accidental dismiss no
    /// longer buries a detection forever. Restoring removes the durable
    /// window tombstone so the deterministic generator may offer it again.
    private var dismissedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showDismissed.toggle()
            } label: {
                HStack {
                    Text("Dismissed detections (\(state.dismissedWindows.count))")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: showDismissed ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            if showDismissed {
                ForEach(Array(state.dismissedWindows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 12) {
                        Image(systemName: "bolt.slash")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.timeRangeText(start: window.start, end: window.end))
                                .font(.caption.weight(.semibold))
                            Text("Dismissed — Atria will not offer this window")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Restore") {
                            _ = store?.restoreDismissedWorkoutCandidate(start: window.start,
                                                                        end: window.end)
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                        .tint(.cyan)
                    }
                    .padding(10)
                    .atriaInsetCard(cornerRadius: 14, tint: Color.secondary.opacity(0.2))
                }
                Text("Restoring lets Atria offer the window for review again. Nothing is saved until you confirm it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func requestReview(_ candidate: WorkoutReviewCandidate) {
        NotificationCenter.default.post(
            name: SessionStore.workoutReviewCandidateReviewRequestedNotification,
            object: nil,
            userInfo: [SessionStore.workoutReviewCandidateUserInfoKey: candidate]
        )
    }

    static func timeRangeText(start: Date, end: Date) -> String {
        let day = start.formatted(.dateTime.month(.abbreviated).day())
        let startTime = start.formatted(date: .omitted, time: .shortened)
        let endTime = end.formatted(date: .omitted, time: .shortened)
        return "\(day) · \(startTime)–\(endTime)"
    }

    /// Presentation-only rewording of the detector's own reason codes. Codes
    /// without a mapping render as-is (never invent a reason the pipeline did
    /// not produce — same rule as DetectionReasonCopy).
    static func reasonText(_ code: String) -> String {
        if let mapped = reasonCopyByCode[code] { return mapped }
        return code.replacingOccurrences(of: "_", with: " ")
    }

    private static let reasonCopyByCode: [String: String] = [
        "sustained_elevated_hr": "sustained elevated heart rate",
        "elevated_seconds_below_required": "not enough time at elevated heart rate",
        "elevated_bout_below_required": "no long enough continuous elevated stretch",
        "duration_below_10m": "under 10 minutes observed",
        "observed_duration_below_10m_stream_gaps": "under 10 minutes observed after stream gaps",
        "detector_not_workout": "heart rate alone did not meet the workout bar"
    ]
}

// MARK: - Full history (pushed, pinned-month list)

/// Owns its own scroll + LazyVStack so all ≤400 rows are never instantiated
/// eagerly -- only visible rows render, with pinned month section headers for
/// scannability. Rows funnel back to the parent's single day-detail sheet via
/// `onSelect` rather than presenting their own.
struct AtriaHistoryFullScreen: View {
    let model: AtriaHistoryModel
    let onSelect: (AtriaHistoryDay) -> Void

    private struct MonthGroup: Identifiable {
        let id: String
        let title: String
        let days: [AtriaHistoryDay]
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private let monthGroups: [MonthGroup]

    init(model: AtriaHistoryModel, onSelect: @escaping (AtriaHistoryDay) -> Void) {
        self.model = model
        self.onSelect = onSelect
        self.monthGroups = Self.makeMonthGroups(days: model.days)
    }

    private static func makeMonthGroups(days: [AtriaHistoryDay]) -> [MonthGroup] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [AtriaHistoryDay]] = [:]
        for day in days {
            let comps = calendar.dateComponents([.year, .month], from: day.date)
            let key = "\(comps.year ?? 0)-\(comps.month ?? 0)"
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = []
            }
            buckets[key]?.append(day)
        }
        return order.compactMap { key in
            guard let days = buckets[key], let first = days.first else { return nil }
            return MonthGroup(id: key, title: Self.monthFormatter.string(from: first.date), days: days)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12, pinnedViews: [.sectionHeaders]) {
                ForEach(monthGroups) { group in
                    Section {
                        ForEach(group.days) { day in
                            Button {
                                onSelect(day)
                            } label: {
                                AtriaHistoryDayRow(day: day)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        monthHeader(group.title)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("History")
    }

    private func monthHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.bold))
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(.bar)
    }
}

// MARK: - Day detail sheet

private enum AtriaHistoryGoodDirection {
    case up
    case down
    case neutral
}

private struct AtriaHistoryDeltaGlyph: View {
    let current: Double?
    let median: Double?
    let goodDirection: AtriaHistoryGoodDirection
    let formatMagnitude: (Double) -> String

    var body: some View {
        if let current, let median {
            let delta = current - median
            let isUp = delta >= 0
            Label {
                Text(formatMagnitude(abs(delta)))
            } icon: {
                Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
            }
            .font(.caption2.weight(.bold).monospacedDigit())
            .foregroundStyle(tint(isUp: isUp))
        } else {
            // Distinguish the two honest empty states: the day itself has no
            // reading vs the median hasn't accumulated 3 samples yet.
            Text(median != nil ? "No reading this day" : "Building median")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func tint(isUp: Bool) -> Color {
        switch goodDirection {
        case .neutral: return .secondary
        case .up: return isUp ? Metrics.electricGreen : Metrics.electricYellow
        case .down: return isUp ? Metrics.electricYellow : Metrics.electricGreen
        }
    }
}

/// Replica of `AtriaWeeklyReportStatRow` (AtriaOverviewSections.swift, private
/// to that file) extended with a trailing delta glyph vs the 14-day median.
private struct AtriaHistoryStatRow: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let delta: AtriaHistoryDeltaGlyph

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(value)
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                delta
            }
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 16, tint: tint)
    }
}

struct AtriaHistoryDayDetailSheet: View {
    let day: AtriaHistoryDay
    let medians: AtriaHistoryMedians

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                AtriaPanelSectionHeader(title: day.date.formatted(.dateTime.weekday(.wide).month().day()),
                                        subtitle: "vs 14-day median")
                VStack(spacing: 10) {
                    recoveryRow
                    rhrRow
                    hrvRow
                    sleepRow
                    strainRow
                }
            }
            .padding(20)
        }
    }

    private var recoveryRow: some View {
        AtriaHistoryStatRow(title: "Recovery",
                            value: day.recovery.map { "\($0)%" } ?? "—",
                            detail: medians.recovery.map { "Median \(Int($0.rounded()))%" } ?? "Building median",
                            systemImage: "heart.fill",
                            tint: day.recovery.map { Metrics.recoveryColor($0) } ?? .secondary,
                            delta: AtriaHistoryDeltaGlyph(current: day.recovery.map(Double.init),
                                                          median: medians.recovery,
                                                          goodDirection: .up,
                                                          formatMagnitude: { "\(Int($0.rounded()))%" }))
    }

    private var rhrRow: some View {
        AtriaHistoryStatRow(title: "Resting HR",
                            value: day.rhrInt.map { "\($0) bpm" } ?? "—",
                            detail: medians.rhr.map { "Median \(Int($0.rounded())) bpm" } ?? "Building median",
                            systemImage: "heart.text.square.fill",
                            tint: .cyan,
                            delta: AtriaHistoryDeltaGlyph(current: day.rhrInt.map(Double.init),
                                                          median: medians.rhr,
                                                          goodDirection: .down,
                                                          formatMagnitude: { "\(Int($0.rounded())) bpm" }))
    }

    private var hrvRow: some View {
        AtriaHistoryStatRow(title: "HRV",
                            value: AtriaMetricFormat.hrv(day.hrvMs),
                            detail: medians.hrvMs.map { "Median \(AtriaMetricFormat.hrv($0))" } ?? "Building median",
                            systemImage: "waveform.path.ecg",
                            tint: Metrics.electricGreen,
                            delta: AtriaHistoryDeltaGlyph(current: day.hrvMs,
                                                          median: medians.hrvMs,
                                                          goodDirection: .up,
                                                          formatMagnitude: { "\(Int($0.rounded())) ms" }))
    }

    private var sleepRow: some View {
        AtriaHistoryStatRow(title: "Sleep",
                            value: SleepHistorySnapshot.formatDuration(day.sleepSeconds ?? 0),
                            detail: medians.sleepSeconds.map { "Median \(SleepHistorySnapshot.formatDuration($0))" } ?? "Building median",
                            systemImage: "moon.fill",
                            tint: Metrics.electricSleep,
                            delta: AtriaHistoryDeltaGlyph(current: day.sleepSeconds,
                                                          median: medians.sleepSeconds,
                                                          goodDirection: .up,
                                                          formatMagnitude: { SleepHistorySnapshot.formatDuration($0) }))
    }

    private var strainRow: some View {
        AtriaHistoryStatRow(title: "Strain",
                            value: AtriaMetricFormat.strain(day.strain),
                            detail: medians.strain.map { "Median \(AtriaMetricFormat.strain($0))" } ?? "Building median",
                            systemImage: "bolt.fill",
                            tint: Metrics.electricStrain,
                            delta: AtriaHistoryDeltaGlyph(current: day.strain,
                                                          median: medians.strain,
                                                          goodDirection: .neutral,
                                                          formatMagnitude: { String(format: "%.1f", $0) }))
    }
}
