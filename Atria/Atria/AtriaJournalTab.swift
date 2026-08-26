import Combine
import SwiftUI

struct AtriaJournalProjectionState: Equatable {
    let behaviorJournalRevision: Int
    let journalAnswersRevision: Int
    let typedInsights: [JournalInsight]
    let dailyRollupHistoryRevision: Int
    /// Keys the Behavior Impact / Impact map memo (design slice 3): those cards
    /// read `dailyMetricHistory` for real recovery + vitals per night, which the
    /// journal revision alone does not cover.
    let dailyMetricHistoryRevision: Int
    let localDay: Date
}

struct AtriaJournalDeckSizing: Equatable {
    // The check-in remains the focal action, but it cannot monopolize a phone
    // viewport or clip its own content.  A 360pt floor keeps the prompt and
    // actions comfortably tappable, while the card is free to grow for longer
    // localized questions, larger text, or future follow-up controls.
    static let standardHeight: CGFloat = 360

    let minimumHeight: CGFloat

    init(dynamicTypeSize: DynamicTypeSize) {
        minimumHeight = Self.standardHeight
    }
}

/// Single source of truth for which behaviors a user has chosen to track. The
/// catalog (`BehaviorJournalEntry.Tag`) is WHOOP-scale, but the daily check-in
/// and the impact section only ever show this opted-in subset — an empty/unset
/// preference falls back to the original proven default set, so nothing changes
/// for anyone who never opens the picker. Stored as a CSV of raw values under
/// one shared key so the deck, Settings picker, and onboarding stay in sync via
/// UserDefaults change notifications (see AtriaDefault).
enum AtriaTrackedBehaviors {
    static let storageKey = "atria.journal.trackedBehaviors"

    static func parse(_ raw: String) -> [BehaviorJournalEntry.Tag] {
        let stored = Set(raw.split(separator: ",").map(String.init))
        // Preserve canonical catalog order regardless of stored order.
        let picked = BehaviorJournalEntry.Tag.allCases.filter { stored.contains($0.rawValue) }
        return picked.isEmpty ? BehaviorJournalEntry.Tag.defaultTracked : picked
    }

    static func serialize(_ tags: [BehaviorJournalEntry.Tag]) -> String {
        tags.map(\.rawValue).joined(separator: ",")
    }
}

/// Day-scoped progress shared by Journal's deck and Today's Daily Brief.
/// Boolean `No` answers live only in the typed answer store, so counting tags
/// alone would incorrectly call a partially completed check-in "not started."
struct AtriaJournalCheckInProgress: Equatable {
    static let scaleQuestions: [AtriaJournalTypedQuestion] = [
        .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale
    ]

    let answeredCount: Int
    let totalCount: Int

    var isComplete: Bool { totalCount > 0 && answeredCount >= totalCount }
    var isStarted: Bool { answeredCount > 0 }

    var actionLabel: String {
        if isComplete { return "Review check-in" }
        // The count lives on statusLabel, which the Today card renders on the
        // very next line — printing it here too made the button read
        // "Resume check-in · 3 of 15" above a bare "3 of 15", and VoiceOver
        // speak the pair as one sentence.
        if isStarted { return "Resume check-in" }
        return "Start check-in"
    }

    var statusLabel: String {
        if isComplete { return "Done" }
        if isStarted { return "\(answeredCount) of \(totalCount)" }
        return "Not started"
    }

    static func booleanQuestionID(for tag: BehaviorJournalEntry.Tag) -> String {
        "tag.\(tag.rawValue)"
    }

    static func resolve(trackedTags: [BehaviorJournalEntry.Tag],
                        todayEntry: BehaviorJournalEntry?,
                        answersByQuestion: [String: AtriaJournalAnswer]) -> Self {
        let answeredTags = trackedTags.reduce(into: 0) { count, tag in
            if todayEntry?.tags.contains(tag) == true
                || answersByQuestion[booleanQuestionID(for: tag)] != nil {
                count += 1
            }
        }
        let answeredScales = scaleQuestions.reduce(into: 0) { count, question in
            if answersByQuestion[question.rawValue] != nil { count += 1 }
        }
        return Self(answeredCount: answeredTags + answeredScales,
                    totalCount: trackedTags.count + scaleQuestions.count)
    }
}

/// Equality-gated bridge between the retained Journal tab and SessionStore.
/// It may hear a broad dashboard revision, but the Journal root only invalidates
/// when one of its own value-semantic inputs actually changes.
@MainActor
final class AtriaJournalProjectionStore: ObservableObject {
    @Published private(set) var state: AtriaJournalProjectionState

    private var cancellables = Set<AnyCancellable>()

    init(state: AtriaJournalProjectionState) {
        self.state = state
    }

    convenience init(store: SessionStore, now: Date = Date(), calendar: Calendar = .current) {
        self.init(state: Self.makeState(store: store, now: now, calendar: calendar))
        bind(to: store)
    }

    @discardableResult
    func refresh(_ next: AtriaJournalProjectionState) -> Bool {
        guard next != state else { return false }
        state = next
        return true
    }

    private func bind(to store: SessionStore) {
        Publishers.MergeMany([
            store.$dashboardRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$journalAnswersRevision.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$journalInsightsCache.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyRollupHistory.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            store.$dailyMetricHistory.dropFirst().map { _ in () }.eraseToAnyPublisher()
        ])
        // @Published emits before assignment. Coalescing onto the next run-loop
        // turn guarantees revisions and their backing snapshots agree.
        .debounce(for: .milliseconds(1), scheduler: RunLoop.main)
        .sink { [weak self, weak store] in
            guard let self, let store else { return }
            self.refresh(Self.makeState(store: store))
        }
        .store(in: &cancellables)
    }

