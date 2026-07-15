import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AtriaOnboardingFlow: View {
    @State private var draft: AthleteProfile
    let ble: AtriaBLEManager
    let onComplete: (AthleteProfile) -> Void
    let onRestoreBackup: ((URL) async -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .whatThisIs
    @State private var focusMetric: OnboardingFocusMetric = .recovery
    @State private var backupImportPresented = false
    @State private var restoreMessage: String?
    @State private var restoreInProgress = false

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
            case .recovery: return "Morning readiness"
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
        case expectations

        var isFirst: Bool { self == .whatThisIs }
        var isLast: Bool { self == .expectations }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome", "what-this-is", "what": self = .whatThisIs
            case "strap", "connect": self = .strap
            case "you", "profile": self = .you
            case "expectations", "expect", "tomorrow": self = .expectations
            default: return nil
            }
        }
    }

    private struct PrimaryActionButton: View {
        @ObservedObject var ble: AtriaBLEManager
        let step: Step
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(title)
                    .font(.headline.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 30)
            }
            .controlSize(.large)
            .atriaCardAction(tint: step == .strap && ble.status != .connected ? .blue : .green)
        }

        private var title: String {
            switch step {
            case .whatThisIs: return "Get started"
            case .strap: return ble.status == .connected ? "Continue" : "Connect"
            case .you: return "Continue"
            case .expectations: return "Start using Atria"
            }
        }
    }

    private struct ConnectedDebugObserver: View {
        @ObservedObject var ble: AtriaBLEManager
        let onConnected: () -> Void
        @State private var didComplete = false

        var body: some View {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .task(id: ble.status) {
#if DEBUG
                    guard ProcessInfo.processInfo.arguments.contains("--atria-ui-onboarding-complete-connected-strap") else { return }
                    guard ble.status == .connected, !didComplete else { return }
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
         debugInitialStep: String? = nil,
         onRestoreBackup: ((URL) async -> Bool)? = nil,
         onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        _step = State(initialValue: Step(debugName: debugInitialStep) ?? .whatThisIs)
        self.ble = ble
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
                    PrimaryActionButton(ble: ble, step: step) {
                        if step == .strap, ble.status != .connected {
                            // “Connect” must be an honest action. Advancing to
                            // profile setup while the status card still said
                            // Searching made first-run setup look successful
                            // even though no sensor source existed.
                            ble.startScan(reason: "onboarding_primary_connect")
                        } else if step.isLast {
                            onComplete(draft)
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

    private func move(to next: Step) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: 0.28)) { step = next }
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
            Picker("Center metric", selection: $focusMetric) {
                ForEach(OnboardingFocusMetric.allCases) { metric in
                    Text(metric.title).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityHint("Selects the metric shown in the center of the ring")
            if onRestoreBackup != nil {
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
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .disabled(restoreInProgress)
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
                setupStepTile(3, title: "Allow Bluetooth", systemImage: "antenna.radiowaves.left.and.right")
            }
            OnboardingConnectionStatusView(ble: ble)
            ConnectedDebugObserver(ble: ble) {
                onComplete(draft)
            }
        }
        .onAppear { ble.startScan(reason: "onboarding_strap") }
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
                numericProfileField("Height", value: heightBinding, suffix: "cm")
                numericProfileField("Weight", value: weightBinding, suffix: "kg")
            }
            .padding(14)
            .atriaCard(emphasis: .soft)
        }
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
            withAnimation(.snappy(duration: 0.22)) { focusMetric = next }
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
