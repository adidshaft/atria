import SwiftUI

/// Journal tab (phase 1): a sub-30-second morning check-in over the existing
/// behavior tags, a "same as yesterday" shortcut, a 90-day logging heat strip,
/// and the shared behavior-impact section. Strictly additive: reads and writes
/// go through the existing BehaviorJournalEntry store APIs only.
struct AtriaJournalTab: View {
    @ObservedObject var store: SessionStore

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaJournalTab")
        Group {
            AtriaJournalCheckInDeck(store: store)
            AtriaJournalTypedInsightsSection(store: store)
            AtriaOverviewBehaviorJournalSection(store: store)
            // Heat strip rides directly under the behavior-impact section it
            // visualizes (UX audit 2026-07-07) instead of orphaned mid-stack.
            AtriaJournalHeatStrip(entries: store.behaviorJournalEntries)
            AtriaRoutineCard(store: store)
            AtriaJournalCycleCard(sessionStore: store)
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

    /// Cycle-phase patterns (design backlog item 10): average recovery per
    /// estimated phase over the trailing 90 days. Gated on a PERSONALIZED
    /// estimate (>=2 completed cycles) and >=3 classified days per phase;
    /// always labeled an estimate/association per the honesty rules.
    @ViewBuilder
    private var phasePatternRows: some View {
        let patterns = store.recoveryPatternsByPhase(
            days: sessionStore.dailyRollupHistory.map { (day: $0.day, recovery: $0.recovery) })
        if !patterns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("RECOVERY BY PHASE (ESTIMATE)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.tertiary)
                    .kerning(0.8)
                ForEach(patterns, id: \.phase) { pattern in
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
                }
                Text("Averages across your last 90 days, grouped by estimated phase. An association from your logs, not a prediction.")
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
        .padding(16)
        .atriaCard(emphasis: .soft)
        .sheet(isPresented: $showLogSheet) {
            AtriaCyclePeriodLogSheet(store: store)
        }
    }

    private var disabledContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Log period dates to see a phase-aware note alongside your recovery and strain — menstrual, follicular, ovulatory, luteal.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Optional. Stays on this phone. Not in research bundles.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                isEnabled = true
            } label: {
                Label("Turn on cycle tracking", systemImage: "calendar.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .pink)
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
                Text("No period logged yet. Log your first start date to begin estimating your phase.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.completedCycleCount < 2 {
                Text("Estimating from calendar averages until 2 cycles are logged (\(store.completedCycleCount)/2 so far). Not medical advice.")
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
    @ObservedObject var store: SessionStore

    var body: some View {
        let insights = Array(store.journalInsightsCache.prefix(3))
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Patterns",
                                    subtitle: "From your typed answers")

            if insights.isEmpty {
                // Locked treatment (2026-07-07 design handoff): dashed card,
                // lock tile, explicit title -- same honest copy as before.
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text("Patterns are locked")
                        .font(.subheadline.weight(.bold))
                    Text("Keep answering the detail questions (times, amounts, mood). Patterns like \u{201C}caffeine after 2:30 PM\u{201D} unlock once enough days exist on both sides — usually 2\u{2013}3 weeks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 10)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

/// One question per card, swipe or auto-advance; answering never blocks the user.
/// Skip = simply not answering — an unanswered tag stays absent, matching the
/// existing journal semantics (empty entries are dropped on save).
private struct AtriaJournalCheckInDeck: View {
    @ObservedObject var store: SessionStore
    @State private var deckIndex: Int = 0
    // Follow-up values are held locally and committed on "Set" — recording on
    // every wheel/stepper tick would fire a full insights recompute per tick.
    @State private var pendingCaffeineMinutes: Int = 15 * 60
    @State private var pendingDrinks: Int = 1
    // Tinder-style swipe deck: live drag offset for the top card, plus a
    // dedicated haptic tick that fires on every committed swipe (yes or no),
    // independent of the existing deckIndex-driven selection tick.
    @State private var dragOffset: CGSize = .zero
    @State private var swipeHapticTick: Int = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum SwipeDirection {
        case yes
        case no
    }

    private static let cardHeight: CGFloat = 250

    private var todayEntry: BehaviorJournalEntry {
        store.behaviorJournalEntry(for: Date())
    }

    private var yesterdayEntry: BehaviorJournalEntry? {
        guard let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else { return nil }
        let entry = store.behaviorJournalEntry(for: yesterday)
        return entry.tags.isEmpty ? nil : entry
    }

    private var tags: [BehaviorJournalEntry.Tag] { BehaviorJournalEntry.Tag.allCases }
    /// Standalone typed cards appended after the boolean tags.
    private var scaleQuestions: [AtriaJournalTypedQuestion] { [.moodScale, .stressScale, .energyScale, .focusScale, .windDownScale] }
    private var cardCount: Int { tags.count + scaleQuestions.count }
    private var answeredCount: Int { answeredTagCount + answeredScaleCount }
    private var answeredScaleCount: Int {
        scaleQuestions.filter { store.journalAnswers.answer(questionID: $0.rawValue, day: Date()) != nil }.count
    }
    private var deckComplete: Bool { deckIndex >= cardCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Morning check-in",
                                        subtitle: deckComplete
                                            ? "Done for today"
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

                HStack(spacing: 6) {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        Circle()
                            .fill(dotColor(index: index, tag: tag))
                            .frame(width: 7, height: 7)
                    }
                    ForEach(Array(scaleQuestions.enumerated()), id: \.element.id) { index, question in
                        Circle()
                            .fill(scaleDotColor(index: tags.count + index, question: question))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(maxWidth: .infinity)
                .accessibilityHidden(true)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
        .sensoryFeedback(.selection, trigger: deckIndex)
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeHapticTick)
        .onAppear {
            // Completion is persisted state, not transient UI state: resume at
            // the first unanswered card (or the done card) after any view reset.
            deckIndex = firstUnansweredIndex
        }
    }

    private var firstUnansweredIndex: Int {
        for (index, tag) in tags.enumerated() where !tagAnswered(tag) {
            return index
        }
        for (index, question) in scaleQuestions.enumerated()
        where store.journalAnswers.answer(questionID: question.rawValue, day: Date()) == nil {
            return tags.count + index
        }
        return cardCount
    }

    static func booleanQuestionID(for tag: BehaviorJournalEntry.Tag) -> String {
        "tag.\(tag.rawValue)"
    }

    private func tagAnswered(_ tag: BehaviorJournalEntry.Tag) -> Bool {
        todayEntry.tags.contains(tag)
            || store.journalAnswers.answer(questionID: Self.booleanQuestionID(for: tag), day: Date()) != nil
    }

    private var answeredTagCount: Int {
        tags.filter { tagAnswered($0) }.count
    }

    private func dotColor(index: Int, tag: BehaviorJournalEntry.Tag) -> Color {
        if tagAnswered(tag) { return .cyan }
        if index == deckIndex { return .primary.opacity(0.65) }
        return .primary.opacity(0.18)
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
        Group {
            if index < tags.count {
                questionCard(for: tags[index])
            } else if index < cardCount {
                scaleCard(for: scaleQuestions[index - tags.count])
            } else {
                completedCard
            }
        }
        // Clamp every card to the deck's fixed height (a plain ZStack, unlike
        // TabView, won't do this for us) so the peeking card behind is mostly
        // covered by the front card instead of both showing full content.
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight)
        .clipped()
        // Each card needs its own opaque surface — the deck stacks the next
        // card behind the current one in a ZStack, and without a background
        // here the "peeking" card would show straight through the front card.
        .atriaInsetCard(cornerRadius: 20, tint: .cyan)
    }

    private var swipeDeck: some View {
        ZStack {
            if deckIndex + 1 < cardCount {
                // A plain hint, not the next card's real content: the deck's
                // surfaces are translucent Liquid Glass, so stacking the actual
                // (duplicate) text/buttons behind the front card would show
                // through as illegible ghosting. A flat peeking shape avoids
                // that while still reading as "there's another card back here."
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cyan.opacity(0.10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.cyan.opacity(0.16), lineWidth: 1)
                    }
                    .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight)
                    .scaleEffect(0.94)
                    .offset(y: 14)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

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
        }
        .frame(height: Self.cardHeight)
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
                dragOffset = value.translation
            }
            .onEnded { value in
                let threshold: CGFloat = 110
                if value.translation.width > threshold {
                    commitSwipe(.yes)
                } else if value.translation.width < -threshold {
                    commitSwipe(.no)
                } else {
                    snapBack()
                }
            }
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
        return VStack(spacing: 12) {
            Image(systemName: tag.symbolName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.cyan)

            Text(question(for: tag))
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if isAutoTag {
                AtriaStatusChip(text: "from Health", systemImage: "heart.fill", tint: .pink)
            }

            HStack(spacing: 10) {
                Button {
                    recordYes(tag: tag)
                    if followUp == nil { advance() }
                } label: {
                    Text("Yes")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: answeredYes ? .cyan : .accentColor)

                Button {
                    recordNo(tag: tag, followUp: followUp)
                    advance()
                } label: {
                    Text("No")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }

            if answeredYes, let followUp {
                followUpControl(for: followUp)
            }

            Button("Skip") {
                advance()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    /// Inline typed detail shown once the linked boolean is Yes: caffeine time
    /// dial, alcohol drinks stepper. Setting the detail advances the deck.
    @ViewBuilder
    private func followUpControl(for question: AtriaJournalTypedQuestion) -> some View {
        switch question {
        case .caffeineLastTime:
            HStack(spacing: 8) {
                Label(question.title, systemImage: question.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                DatePicker("",
                           selection: Binding(
                               get: {
                                   Calendar.current.date(bySettingHour: pendingCaffeineMinutes / 60,
                                                         minute: pendingCaffeineMinutes % 60,
                                                         second: 0,
                                                         of: Date()) ?? Date()
                               },
                               set: { picked in
                                   let components = Calendar.current.dateComponents([.hour, .minute], from: picked)
                                   pendingCaffeineMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                               }),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button("Set") {
                    // Commit the DISPLAYED value: tapping Set without touching the
                    // dial must still record an answer.
                    store.recordJournalAnswer(questionID: question.rawValue,
                                              value: .timeOfDay(minutes: pendingCaffeineMinutes))
                    advance()
                }
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .atriaCardAction(prominent: false, tint: .cyan)
            }
            .onAppear {
                if let existing = store.journalAnswers.answer(questionID: question.rawValue, day: Date())?
                    .value.timeOfDayMinutes {
                    pendingCaffeineMinutes = existing
                }
            }
        case .alcoholDrinks:
            HStack(spacing: 8) {
                Label(question.title, systemImage: question.symbolName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Stepper(value: $pendingDrinks, in: 1...20) {
                    Text("\(pendingDrinks)")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .fixedSize()
                Button("Set") {
                    store.recordJournalAnswer(questionID: question.rawValue,
                                              value: .quantity(pendingDrinks))
                    advance()
                }
                .font(.caption.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .atriaCardAction(prominent: false, tint: .cyan)
            }
            .onAppear {
                if let existing = store.journalAnswers.answer(questionID: question.rawValue, day: Date())?
                    .value.quantityValue {
                    pendingDrinks = existing
                }
            }
        case .moodScale, .stressScale, .energyScale, .focusScale, .windDownScale:
            EmptyView()
        }
    }

    private static let scaleEmoji = ["😖", "😕", "😐", "🙂", "😄"]

    private func scaleCard(for question: AtriaJournalTypedQuestion) -> some View {
        let existing = store.journalAnswers.answer(questionID: question.rawValue, day: Date())?.value.scaleValue
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
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity)
    }

    private func scaleDotColor(index: Int, question: AtriaJournalTypedQuestion) -> Color {
        if store.journalAnswers.answer(questionID: question.rawValue, day: Date()) != nil { return .cyan }
        if index == deckIndex { return .primary.opacity(0.65) }
        return .primary.opacity(0.18)
    }

    private var completedCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.cyan)
            Text("Check-in done")
                .font(.headline)
            Text("Answers feed your local behavior impacts below. Skipped questions stay unanswered — a skipped day never counts as a \u{201C}no\u{201D}.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if answeredCount > 0 {
                Button("Review answers") {
                    withAnimation(.snappy) { deckIndex = 0 }
                }
                .font(.caption.weight(.semibold))
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
        }
    }

    private func advance() {
        withAnimation(.snappy) {
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
        withAnimation(.snappy) { deckIndex = tags.count }
    }
}

/// 90-day logging history: one cell per day, brightness by how much was logged.
// Internal (was private) so the empty-vs-full history modes are render-testable.
struct AtriaJournalHeatStrip: View, Equatable {
    let entries: [BehaviorJournalEntry]

    static func == (lhs: AtriaJournalHeatStrip, rhs: AtriaJournalHeatStrip) -> Bool {
        lhs.entries.count == rhs.entries.count
            && lhs.entries.first?.day == rhs.entries.first?.day
            && lhs.entries.first?.tags.count == rhs.entries.first?.tags.count
    }

    private static let dayCount = 90

    private var countsByDay: [Date: Int] {
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for entry in entries {
            counts[calendar.startOfDay(for: entry.day)] = entry.tags.count
        }
        return counts
    }

    private var days: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<Self.dayCount).compactMap {
            calendar.date(byAdding: .day, value: -(Self.dayCount - 1 - $0), to: today)
        }
    }

    private var loggedDayCount: Int {
        let counts = countsByDay
        return days.filter { (counts[$0] ?? 0) > 0 }.count
    }

    /// The full 90-day grid only earns its space once there's enough history to
    /// show a pattern; before that it's ~88 empty cells advertising emptiness
    /// (UX audit 2026-07-08). Until ~3 weeks of history, show a 2-week strip.
    private static let compactDayCount = 14
    private var hasEnoughHistoryForFullGrid: Bool {
        guard let earliest = entries.map({ Calendar.current.startOfDay(for: $0.day) }).min() else { return false }
        let span = Calendar.current.dateComponents([.day], from: earliest,
                                                    to: Calendar.current.startOfDay(for: Date())).day ?? 0
        return span >= 21
    }

    private var recentDays: [Date] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<Self.compactDayCount).compactMap {
            calendar.date(byAdding: .day, value: -(Self.compactDayCount - 1 - $0), to: today)
        }
    }

    var body: some View {
        let counts = countsByDay
        let fullGrid = hasEnoughHistoryForFullGrid
        let shownDays = fullGrid ? days : recentDays
        let columnCount = fullGrid ? 30 : Self.compactDayCount
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Logging history",
                                        subtitle: fullGrid ? "Last 90 days" : "Last 2 weeks")

                Spacer(minLength: 0)

                AtriaStatusChip(text: "\(loggedDayCount)d logged",
                                systemImage: "square.and.pencil",
                                tint: .cyan)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: columnCount),
                      spacing: 3) {
                ForEach(shownDays, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(cellColor(count: counts[day] ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Journal logging history: \(loggedDayCount) of the last \(fullGrid ? Self.dayCount : Self.compactDayCount) days logged.")

            if !fullGrid {
                Text(loggedDayCount == 0
                     ? "Log today to start your pattern — the full 90-day view builds as history grows."
                     : "Your full 90-day pattern unlocks as history builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private func cellColor(count: Int) -> Color {
        guard count > 0 else { return .primary.opacity(0.08) }
        let fraction = min(Double(count) / 6.0, 1.0)
        return .cyan.opacity(0.25 + 0.65 * fraction)
    }
}