    private static func makeState(store: SessionStore,
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> AtriaJournalProjectionState {
        AtriaJournalProjectionState(
            behaviorJournalRevision: store.behaviorJournalRevision,
            journalAnswersRevision: store.journalAnswersRevision,
            typedInsights: Array(store.journalInsightsCache.prefix(3)),
            dailyRollupHistoryRevision: store.dailyRollupHistoryRevision,
            dailyMetricHistoryRevision: store.dailyMetricHistoryRevision,
            localDay: calendar.startOfDay(for: now)
        )
    }

    @discardableResult
    func refreshDayIfNeeded(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let localDay = calendar.startOfDay(for: now)
        guard localDay != state.localDay else { return false }
        state = AtriaJournalProjectionState(
            behaviorJournalRevision: state.behaviorJournalRevision,
            journalAnswersRevision: state.journalAnswersRevision,
            typedInsights: state.typedInsights,
            dailyRollupHistoryRevision: state.dailyRollupHistoryRevision,
            dailyMetricHistoryRevision: state.dailyMetricHistoryRevision,
            localDay: localDay
        )
        return true
    }
}

/// Journal tab (phase 1): a sub-30-second morning check-in over the existing
/// behavior tags, a "same as yesterday" shortcut, a 90-day logging heat strip,
/// and the shared behavior-impact section. Strictly additive: reads and writes
/// go through the existing BehaviorJournalEntry store APIs only.
struct AtriaJournalTab: View {
    /// Retained only for actions and snapshot reads. Root observation is narrowed
    /// to `projectionStore`, so live BLE/session publishes cannot redraw the root,
    /// check-in deck, or typed-pattern section.
    let store: SessionStore
    @StateObject private var projectionStore: AtriaJournalProjectionStore
    @State private var behaviorImpactMemo = AtriaBehaviorImpactMemo()

    init(store: SessionStore) {
        self.store = store
        _projectionStore = StateObject(wrappedValue: AtriaJournalProjectionStore(store: store))
    }

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaJournalTab")
        let projection = projectionStore.state
        let localDay = projection.localDay
        // Design slice 3: one gated model feeds BOTH the diverging chart and the
        // impact map, so the two cards can never disagree about a behavior.
        // Memoized on the journal + daily-metric revisions — never recomputed
        // by a live BLE publish.
        let impactModel = behaviorImpactMemo.model(behaviorJournalRevision: projection.behaviorJournalRevision,
                                                   dailyMetricHistoryRevision: projection.dailyMetricHistoryRevision,
                                                   localDay: localDay,
                                                   store: store)
        Group {
            AtriaJournalCheckInDeck(store: store, projection: projection)
            AtriaJournalTypedInsightsSection(insights: projection.typedInsights)
            AtriaBehaviorImpactCard(model: impactModel)
            // The evidence chart and its compact evidence rows already answer
            // what moved recovery and how much data supports it. A second
            // classification map repeated those same results without an action.
            // Heat strip rides directly under the behavior-impact section it
            // visualizes (UX audit 2026-07-07) instead of orphaned mid-stack.
            AtriaJournalHeatStrip(entries: store.behaviorJournalEntries,
                                  revision: projection.behaviorJournalRevision,
                                  localDay: localDay)
                .equatable()
            AtriaRoutineCard(store: store)
            AtriaJournalCycleCard(sessionStore: store)
        }
        .onAppear {
            projectionStore.refreshDayIfNeeded()
        }
    }
}

/// Opt-in menstrual cycle tracking card (v1, docs handoff: bounded, privacy-
/// first). Reads/writes go through `AtriaCycleTrackingStore` only — its own
/// JSON file in Documents, entirely separate from the behavior-journal store
/// above and from the research-bundle allowlist. Default OFF; enabling is an
/// explicit, one-tap opt-in from here, never implied by anything else in the
/// app.
private struct AtriaJournalCycleCard: View {
    /// Recovery history for the phase-patterns rows (design backlog item 10).
    let sessionStore: SessionStore

    // Dotted UserDefaults key: must use @AtriaDefault, not @AppStorage — see
    // AtriaDefault.swift for why plain @AppStorage on a dotted key storms the
    // whole view tree under high-frequency sibling writes.
    @AtriaDefault(AtriaCycleTracking.enabledKey) private var isEnabled: Bool = false
    @StateObject private var store = AtriaCycleTrackingStore()
    @State private var showLogSheet = false
    @State private var phasePatternMemo = AtriaJournalPhasePatternMemo()

    /// Cycle-phase patterns (design backlog item 10): average recovery per
    /// estimated phase over the trailing 90 days. Gated on a PERSONALIZED
    /// estimate (>=2 completed cycles) and >=3 classified days per phase;
    /// always labeled an estimate/association per the honesty rules.
    @ViewBuilder
    private var phasePatternRows: some View {
        let localDay = Calendar.current.startOfDay(for: Date())
        let patterns = phasePatternMemo.patterns(rollupRevision: sessionStore.dailyRollupHistoryRevision,
                                                 localDay: localDay,
                                                 cycleEntriesRevision: store.entriesRevision,
                                                 cycleStore: store,
                                                 rollups: sessionStore.dailyRollupHistory)
        if !patterns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY BY PHASE (ESTIMATE)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.tertiary)
                    .kerning(0.8)
                ForEach(patterns, id: \.phase) { pattern in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(pattern.phase.title)
                                .font(.caption.weight(.semibold))
                            Spacer(minLength: 8)
                            Text("\(pattern.averageRecovery)% avg")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(Metrics.recoveryColor(pattern.averageRecovery))
                            Text("\u{00B7} \(pattern.dayCount)d")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // Proportional recovery bar (design UI pass): a visual of
                        // the same averageRecovery number, colored by the shared
                        // recovery scale. Adds no new claim — the card already
                        // labels this a 90-day association estimate, not a prediction.
                        GeometryReader { geo in
                            let fraction = min(1, max(0, CGFloat(pattern.averageRecovery) / 100))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.06))
                                Capsule()
                                    .fill(Metrics.recoveryColor(pattern.averageRecovery))
                                    .frame(width: max(6, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 6)
                        .accessibilityHidden(true)
                    }
                }
                Text("90-day association from logged dates; not a prediction.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .atriaInsetCard(tint: .pink)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Cycle",
                                    subtitle: isEnabled ? "Phase estimate from your logged dates" : "Optional, off by default")
            if isEnabled {
                enabledContent
                phasePatternRows
            } else {
                disabledContent
            }
        }
        // The swipe card is already the check-in surface. A second enclosing
        // card only reduced its reading width and made the deck feel boxed in.
        .sheet(isPresented: $showLogSheet) {
            AtriaCyclePeriodLogSheet(store: store)
        }
    }

    private var disabledContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                isEnabled = true
            } label: {
                Label("Turn on cycle tracking", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .pink)
            .accessibilityHint("Optional phase estimates stay on this phone and are excluded from research.")
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let estimate = store.currentEstimate() {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: estimate.phase.symbolName)
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.pink)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(estimate.phase.title) \u{00B7} day \(estimate.cycleDay)")
                            .font(.headline)
                        Text(confidenceLabel(estimate.confidence))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(estimate.phase.coachNote)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                Text("Log a first period to begin phase estimates.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.completedCycleCount < 2 {
                Text("Calendar estimate · \(store.completedCycleCount)/2 cycles · not medical advice")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    showLogSheet = true
                } label: {
                    Label("Log period", systemImage: "drop.fill")
                        .font(.caption.weight(.semibold))
                }
                .atriaCardAction(prominent: false, tint: .pink)

                if store.isPeriodOngoing {
                    Button {
                        store.logPeriodEnd()
                    } label: {
                        Label("Ended today", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                    }
                    .atriaCardAction(prominent: false, tint: .secondary)
                }

                Spacer(minLength: 0)

                Button("Turn off") {
                    isEnabled = false
                }
                .font(.caption)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func confidenceLabel(_ confidence: AtriaCycleConfidence) -> String {
        switch confidence {
        case .estimating: return "Estimating \u{2014} calendar average, not yet personalized"
        case .personalized: return "Personalized to your logged cycles"
        }
    }
}

