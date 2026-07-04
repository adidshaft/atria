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
            AtriaJournalHeatStrip(entries: store.behaviorJournalEntries)
            AtriaOverviewBehaviorJournalSection(store: store)
        }
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
                Text("Keep answering the detail questions (times, amounts, mood). Patterns like \u{201C}caffeine after 2:30 PM\u{201D} appear once enough days exist on both sides — usually 2\u{2013}3 weeks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(insights) { insight in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.cyan)
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
    private var scaleQuestions: [AtriaJournalTypedQuestion] { [.moodScale, .stressScale] }
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
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                }
            }

            if deckComplete {
                completedCard
            } else {
                TabView(selection: $deckIndex) {
                    ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                        questionCard(for: tag)
                            .tag(index)
                    }
                    ForEach(Array(scaleQuestions.enumerated()), id: \.element.id) { index, question in
                        scaleCard(for: question)
                            .tag(tags.count + index)
                    }
                    completedCard
                        .tag(cardCount)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 250)

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
                    if !answeredYes {
                        store.toggleBehaviorTag(tag)
                    }
                    // Explicit answers are also recorded typed, so "answered No"
                    // is distinguishable from "skipped" (skips record nothing).
                    store.recordJournalAnswer(questionID: Self.booleanQuestionID(for: tag), value: .yes)
                    if followUp == nil { advance() }
                } label: {
                    Text("Yes")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(answeredYes ? .cyan : .accentColor)

                Button {
                    if answeredYes {
                        store.toggleBehaviorTag(tag)
                    }
                    if let followUp {
                        store.removeJournalAnswer(questionID: followUp.rawValue)
                    }
                    store.recordJournalAnswer(questionID: Self.booleanQuestionID(for: tag), value: .no)
                    advance()
                } label: {
                    Text("No")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
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
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .onAppear {
                if let existing = store.journalAnswers.answer(questionID: question.rawValue, day: Date())?
                    .value.quantityValue {
                    pendingDrinks = existing
                }
            }
        case .moodScale, .stressScale:
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
private struct AtriaJournalHeatStrip: View, Equatable {
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

    var body: some View {
        let counts = countsByDay
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Logging history",
                                        subtitle: "Last 90 days")

                Spacer(minLength: 0)

                AtriaStatusChip(text: "\(loggedDayCount)d logged",
                                systemImage: "square.and.pencil",
                                tint: .cyan)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 30),
                      spacing: 3) {
                ForEach(days, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(cellColor(count: counts[day] ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Journal logging history: \(loggedDayCount) of the last \(Self.dayCount) days logged.")
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
