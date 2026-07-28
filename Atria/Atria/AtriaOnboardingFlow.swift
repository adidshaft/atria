import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum AtriaOptionalProfileNumber {
    static func parse(_ entry: String) -> Double {
        let numeric = entry.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard numeric.contains(where: \.isNumber) else { return 0 }

        let separatorOffsets = numeric.indices.filter {
            numeric[$0] == "." || numeric[$0] == ","
        }
        guard let lastSeparator = separatorOffsets.last else {
            return max(0, Double(numeric) ?? 0)
        }

        let trailingDigits = numeric[numeric.index(after: lastSeparator)...].filter(\.isNumber).count
        let lastSeparatorIsDecimal = (1...2).contains(trailingDigits)
        var normalized = ""
        for index in numeric.indices {
            let character = numeric[index]
            if character.isNumber {
                normalized.append(character)
            } else if lastSeparatorIsDecimal && index == lastSeparator {
                normalized.append(".")
            }
        }
        return max(0, Double(normalized) ?? 0)
    }

    static func displayText(for value: Double) -> String {
        guard value.isFinite, value > 0 else { return "" }
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(
            format: "%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            value
        )
        .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

struct AtriaOnboardingFlow: View {
    @State private var draft: AthleteProfile
    let ble: AtriaBLEManager
    @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
    let onComplete: (AthleteProfile) -> Void
    let onRestoreBackup: ((URL) async -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .whatThisIs
    @State private var focusMetric: OnboardingFocusMetric = .recovery
    @State private var backupImportPresented = false
    @State private var restoreMessage: String?
    @State private var restoreInProgress = false
    // Which journal behaviors the user wants to track. Shared key with the deck
    // and the Settings picker (see AtriaTrackedBehaviors); empty falls back to
    // the default set, so skipping this step keeps the proven default check-in.
    @AtriaDefault(AtriaTrackedBehaviors.storageKey) private var trackedBehaviorsRaw: String = ""

    private enum OnboardingFocusMetric: String, CaseIterable, Identifiable {
        case recovery
        case sleep
        case strain

        var id: String { rawValue }

        var title: String {
            switch self {
            case .recovery: return "Recovery"
            case .sleep: return "Sleep"
            case .strain: return "Strain"
            }
        }

        var detail: String {
            switch self {
            // Short enough to fit the three-across legend chip at the ring's
            // 260pt width. "Morning readiness" rendered as "Morning re…" even
            // at minimumScaleFactor(0.6) — a truncation on the very first
            // screen a user sees.
            case .recovery: return "Readiness"
            case .sleep: return "Night review"
            case .strain: return "Day load"
            }
        }

        var icon: String {
            switch self {
            case .recovery: return "heart.text.square.fill"
            case .sleep: return "bed.double.fill"
            case .strain: return "flame.fill"
            }
        }

        var tint: Color {
            switch self {
            case .recovery: return Metrics.electricGreen
            case .sleep: return Metrics.electricSleep
            case .strain: return Metrics.electricStrain
            }
        }

        var centerValue: String {
            switch self {
            case .recovery: return "64%"
            case .sleep: return "7h 42m"
            case .strain: return "13.1"
            }
        }
    }

    private enum Step: Int, CaseIterable {
        case whatThisIs
        case strap
        case you
        case behaviors
        case expectations

        var isFirst: Bool { self == .whatThisIs }
        var isLast: Bool { self == .expectations }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome", "what-this-is", "what": self = .whatThisIs
            case "strap", "connect": self = .strap
            case "you", "profile": self = .you
            case "behaviors", "track", "tracking": self = .behaviors
            case "expectations", "expect", "tomorrow": self = .expectations
            default: return nil
            }
        }
    }

    private struct PrimaryActionButton: View {
        @ObservedObject var ble: AtriaBLEManager
        @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
        let step: Step
        let action: () -> Void

        private var strapIsReady: Bool { historyBootstrap.isCompleteForCurrentStrap }

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 30)
            }
            .controlSize(.large)
            .atriaCardAction(tint: step == .strap && !strapIsReady ? .blue : .green)
            .disabled(step == .strap && historyBootstrap.isWorking)
        }

        private var title: String {
            switch step {
            case .whatThisIs: return "Get started"
            case .strap:
                if strapIsReady { return "Continue" }
                if historyBootstrap.isWorking { return "Preparing your strap…" }
                if historyBootstrap.snapshot.phase == .failed { return "Retry secure import" }
                return ble.status == .connected ? "Waiting for live data…" : "Connect"
            case .you: return "Continue"
            case .behaviors: return "Continue"
            case .expectations:
                return strapIsReady ? "Start using Atria" : "Finish strap setup"
            }
        }
    }

    private struct ConnectedDebugObserver: View {
        @ObservedObject var ble: AtriaBLEManager
        @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
        let onConnected: () -> Void
        @State private var didComplete = false

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task(id: ble.status) {
#if DEBUG
                    guard ProcessInfo.processInfo.arguments.contains("--atria-ui-onboarding-complete-connected-strap") else { return }
                    guard historyBootstrap.isCompleteForCurrentStrap, !didComplete else { return }
                    didComplete = true
                    AtriaDebugLog("ATRIADBG onboarding status=debug_complete_connected_strap action=complete")
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    guard !Task.isCancelled else { return }
                    onConnected()
#endif
                }
        }
    }

    init(profile: AthleteProfile,
         ble: AtriaBLEManager,
         historyBootstrap: AtriaOnboardingHistoryBootstrap,
         debugInitialStep: String? = nil,
         onRestoreBackup: ((URL) async -> Bool)? = nil,
         onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        _step = State(initialValue: Step(debugName: debugInitialStep) ?? .whatThisIs)
        self.ble = ble
        self.historyBootstrap = historyBootstrap
        self.onRestoreBackup = onRestoreBackup
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                TabView(selection: $step) {
                    page { whatThisIsPage }
                        .tag(Step.whatThisIs)
                    page { strapPage }
                        .tag(Step.strap)
                    page { youPage }
                        .tag(Step.you)
                    page { behaviorsPage }
                        .tag(Step.behaviors)
                    page { expectationsPage }
                        .tag(Step.expectations)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !step.isFirst {
                        Button {
                            move(to: Step(rawValue: step.rawValue - 1) ?? .whatThisIs)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .fileImporter(isPresented: $backupImportPresented,
                          allowedContentTypes: backupArchiveTypes,
                          allowsMultipleSelection: false) { result in
                handleBackupImport(result)
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    progressDots
                    PrimaryActionButton(ble: ble,
                                        historyBootstrap: historyBootstrap,
                                        step: step) {
                        if step == .strap, !onboardingStrapIsReady {
                            // “Connect” must be an honest action. A transport
                            // connection can precede bond completion and the
                            // first usable sample, so never advance until this
                            // exact strap has produced fresh heart-rate data.
                            if historyBootstrap.snapshot.phase == .failed {
                                historyBootstrap.retry()
                            } else if ble.status != .connected {
                                ble.startScan(reason: "onboarding_primary_connect")
                            } else {
                                historyBootstrap.startOrResumeIfPossible()
                            }
                        } else if step.isLast {
                            if onboardingStrapIsReady {
                                onComplete(draft)
                            } else {
                                move(to: .strap)
                            }
                        } else {
                            move(to: Step(rawValue: step.rawValue + 1) ?? .expectations)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var onboardingStrapIsReady: Bool { historyBootstrap.isCompleteForCurrentStrap }

    private func move(to next: Step) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.emphatic)) { step = next }
        }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 116)
        }
    }

    private var whatThisIsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your strap. Your data.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint("WHOOP insights without the subscription.")
            onboardingRingCard
            // The ring above is drawn from fixed sample numbers (64%, 7h 42m,
            // 13.1). Nothing on screen said so, so a first-run user could read
            // them as their own readings before ever wearing the strap —
            // exactly the fabrication the honesty rule exists to prevent. The
            // ring is a layout preview; label it as one.
            Text("Sample numbers, so you can see the layout. Yours start after your first night.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Center metric", selection: $focusMetric) {
                ForEach(OnboardingFocusMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Selects the metric shown in the center of the ring")
            if onRestoreBackup != nil {
                // Restoring a backup is the rare path — a returning user, not
                // a new one. It previously sat directly under the picker as a
                // full-width glass button, reading as a co-equal first action.
                // Pushed to the foot of the page behind a quiet lead-in so the
                // common path (Get started) stays unambiguous.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Coming back to Atria?")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button {
                        backupImportPresented = true
                    } label: {
                        HStack(spacing: 8) {
                            if restoreInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(restoreInProgress ? "Restoring…" : "Restore backup from Files",
                                  systemImage: "tray.and.arrow.down")
                                .font(.footnote.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(restoreInProgress)
                    if let restoreMessage {
                        Text(restoreMessage)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var strapPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingHeader("Connect your strap",
                             systemImage: "battery.100percent.bolt",
                             tint: .blue)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                setupStepTile(1, title: "Charge strap", systemImage: "battery.100percent")
                setupStepTile(2, title: "Close WHOOP", systemImage: "xmark.app")
                setupStepTile(3, title: "Tap until blue", systemImage: "hand.tap.fill")
            }
            Text("Take the strap off, wait for its green sensor lights to stop, then tap the top repeatedly until the side light pulses blue. Atria will securely ask iPhone to pair; accept the system prompt, put the strap back on snugly, and keep it nearby. The strap stops its blue light when pairing finishes — Atria does not force the light off.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Pairing instructions")
            OnboardingConnectionStatusView(ble: ble)
            VStack(alignment: .leading, spacing: 8) {
                Label(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.title,
                      systemImage: "externaldrive.badge.icloud")
                    .font(.subheadline.weight(.semibold))
                Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.disclosure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.interruptionDisclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                onboardingHistoryStatus
            }
            .padding(14)
            .atriaCard(emphasis: .soft)
            ConnectedDebugObserver(ble: ble,
                                   historyBootstrap: historyBootstrap) {
                onComplete(draft)
            }
        }
        .onAppear {
            ble.startScan(reason: "onboarding_strap")
            historyBootstrap.startOrResumeIfPossible()
        }
        .onChange(of: ble.status) { _, _ in
            historyBootstrap.startOrResumeIfPossible()
        }
        .onChange(of: ble.heartRate) { _, _ in
            historyBootstrap.startOrResumeIfPossible()
        }
        .onChange(of: ble.onboardingPairingPreflightInFlight) { wasInFlight, isInFlight in
            guard wasInFlight, !isInFlight else { return }
            historyBootstrap.startOrResumeIfPossible()
        }
    }

    @ViewBuilder
    private var onboardingHistoryStatus: some View {
        switch historyBootstrap.snapshot.phase {
        case .waitingForStrap:
            Label(historyBootstrap.snapshot.detail,
                  systemImage: "dot.radiowaves.left.and.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.blue)
        case .importing, .publishing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(historyBootstrap.snapshot.detail)
                    .font(.footnote.weight(.semibold))
            }
            Text("Keep Atria open and the strap nearby. If iPhone asks to pair, tap Pair.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .complete:
            Label(historyBootstrap.snapshot.importedRows > 0
                  ? "Ready · \(historyBootstrap.snapshot.importedRows) records safely added"
                  : "Ready · strap history verified",
                  systemImage: "checkmark.seal.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.green)
        case .failed:
            Label(historyBootstrap.snapshot.detail,
                  systemImage: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var youPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingHeader("You", systemImage: "person.crop.circle.fill", tint: .purple)
            VStack(alignment: .leading, spacing: 12) {
                numericProfileField("Age", value: ageBinding, suffix: "years")
                Picker("Sex", selection: $draft.biologicalSex) {
                    ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .pickerStyle(.segmented)
                optionalNumericProfileField("Height", value: heightBinding, suffix: "cm")
                optionalNumericProfileField("Weight", value: weightBinding, suffix: "kg")

                // Nothing said why any of this is asked, or that most of it can
                // be skipped. Age and sex are the two that do real work here.
                Text("Age and sex shape your heart-rate zones. Height and weight only sharpen calorie estimates — leave them blank if you would rather not.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .atriaCard(emphasis: .soft)
        }
    }

    private var behaviorsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingHeader("What to track", systemImage: "checklist", tint: .cyan)
            Text("Pick the behaviors you want to log each morning. Your check-in shows only these — you can add or remove them anytime in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(behaviorGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title.uppercased())
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(group.tags) { tag in
                            behaviorChip(tag)
                        }
                    }
                }
                .padding(14)
                .atriaCard(emphasis: .soft)
            }
        }
    }

    private var trackedBehaviorSet: Set<BehaviorJournalEntry.Tag> {
        Set(AtriaTrackedBehaviors.parse(trackedBehaviorsRaw))
    }

    private var behaviorGroups: [(title: String, tags: [BehaviorJournalEntry.Tag])] {
        [
            ("Sleep & recovery", [.sleep, .consistentBedtime, .nap, .melatonin, .sharedBed,
                                  .warmRoom, .screenInBed, .readBeforeBed, .sauna, .coldExposure,
                                  .massage, .stretching, .soreness]),
            ("Activity & nutrition", [.training, .activeDay, .protein, .hydration, .vegetables,
                                      .bigMeal, .addedSugar, .lateMeal, .fasted, .caffeine,
                                      .supplements, .medication]),
            ("Substances", [.alcohol, .nicotine, .cannabis]),
            ("Mind & lifestyle", [.stress, .anxious, .meditation, .gratitude, .socialTime,
                                  .morningLight, .outdoors, .travel, .unwell]),
            ("Intimacy", [.sexualActivity, .selfPleasure])
        ]
    }

    private func behaviorChip(_ tag: BehaviorJournalEntry.Tag) -> some View {
        let selected = trackedBehaviorSet.contains(tag)
        return Button {
            toggleTrackedBehavior(tag)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: tag.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selected ? .cyan : .secondary)
                    .frame(width: 18)
                Text(tag.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.caption)
                    .foregroundStyle(selected ? Color.cyan : Color.secondary.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.cyan.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(selected ? Color.cyan.opacity(0.4) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tag.label)
        .accessibilityValue(selected ? "Tracked" : "Not tracked")
    }

    private func toggleTrackedBehavior(_ tag: BehaviorJournalEntry.Tag) {
        var set = trackedBehaviorSet
        if set.contains(tag) { set.remove(tag) } else { set.insert(tag) }
        // Never persist an empty set — parse() treats empty as "use defaults".
        if set.isEmpty { set = [.sleep] }
        let ordered = BehaviorJournalEntry.Tag.allCases.filter { set.contains($0) }
        trackedBehaviorsRaw = AtriaTrackedBehaviors.serialize(ordered)
    }

    // Ring preview only. The focus selector lives in the metric list below
    // (whatThisIsPage) — before this, the same Recovery/Sleep/Strain choice was
    // offered three times (ring taps, these pills, AND the list), which read as
    // repetitive. The ring stays tappable, so nothing is lost.
    private var onboardingRingCard: some View {
        AtriaTriRing(slots: onboardingRingSlots,
                     centerValue: focusMetric.centerValue,
                     centerState: focusMetric.title,
                     accessibilitySummary: "Preview ring focused on \(focusMetric.title). Choose a focus below.",
                     actions: [
                        .sleep: { moveFocus(to: .sleep) },
                        .recovery: { moveFocus(to: .recovery) },
                        .strain: { moveFocus(to: .strain) }
                     ])
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .atriaCard(emphasis: .soft)
    }

    private var onboardingRingSlots: [AtriaTriRingSlotContent] {
        [
            AtriaTriRingSlotContent(slot: .sleep,
                                    metric: onboardingMetric(.sleep, fill: focusMetric == .sleep ? 0.92 : 0.72)),
            AtriaTriRingSlotContent(slot: .recovery,
                                    metric: onboardingMetric(.recovery, fill: focusMetric == .recovery ? 0.78 : 0.58)),
            AtriaTriRingSlotContent(slot: .strain,
                                    metric: onboardingMetric(.strain, fill: focusMetric == .strain ? 0.66 : 0.42))
        ]
    }

    private func onboardingMetric(_ metric: OnboardingFocusMetric, fill: Double) -> AtriaTriRingMetric {
        AtriaTriRingMetric(title: metric.title,
                           value: metric.centerValue,
                           detail: metric.detail,
                           systemImage: metric.icon,
                           tint: metric.tint,
                           fill: fill)
    }

    private var expectationsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingHeader("Wear it tonight", systemImage: "moon.stars.fill", tint: .indigo)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                expectationPill(icon: "moon.fill",
                                title: "Wear",
                                hint: "Wear your strap tonight.",
                                tint: .indigo)
                expectationPill(icon: "sunrise.fill",
                                title: "Sleep",
                                hint: "Review your first sleep tomorrow.",
                                tint: .orange)
                expectationPill(icon: "chart.line.uptrend.xyaxis",
                                title: "Recovery",
                                hint: "Recovery begins after 3–4 nights.",
                                tint: .green)
            }
        }
    }

    private var progressDots: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == step ? 22 : 7, height: 7)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var currentBirthYear: Int {
        Calendar.current.component(.year, from: Date()) - draft.age
    }

    private var ageBinding: Binding<Int> {
        Binding {
            draft.age
        } set: { age in
            draft.age = min(max(age, 13), 100)
        }
    }

    private var heightBinding: Binding<Double> {
        Binding {
            draft.heightCm
        } set: { height in
            draft.heightCm = min(max(height, 0), 230)
        }
    }

    private var weightBinding: Binding<Double> {
        Binding {
            draft.weightKg
        } set: { weight in
            draft.weightKg = min(max(weight, 0), 250)
        }
    }

    private func moveFocus(to next: OnboardingFocusMetric) {
        if reduceMotion {
            focusMetric = next
        } else {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.standard)) { focusMetric = next }
        }
    }

    private func onboardingIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
    }

    private func onboardingHeader(_ title: String,
                                  systemImage: String,
                                  tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            onboardingIcon(systemImage, tint: tint)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var backupArchiveTypes: [UTType] {
        var types: [UTType] = [.json]
        if let gzip = UTType(filenameExtension: "gz") {
            types.append(gzip)
        }
        return types
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let onRestoreBackup, !restoreInProgress else { return }
            restoreInProgress = true
            restoreMessage = nil
            Task { @MainActor in
                // Keep the scope alive through the worker's full archive read,
                // safety-backup write and canonical apply.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    restoreInProgress = false
                }
                if await onRestoreBackup(url) {
                    restoreMessage = "Backup restored."
                } else {
                    restoreMessage = "Restore failed. Choose an Atria .json or .json.gz archive."
                }
            }
        case .failure:
            restoreMessage = "Restore canceled."
        }
    }

    private func numericProfileField(_ title: String, value: Binding<Int>, suffix: String) -> some View {
        profileFieldLayout(title: title, suffix: suffix) {
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 132)
                .frame(minHeight: 44)
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Height and weight are optional, and the model already treats 0 as
    /// "unset" (both bindings clamp to max(0, …)). Bound through
    /// `TextField(_:value:format:)` that sentinel rendered as a reading —
    /// "0 cm", "0 kg" — which is not a height and not a weight, and disagreed
    /// with Settings, where unset profile fields already show as blank rather
    /// than zero. The field is empty when unset, with the unit as its prompt,
    /// so skipping it looks like skipping it.
    private func optionalNumericProfileField(_ title: String,
                                             value: Binding<Double>,
                                             suffix: String) -> some View {
        let text = Binding<String>(
            get: { AtriaOptionalProfileNumber.displayText(for: value.wrappedValue) },
            set: { value.wrappedValue = AtriaOptionalProfileNumber.parse($0) }
        )
        return profileFieldLayout(title: title, suffix: suffix) {
            TextField(title, text: text, prompt: Text("Optional"))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 132)
                .frame(minHeight: 44)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func numericProfileField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        profileFieldLayout(title: title, suffix: suffix) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 88, idealWidth: 96, maxWidth: 132)
                .frame(minHeight: 44)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func profileFieldLayout<Editor: View>(
        title: String,
        suffix: String,
        @ViewBuilder editor: () -> Editor
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                HStack(spacing: 8) {
                    editor()
                    Text(suffix)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                editor()
                Text(suffix)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
    }

    private func setupStepTile(_ number: Int, title: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.blue)
                Spacer(minLength: 4)
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .padding(10)
        .atriaInsetCard(tint: .blue)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number), \(title)")
    }

    private func expectationPill(icon: String,
                                 title: String,
                                 hint: String,
                                 tint: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(tint)
            Text(title)
                .font(.caption.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 58)
        .padding(.horizontal, 6)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityHint(hint)
    }
}