private final class AtriaJournalPhasePatternMemo {
    private var rollupRevision: Int?
    private var localDay: Date?
    private var cycleEntriesRevision: Int?
    private var cachedRows: [(phase: AtriaCyclePhase, averageRecovery: Int, dayCount: Int)] = []

    func patterns(rollupRevision: Int,
                  localDay: Date,
                  cycleEntriesRevision: Int,
                  cycleStore: AtriaCycleTrackingStore,
                  rollups: [DailyRollupStoreEntry],
                  calendar: Calendar = .current) -> [(phase: AtriaCyclePhase, averageRecovery: Int, dayCount: Int)] {
        if self.rollupRevision == rollupRevision,
           self.localDay == localDay,
           self.cycleEntriesRevision == cycleEntriesRevision {
            return cachedRows
        }

        let windowStart = calendar.date(byAdding: .day, value: -90, to: localDay) ?? localDay
        let trailingDays = rollups
            .prefix { $0.day >= windowStart }
            .map { (day: $0.day, recovery: $0.recovery) }
        let rows = cycleStore.recoveryPatternsByPhase(days: trailingDays,
                                                       now: localDay,
                                                       calendar: calendar)
        self.rollupRevision = rollupRevision
        self.localDay = localDay
        self.cycleEntriesRevision = cycleEntriesRevision
        cachedRows = rows
        return rows
    }
}

/// Log-a-period sheet: start date (required) and an optional end date for a
/// period that has already finished. Both dates are clamped to "not in the
/// future" so this can never fabricate a date that hasn't happened.
private struct AtriaCyclePeriodLogSheet: View {
    @ObservedObject var store: AtriaCycleTrackingStore
    @Environment(\.dismiss) private var dismiss
    @State private var startDate = Date()
    @State private var hasEndDate = false
    @State private var endDate = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Period start") {
                    DatePicker("Start date", selection: $startDate, in: ...Date(), displayedComponents: .date)
                }
                Section("Period end") {
                    Toggle("Already ended", isOn: $hasEndDate.animation())
                    if hasEndDate {
                        DatePicker("End date", selection: $endDate, in: startDate...Date(), displayedComponents: .date)
                    }
                }
                Section {
                    Text("Stays on this phone. Not included in research bundles.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Log period")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.logPeriodStart(startDate)
                        if hasEndDate { store.logPeriodEnd(max(endDate, startDate)) }
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: endDate) { _, newValue in
            if newValue < startDate { endDate = startDate }
        }
        .presentationDetents([.medium])
    }
}

/// Insight-engine v2 results (threshold splits, dose-response). Reads the
/// precomputed cache only — never computes in body.
private struct AtriaJournalTypedInsightsSection: View {
    let insights: [JournalInsight]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Patterns",
                                    subtitle: "From your journal entries")

            if insights.isEmpty {
                // Was a padlock captioned "Patterns are locked". Nothing is
                // locked: there is no gate and nobody holds a key, the app
                // simply has too few check-ins to claim a pattern. A padlock
                // is the universal mark of pay-to-unlock, which is the one
                // inference this app can least afford — its whole pitch is
                // WHOOP insights without the subscription. It also broke the
                // standing decision that "Learning" is the canonical
                // not-ready word, used for exactly this state on Today, on
                // Vitals and in the detail sheets. The dashed card stays; it
                // reads as "not yet" without implying a paywall.
                HStack(spacing: 10) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Patterns are learning")
                            .font(.subheadline.weight(.bold))
                        Text("About 2–3 weeks of answers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .padding(12)
                .overlay {
                    RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous)
                        .stroke(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
            } else {
                // Direction-coded rows (design handoff): green up-arrow for a
                // helpful pattern, orange down-arrow for a harmful one --
                // derived from the insight's real signed effect.
                ForEach(insights) { insight in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: insight.signedEffect < 0 ? "arrow.down" : "arrow.up")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(insight.signedEffect < 0 ? .orange : Metrics.electricGreen)
                        Text(insight.valueText)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        // The dashed learning state already establishes its own boundary. A
        // second full-width card made this section feel like a box inside a
        // box and narrowed the only useful content.
        .padding(.vertical, 4)
    }
}

/// One question per card, swipe or auto-advance; answering never blocks the user.
/// Skip = simply not answering — an unanswered tag stays absent, matching the
/// existing journal semantics (empty entries are dropped on save).
private struct AtriaJournalCheckInDeck: View {
    /// Unobserved action dependency. `projection` carries the only values that
    /// can cause this retained subtree to refresh.
    let store: SessionStore
    let projection: AtriaJournalProjectionState
    @State private var deckIndex: Int = 0
    // Follow-up values are held locally and committed on "Set" — recording on
    // every wheel/stepper tick would fire a full insights recompute per tick.
    @State private var pendingCaffeineMinutes: Int = 15 * 60
    @State private var pendingDrinks: Int = 1
    /// Detail questions deliberately live in a sheet rather than inside the
    /// swipe card. A confirmed Yes should feel finished; collecting a time or
    /// amount needs a calm, large-target interaction that cannot fight the
    /// deck's drag gesture.
    @State private var followUpQuestion: AtriaJournalTypedQuestion?
    // Tinder-style swipe deck: live drag offset for the top card, plus a
    // dedicated haptic tick that fires on every committed swipe (yes or no),
    // independent of the existing deckIndex-driven selection tick.
    @State private var dragOffset: CGSize = .zero
    @State private var swipeHapticTick: Int = 0
    @State private var entryMemo = AtriaJournalEntryMemo()
    @State private var answerMemo = AtriaJournalTodayAnswerMemo()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum SwipeDirection {
        case yes
        case no
    }

    private var deckSizing: AtriaJournalDeckSizing {
        AtriaJournalDeckSizing(dynamicTypeSize: dynamicTypeSize)
    }

    private var todayEntry: BehaviorJournalEntry {
        journalEntrySnapshot.today
    }

    private var yesterdayEntry: BehaviorJournalEntry? {
        journalEntrySnapshot.yesterday
    }

    private var journalEntrySnapshot: AtriaJournalEntrySnapshot {
        entryMemo.snapshot(revision: projection.behaviorJournalRevision,
                           store: store)
    }

    @AtriaDefault(AtriaTrackedBehaviors.storageKey) private var trackedBehaviorsRaw: String = ""
    private var tags: [BehaviorJournalEntry.Tag] { AtriaTrackedBehaviors.parse(trackedBehaviorsRaw) }
    /// Standalone typed cards appended after the boolean tags.
    private var scaleQuestions: [AtriaJournalTypedQuestion] {
        AtriaJournalCheckInProgress.scaleQuestions
    }
    private var cardCount: Int { tags.count + scaleQuestions.count }
    private var answeredCount: Int { answeredTagCount + answeredScaleCount }
    private var deckProgressFraction: Double {
        guard cardCount > 0 else { return 0 }
        return min(max(Double(answeredCount) / Double(cardCount), 0), 1)
    }
    private var todayAnswersByQuestion: [String: AtriaJournalAnswer] {
        answerMemo.answers(revision: projection.journalAnswersRevision,
                           store: store.journalAnswers)
    }
    private var answeredScaleCount: Int {
        let answers = todayAnswersByQuestion
        return scaleQuestions.filter { answers[$0.rawValue] != nil }.count
    }
    private var deckComplete: Bool { deckIndex >= cardCount }
    private var allQuestionsAnswered: Bool {
        cardCount > 0 && answeredCount >= cardCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning check-in",
                                        subtitle: deckComplete
                                            ? (allQuestionsAnswered
                                               ? "Done for today"
                                               : "Skipped questions remain")
                                            : "\(answeredCount) of \(cardCount) logged")

                Spacer(minLength: 0)

                if let yesterdayEntry, todayEntry.tags.isEmpty, !deckComplete {
                    Button {
                        applySameAsYesterday(yesterdayEntry)
                    } label: {
                        Label("Same as yesterday", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                    }
                    .atriaCardAction(prominent: false, tint: .secondary)
                }
            }

            if deckComplete {
                completedCard
            } else {
                swipeDeck

                // One rail instead of one dot per card. The dot row did not
                // scale: at the 15 cards shown by default it was already a
                // ~190pt run of 7pt circles that reads as texture rather than
                // progress, and the tracked-behavior list can be expanded to
                // 39, which overflows the row outright. A rail states the same
                // thing at any deck size and matches the exact "N of M logged"
                // count in the header directly above it.
                ProgressView(value: deckProgressFraction)
                    .progressViewStyle(.linear)
                    .tint(.cyan)
                    .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard),
                               value: deckProgressFraction)
                    .accessibilityHidden(true)
            }
        }
        // `swipeDeck` is the one task surface. An additional enclosing card
        // made the check-in look like a modal trapped inside another modal and
        // pushed the answer controls below the fold on a phone. Let the deck
        // use the section's full width instead.
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: deckIndex)
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeHapticTick)
        .sheet(item: $followUpQuestion) { question in
            AtriaJournalFollowUpSheet(
                question: question,
                caffeineMinutes: $pendingCaffeineMinutes,
                drinks: $pendingDrinks,
                existingAnswer: todayAnswersByQuestion[question.rawValue],
                onSave: { value in
                    store.recordJournalAnswer(questionID: question.rawValue, value: value)
                    followUpQuestion = nil
                    advance()
                },
                onSkip: {
                    followUpQuestion = nil
                    advance()
                }
            )
        }
        .onAppear {
            // Completion is persisted state, not transient UI state: resume at
            // the first unanswered card (or the done card) after any view reset.
            deckIndex = firstUnansweredIndex
#if DEBUG
            // Screenshot hook (2026-07-30): hold a card mid-swipe so the
            // horizontal-containment mask is verifiable headlessly (no input
            // injection in this env). The card slides right + rotates but must
            // stay clipped inside the deck column — never reaching the gutter.
            if ProcessInfo.processInfo.arguments.contains("--atria-ui-journal-drag-preview"),
               deckIndex < tags.count {
                dragOffset = CGSize(width: 210, height: 0)
            }
#endif
        }
    }

    private var firstUnansweredIndex: Int {
        for (index, tag) in tags.enumerated() where !tagAnswered(tag) {
            return index
        }
        for (index, question) in scaleQuestions.enumerated()
        where todayAnswersByQuestion[question.rawValue] == nil {
            return tags.count + index
        }
        return cardCount
    }

    static func booleanQuestionID(for tag: BehaviorJournalEntry.Tag) -> String {
        AtriaJournalCheckInProgress.booleanQuestionID(for: tag)
    }

    private func tagAnswered(_ tag: BehaviorJournalEntry.Tag) -> Bool {
        todayEntry.tags.contains(tag)
            || todayAnswersByQuestion[Self.booleanQuestionID(for: tag)] != nil
    }

    private var answeredTagCount: Int {
        tags.filter { tagAnswered($0) }.count
    }

    // MARK: - Swipe deck

    /// Only the boolean tag cards (indices 0..<tags.count) are swipeable.
    /// Typed follow-up cards (time/amount) and the mood/stress scale cards
    /// keep their existing tap-only controls.
    private var isCurrentCardSwipeable: Bool {
        deckIndex < tags.count
    }

    @ViewBuilder
    private func card(at index: Int) -> some View {
        sizedCard(
            Group {
                if index < tags.count {
                    questionCard(for: tags[index])
                } else if index < cardCount {
                    scaleCard(for: scaleQuestions[index - tags.count])
                } else {
                    completedCard
                }
            }
        )
        // Each card needs its own opaque surface — the deck stacks the next
        // card behind the current one in a ZStack, and without a background
        // here the "peeking" card would show straight through the front card.
        .atriaInsetCard(cornerRadius: 20, tint: .cyan)
    }

    @ViewBuilder
    private func sizedCard<Content: View>(_ content: Content) -> some View {
        // Never use a fixed maximum height here. A fixed, clipped deck was
        // hiding controls and text for real users once content or Dynamic Type
        // exceeded its assumptions. The stack stays stable at its floor and
        // grows inside the enclosing Journal scroll view when it needs to.
        content
            .frame(maxWidth: .infinity, minHeight: deckSizing.minimumHeight)
    }

    private var swipeDeck: some View {
        ZStack {
            if deckIndex < cardCount {
                Group {
                    if isCurrentCardSwipeable {
                        card(at: deckIndex).gesture(swipeGesture)
                    } else {
                        card(at: deckIndex)
                    }
                }
                .offset(dragOffset)
                .rotationEffect(.degrees(reduceMotion ? 0 : min(max(Double(dragOffset.width / 18), -14), 14)))
            }
        }
        .frame(minHeight: deckSizing.minimumHeight)
        // Contain the Tinder drag/fly-off HORIZONTALLY (user 2026-07-30 & again on
        // 2026-08-03: journal cards "leaking right and left" to the screen margins
        // mid-swipe). The earlier `.mask(Rectangle().padding(.vertical, -300))` did
        // not clip the offset/rotated card in practice. Instead over-pad
        // vertically, `.clipped()` (which reliably clips at the view's own bounds =
        // the deck column horizontally), then remove the pad's layout effect. A
        // dragged/flying card is now clipped at the deck edges and can never reach
        // the gutter, while the rotation overhang + peek sliver still show through
        // the vertical breathing room.
        .padding(.vertical, 44)
        .clipped()
        .padding(.vertical, -44)
        // Direction badges sit OUTSIDE the mask, pinned to the deck's fixed top
        // corners, so they read clearly and never ride off-column with the card.
        .overlay(alignment: .topTrailing) {
            if isCurrentCardSwipeable, dragOffset.width > 24 {
                swipeBadge(text: "YES", tint: .cyan)
            }
        }
        .overlay(alignment: .topLeading) {
            if isCurrentCardSwipeable, dragOffset.width < -24 {
                swipeBadge(text: "NO", tint: .red)
            }
        }
    }

    private func swipeBadge(text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.heavy))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.5), lineWidth: 1))
            .padding(14)
            .accessibilityHidden(true)
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 15)
            .onChanged { value in
                // A question card also has buttons. Do not let the tiny
                // vertical drift of a normal tap move the entire card; that
                // was the source of the visible shake while answering.
                let x = value.translation.width
                let y = value.translation.height
                guard abs(x) > max(12, abs(y) * 1.25) else { return }
                dragOffset = CGSize(width: resistedSwipeDistance(x), height: 0)
            }
            .onEnded { value in
                let x = value.predictedEndTranslation.width
                let y = value.predictedEndTranslation.height
                guard abs(x) > abs(y) * 1.25 else {
                    snapBack()
                    return
                }
                let threshold: CGFloat = 110
                if x > threshold {
                    commitSwipe(.yes)
                } else if x < -threshold {
                    commitSwipe(.no)
                } else {
                    snapBack()
                }
            }
    }

    private func resistedSwipeDistance(_ translation: CGFloat) -> CGFloat {
        // The card fills the deck column, so any large drag pushes its leading
        // edge past the column/screen margin (which read as "leaking / clipping
        // left and right"). Cap the finger-follow to a small tilt-and-nudge so the
        // card never reaches an edge during a drag; the decisive fly-off on commit
        // still travels fully off-screen.
        let limit: CGFloat = 30
        let magnitude = abs(translation)
        let resisted = limit * (1 - exp(-magnitude / limit))
        return translation < 0 ? -resisted : resisted
    }

    private func commitSwipe(_ direction: SwipeDirection) {
        guard deckIndex < tags.count else { return }
        let tag = tags[deckIndex]
        let followUp = AtriaJournalTypedQuestion.allCases.first { $0.linkedTag == tag }
        swipeHapticTick += 1
        switch direction {
        case .yes:
            recordYes(tag: tag)
            // Mirrors the Yes button: only advance immediately when there is no
            // typed follow-up to collect first (caffeine time, drink count).
            if followUp == nil {
                flyOffAndAdvance(direction: .yes)
            } else {
                snapBack()
                presentFollowUp(followUp)
            }
        case .no:
            recordNo(tag: tag, followUp: followUp)
            flyOffAndAdvance(direction: .no)
        }
    }

    private func flyOffAndAdvance(direction: SwipeDirection) {
        guard !reduceMotion else {
            advance()
            dragOffset = .zero
            return
        }
        let flyX: CGFloat = direction == .yes ? 640 : -640
        withAnimation(.easeOut(duration: 0.22)) {
            dragOffset = CGSize(width: flyX, height: -16)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            advance()
            dragOffset = .zero
        }
    }

    private func presentFollowUp(_ question: AtriaJournalTypedQuestion?) {
        guard let question else { return }
        if let existing = todayAnswersByQuestion[question.rawValue]?.value {
            switch question {
            case .caffeineLastTime:
                pendingCaffeineMinutes = existing.timeOfDayMinutes ?? pendingCaffeineMinutes
            case .alcoholDrinks:
                pendingDrinks = existing.quantityValue ?? pendingDrinks
            case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale:
                break
            }
        }
        followUpQuestion = question
    }

    private func snapBack() {
        if reduceMotion {
            dragOffset = .zero
        } else {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                dragOffset = .zero
            }
        }
    }

    /// Exact recording calls the existing Yes button used — reused by both the
    /// button and the swipe-right gesture so behavior stays identical.
    private func recordYes(tag: BehaviorJournalEntry.Tag) {
        if !todayEntry.tags.contains(tag) {
            store.toggleBehaviorTag(tag)
        }
        // Explicit answers are also recorded typed, so "answered No" is
        // distinguishable from "skipped" (skips record nothing).
        store.recordJournalAnswer(questionID: Self.booleanQuestionID(for: tag), value: .yes)
    }

    /// Exact recording calls the existing No button used — reused by both the
    /// button and the swipe-left gesture so behavior stays identical.
    private func recordNo(tag: BehaviorJournalEntry.Tag, followUp: AtriaJournalTypedQuestion?) {
        if todayEntry.tags.contains(tag) {
            store.toggleBehaviorTag(tag)
        }
        if let followUp {
            store.removeJournalAnswer(questionID: followUp.rawValue)
        }
        store.recordJournalAnswer(questionID: Self.booleanQuestionID(for: tag), value: .no)
    }

    private func questionCard(for tag: BehaviorJournalEntry.Tag) -> some View {
        let answeredYes = todayEntry.tags.contains(tag)
        let isAutoTag = todayEntry.healthAutoTags.contains(tag)
        let followUp = AtriaJournalTypedQuestion.allCases.first { $0.linkedTag == tag }
        return VStack(spacing: 16) {
            Spacer(minLength: 8)

            Image(systemName: tag.symbolName)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.cyan)
                .symbolRenderingMode(.hierarchical)

            Text(question(for: tag))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if isAutoTag {
                AtriaStatusChip(text: "from Health", systemImage: "heart.fill", tint: .pink)
            }

            Spacer(minLength: 8)

            HStack(spacing: 12) {
                Button {
                    recordYes(tag: tag)
                    if followUp == nil {
                        advance()
                    } else {
                        presentFollowUp(followUp)
                    }
                } label: {
                    Text("Yes")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                // Equal visual weight with No (2026-08-04): a filled Yes
                // beside a pale No nudged the answer, and journal answers
                // feed behavior-impact associations — biased input corrupts
                // the correlation the feature exists to surface.
                .atriaCardAction(prominent: false,
                                 tint: answeredYes ? .cyan : .accentColor)

                Button {
                    recordNo(tag: tag, followUp: followUp)
                    advance()
                } label: {
                    Text("No")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 30)
                }
                .atriaCardAction(prominent: false, tint: .accentColor)
            }

            if answeredYes, let followUp {
                Button {
                    presentFollowUp(followUp)
                } label: {
                    Label("Add details", systemImage: followUp.symbolName)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 32)
                }
                .atriaCardAction(prominent: false, tint: .cyan)
            }

            Button("Skip") {
                advance()
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity)
    }

    private static let scaleEmoji = ["😖", "😕", "😐", "🙂", "😄"]

    private func scaleCard(for question: AtriaJournalTypedQuestion) -> some View {
        let existing = todayAnswersByQuestion[question.rawValue]?.value.scaleValue
        return VStack(spacing: 14) {
            Image(systemName: question.symbolName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.cyan)

            Text(question.title)
                .font(.headline)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                ForEach(1...5, id: \.self) { level in
                    Button {
                        store.recordJournalAnswer(questionID: question.rawValue,
                                                  value: .scale(level))
                        advance()
                    } label: {
                        Text(Self.scaleEmoji[level - 1])
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .font(.system(size: 30))
                            .opacity(existing == nil || existing == level ? 1 : 0.35)
                            .scaleEffect(existing == level ? 1.15 : 1)
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Skip") {
                advance()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private var completedCard: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                Image(systemName: allQuestionsAnswered
                      ? "checkmark.seal.fill"
                      : "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.cyan)
                Text(allQuestionsAnswered ? "Check-in done" : "Check-in paused")
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(allQuestionsAnswered
                                ? "Check-in done."
                                : "Check-in paused. Skipped questions remain unanswered.")

            if answeredCount > 0 {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy) {
                        deckIndex = allQuestionsAnswered ? 0 : firstUnansweredIndex
                    }
                } label: {
                    Text(allQuestionsAnswered ? "Review answers" : "Answer skipped questions")
                        .font(.caption.weight(.semibold))
                        .frame(minHeight: 44)
                        .padding(.horizontal, 14)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func question(for tag: BehaviorJournalEntry.Tag) -> String {
        switch tag {
        case .sleep: return "Did you get to bed on time last night?"
        case .alcohol: return "Any alcohol yesterday?"
        case .caffeine: return "Caffeine after mid-afternoon yesterday?"
        case .protein: return "Did you hit your protein target yesterday?"
        case .training: return "Did you train yesterday?"
        case .stress: return "Was yesterday unusually stressful?"
        case .hydration: return "Did you stay well hydrated yesterday?"
        case .lateMeal: return "Did you eat within two hours of bed?"
        case .morningLight: return "Did you get outdoor light yesterday morning?"
        case .meditation: return "Did you meditate or do breathwork yesterday?"
        case .nicotine: return "Any nicotine yesterday?"
        case .cannabis: return "Any cannabis yesterday?"
        case .bigMeal: return "A large or heavy meal yesterday?"
        case .addedSugar: return "A lot of added sugar yesterday?"
        case .vegetables: return "Plenty of vegetables yesterday?"
        case .fasted: return "Did you fast for a long stretch yesterday?"
        case .supplements: return "Took your supplements yesterday?"
        case .melatonin: return "Melatonin or a sleep aid last night?"
        case .magnesium: return "Magnesium before bed last night?"
        case .medication: return "Took your medication yesterday?"
        case .sauna: return "Sauna or heat session yesterday?"
        case .coldExposure: return "Cold plunge or cold shower yesterday?"
        case .stretching: return "Did you stretch or do mobility yesterday?"
        case .massage: return "Massage or bodywork yesterday?"
        case .soreness: return "Waking up sore today?"
        case .activeDay: return "Were you active on your feet yesterday?"
        case .nap: return "Did you nap yesterday?"
        case .screenInBed: return "Screens in bed last night?"
        case .readBeforeBed: return "Did you read before bed?"
        case .sharedBed: return "Shared your bed (partner or pet) last night?"
        case .warmRoom: return "Was your room too warm last night?"
        case .consistentBedtime: return "A consistent bedtime last night?"
        case .socialTime: return "Meaningful social time yesterday?"
        case .anxious: return "Feeling anxious yesterday?"
        case .gratitude: return "Practice gratitude or journaling yesterday?"
        case .outdoors: return "Time outdoors in nature yesterday?"
        case .travel: return "Travel or a time-zone change yesterday?"
        case .unwell: return "Feeling unwell or run down today?"
        case .sexualActivity: return "Sexual activity yesterday?"
        case .selfPleasure: return "Self-pleasure yesterday?"
        }
    }

    private func advance() {
        withAnimation(reduceMotion ? nil : .snappy) {
            deckIndex = min(deckIndex + 1, cardCount)
        }
    }

    private func applySameAsYesterday(_ yesterday: BehaviorJournalEntry) {
        let today = todayEntry
        for tag in tags {
            if yesterday.tags.contains(tag), !today.tags.contains(tag) {
                store.toggleBehaviorTag(tag)
            }
            store.recordJournalAnswer(questionID: Self.booleanQuestionID(for: tag),
                                      value: yesterday.tags.contains(tag) ? .yes : .no)
        }
        // Jump to the scale cards — mood/stress are about TODAY and cannot be
        // copied from yesterday.
        withAnimation(reduceMotion ? nil : .snappy) { deckIndex = tags.count }
    }
}

/// One focused follow-up at a time. This is intentionally kept out of the
/// swipe card: wheel pickers and steppers need room, 52pt tap targets, and a
/// stable scroll-free surface.
private struct AtriaJournalFollowUpSheet: View {
    let question: AtriaJournalTypedQuestion
    @Binding var caffeineMinutes: Int
    @Binding var drinks: Int
    let existingAnswer: AtriaJournalAnswer?
    let onSave: (AtriaJournalValue) -> Void
    let onSkip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var caffeineDate: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: caffeineMinutes / 60,
                                              minute: caffeineMinutes % 60,
                                              second: 0,
                                              of: Date()) ?? Date()
            },
            set: { picked in
                let components = Calendar.current.dateComponents([.hour, .minute], from: picked)
                caffeineMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: question.symbolName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 48, height: 48)
                    .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.title)
                        .font(.title3.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(question == .caffeineLastTime
                         ? "This helps relate timing to tonight’s sleep."
                         : "A quick count helps make the journal useful later.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            switch question {
            case .caffeineLastTime:
                DatePicker("Last caffeine", selection: caffeineDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .accessibilityLabel("Last caffeine time")
            case .alcoholDrinks:
                HStack(spacing: 18) {
                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            drinks = max(1, drinks - 1)
                        }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("One fewer drink")

                    Text("\(drinks)")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("\(drinks) drinks")

                    Button {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            drinks = min(20, drinks + 1)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .frame(width: 56, height: 56)
                    .accessibilityLabel("One more drink")
                }
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.34), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale:
                EmptyView()
            }

            Button {
                switch question {
                case .caffeineLastTime:
                    onSave(.timeOfDay(minutes: caffeineMinutes))
                case .alcoholDrinks:
                    onSave(.quantity(drinks))
                case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale:
                    break
                }
            } label: {
                Text("Save detail")
                    .font(.body.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)

            Button("Skip for now", action: onSkip)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .onAppear {
            guard let value = existingAnswer?.value else { return }
            switch question {
            case .caffeineLastTime:
                caffeineMinutes = value.timeOfDayMinutes ?? caffeineMinutes
            case .alcoholDrinks:
                drinks = value.quantityValue ?? drinks
            case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale:
                break
            }
        }
    }
}

private struct AtriaJournalEntrySnapshot {
    let today: BehaviorJournalEntry
    let yesterday: BehaviorJournalEntry?
}

private final class AtriaJournalEntryMemo {
    private var revision: Int?
    private var day: Date?
    private var value: AtriaJournalEntrySnapshot?

    @MainActor
    func snapshot(revision: Int,
                  store: SessionStore,
                  now: Date = Date(),
                  calendar: Calendar = .current) -> AtriaJournalEntrySnapshot {
        let today = calendar.startOfDay(for: now)
        if self.revision == revision,
           day == today,
           let value {
            return value
        }

        let todayEntry = store.behaviorJournalEntry(for: today, calendar: calendar)
        let yesterdayEntry: BehaviorJournalEntry?
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            let entry = store.behaviorJournalEntry(for: yesterday, calendar: calendar)
            yesterdayEntry = entry.tags.isEmpty ? nil : entry
        } else {
            yesterdayEntry = nil
        }
        let snapshot = AtriaJournalEntrySnapshot(today: todayEntry,
                                                 yesterday: yesterdayEntry)
        self.revision = revision
        day = today
        value = snapshot
        return snapshot
    }
}

/// Behavior Impact / Impact map model cache (design slice 3). The gated
/// statistics walk the full 90-day journal + daily-metric history, which must
/// never happen inside a view body — this recomputes only when the journal or
/// the daily metric history actually changes, or the local day rolls over.
private final class AtriaBehaviorImpactMemo {
    private var behaviorJournalRevision: Int?
    private var dailyMetricHistoryRevision: Int?
    private var localDay: Date?
    private var cached = AtriaBehaviorImpactPresentation.Model.empty

    @MainActor
    func model(behaviorJournalRevision: Int,
               dailyMetricHistoryRevision: Int,
               localDay: Date,
               store: SessionStore,
               calendar: Calendar = .current) -> AtriaBehaviorImpactPresentation.Model {
        if self.behaviorJournalRevision == behaviorJournalRevision,
           self.dailyMetricHistoryRevision == dailyMetricHistoryRevision,
           self.localDay == localDay {
            return cached
        }

        let nights = AtriaBehaviorImpactPresentation.nights(from: store.dailyMetricHistory,
                                                            calendar: calendar)
        let model = AtriaBehaviorImpactPresentation.model(nights: nights,
                                                          journalEntries: store.behaviorJournalEntries,
                                                          referenceDate: localDay,
                                                          calendar: calendar)
        self.behaviorJournalRevision = behaviorJournalRevision
        self.dailyMetricHistoryRevision = dailyMetricHistoryRevision
        self.localDay = localDay
        cached = model
        return model
    }
}

private final class AtriaJournalTodayAnswerMemo {
    private var revision: Int?
    private var day: Date?
    private var value: [String: AtriaJournalAnswer] = [:]

    func answers(revision: Int,
                 store: AtriaJournalAnswerStore,
                 now: Date = Date(),
                 calendar: Calendar = .current) -> [String: AtriaJournalAnswer] {
        let today = calendar.startOfDay(for: now)
        if self.revision == revision,
           day == today {
            return value
        }

        let next = store.answersByQuestion(for: today, calendar: calendar)
        self.revision = revision
        day = today
        value = next
        return next
    }
}

/// 90-day logging history: one cell per day, brightness by how much was logged.
// Internal (was private) so the empty-vs-full history modes are render-testable.
struct AtriaJournalHeatStrip: View, Equatable {
    let entries: [BehaviorJournalEntry]
    let revision: Int
    let localDay: Date

    @State private var heatMemo = HeatMemo()

    static func == (lhs: AtriaJournalHeatStrip, rhs: AtriaJournalHeatStrip) -> Bool {
        lhs.revision == rhs.revision
            && lhs.localDay == rhs.localDay
            && lhs.entries.count == rhs.entries.count
            && lhs.entries.first?.day == rhs.entries.first?.day
            && lhs.entries.first?.tags.count == rhs.entries.first?.tags.count
    }

    private static let dayCount = 90
    /// The full 90-day grid only earns its space once there's enough history to
    /// show a pattern; before that it's ~88 empty cells advertising emptiness
    /// (UX audit 2026-07-08). Until ~3 weeks of history, show a 2-week strip.
    private static let compactDayCount = 14
    /// Full grid is a GitHub-style calendar heatmap: one COLUMN per week (7
    /// weekday rows), the last ~3 months across (user request 2026-08-03).
    private static let weeksToShow = 13

    /// The last `weeksToShow` weeks as columns of 7 days each, aligned to the
    /// calendar's week boundary so every column is a clean Mon–Sun (or Sun–Sat)
    /// week and the rightmost column is the current, partially-elapsed week.
    static func weekColumns(endingAt localDay: Date,
                            calendar: Calendar = .current) -> [[Date]] {
        let today = calendar.startOfDay(for: localDay)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let gridStart = calendar.date(byAdding: .weekOfYear,
                                            value: -(weeksToShow - 1),
                                            to: currentWeekStart) else { return [] }
        return (0..<weeksToShow).map { week in
            (0..<7).compactMap { weekday in
                calendar.date(byAdding: .day, value: week * 7 + weekday, to: gridStart)
            }
        }
    }

    private struct HeatKey: Equatable {
        let revision: Int
        let localDay: Date
        let entryCount: Int
        let newestEntryDay: Date?
        let newestEntryTagCount: Int?
    }

    private struct HeatModel {
        let countsByDay: [Date: Int]
        let fullDays: [Date]
        let recentDays: [Date]
        let usesFullGrid: Bool
        let loggedDayCount: Int

        var shownDays: [Date] {
            usesFullGrid ? fullDays : recentDays
        }

        var visibleDayCount: Int {
            usesFullGrid ? AtriaJournalHeatStrip.dayCount : AtriaJournalHeatStrip.compactDayCount
        }
    }

    private final class HeatMemo {
        private var key: HeatKey?
        private var cached: HeatModel?

        func model(entries: [BehaviorJournalEntry],
                   revision: Int,
                   localDay: Date,
                   calendar: Calendar = .current) -> HeatModel {
            let key = HeatKey(revision: revision,
                              localDay: localDay,
                              entryCount: entries.count,
                              newestEntryDay: entries.first?.day,
                              newestEntryTagCount: entries.first?.tags.count)
            if self.key == key, let cached {
                return cached
            }

            var counts: [Date: Int] = [:]
            var earliest: Date?
            for entry in entries {
                let day = calendar.startOfDay(for: entry.day)
                counts[day] = entry.tags.count
                if earliest.map({ day < $0 }) ?? true {
                    earliest = day
                }
            }

            let fullDays = Self.days(endingAt: localDay, count: AtriaJournalHeatStrip.dayCount, calendar: calendar)
            let recentDays = Self.days(endingAt: localDay, count: AtriaJournalHeatStrip.compactDayCount, calendar: calendar)
            let span = earliest.map {
                calendar.dateComponents([.day], from: $0, to: localDay).day ?? 0
            } ?? 0
            let model = HeatModel(countsByDay: counts,
                                  fullDays: fullDays,
                                  recentDays: recentDays,
                                  usesFullGrid: earliest != nil && span >= 21,
                                  loggedDayCount: fullDays.filter { (counts[$0] ?? 0) > 0 }.count)
            self.key = key
            cached = model
            return model
        }

        private static func days(endingAt localDay: Date, count: Int, calendar: Calendar) -> [Date] {
            (0..<count).compactMap {
                calendar.date(byAdding: .day, value: -(count - 1 - $0), to: localDay)
            }
        }
    }

    var body: some View {
        let model = heatMemo.model(entries: entries, revision: revision, localDay: localDay)
        let today = Calendar.current.startOfDay(for: localDay)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Logging history",
                                        subtitle: model.usesFullGrid ? "Last 3 months" : "Last 2 weeks")

                Spacer(minLength: 0)

                AtriaStatusChip(text: "\(model.loggedDayCount)d logged",
                                systemImage: "square.and.pencil",
                                tint: .cyan)
            }

            if model.usesFullGrid {
                // GitHub-style calendar: one column per week (7 weekday rows),
                // ~13 weeks across. Columns share the width equally so the whole
                // grid always fits the card (never overflows the screen margins).
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(Self.weekColumns(endingAt: localDay).enumerated()),
                            id: \.offset) { _, week in
                        VStack(spacing: 3) {
                            ForEach(week, id: \.self) { day in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(cellColor(count: model.countsByDay[day] ?? 0,
                                                    isFuture: day > today))
                                    .aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3),
                                         count: Self.compactDayCount),
                          spacing: 3) {
                    ForEach(model.shownDays, id: \.self) { day in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(cellColor(count: model.countsByDay[day] ?? 0,
                                            isFuture: day > today))
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }

            // Intensity key for the cyan opacity ramp (visual only; the card's
            // accessibilityLabel already states the counts). Reuses the grid's
            // cellColor so the swatches never drift from the cells.
            HStack(spacing: 6) {
                Text("Less")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach([0, 2, 4, 6], id: \.self) { count in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(cellColor(count: count, isFuture: false))
                        .frame(width: 10, height: 10)
                }
                Text("More")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Journal logging history: \(model.loggedDayCount) of the last \(model.usesFullGrid ? Self.weeksToShow * 7 : model.visibleDayCount) days logged.")
        .padding(16)
        .atriaCard(emphasis: .soft)
        .accessibilityHint(model.usesFullGrid
                           ? "Shows the last 3 months, one column per week."
                           : "The full pattern appears as logging history grows.")
    }

    private func cellColor(count: Int, isFuture: Bool) -> Color {
        // A day that has not happened yet is not a "missed" day — keep it faint
        // so the current week's remaining days do not read as skipped.
        if isFuture { return .primary.opacity(0.03) }
        guard count > 0 else { return .primary.opacity(0.08) }
        let fraction = min(Double(count) / 6.0, 1.0)
        return .cyan.opacity(0.25 + 0.65 * fraction)
    }
}
