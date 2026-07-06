import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AtriaOnboardingFlow: View {
    @State private var draft: AthleteProfile
    @ObservedObject var ble: AtriaBLEManager
    let onComplete: (AthleteProfile) -> Void
    let onRestoreBackup: ((URL) -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: Step = .whatThisIs
    @State private var focusMetric: OnboardingFocusMetric = .recovery
    @State private var didDebugCompleteFromConnectedStrap = false
    @State private var backupImportPresented = false
    @State private var restoreMessage: String?

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

    init(profile: AthleteProfile,
         ble: AtriaBLEManager,
         debugInitialStep: String? = nil,
         onRestoreBackup: ((URL) -> Bool)? = nil,
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
                VStack(spacing: 14) {
                    progressDots
                    Button {
                        if step.isLast {
                            onComplete(draft)
                        } else {
                            move(to: Step(rawValue: step.rawValue + 1) ?? .expectations)
                        }
                    } label: {
                        Text(primaryTitle)
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 30)
                    }
                    .controlSize(.large)
                    .atriaCardAction(tint: step == .strap && ble.status != .connected ? .blue : .green)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var primaryTitle: String {
        switch step {
        case .whatThisIs: return "Get started"
        case .strap: return ble.status == .connected ? "Continue" : "Connect"
        case .you: return "Continue"
        case .expectations: return "Start using Atria"
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
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 124)
        }
    }

    private var whatThisIsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Your WHOOP strap, no subscription. Data stays on your phone.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            onboardingRingCard
            VStack(alignment: .leading, spacing: 12) {
                Text("SHOW IN THE CENTER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                ForEach(OnboardingFocusMetric.allCases) { metric in
                    let isSelected = metric == focusMetric
                    Button {
                        moveFocus(to: metric)
                    } label: {
                        HStack(spacing: 12) {
                            featureRow(icon: metric.icon,
                                       tint: metric.tint,
                                       title: metric.title,
                                       detail: metric.detail)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                                .foregroundStyle(isSelected ? metric.tint : Color.secondary.opacity(0.4))
                        }
                        .padding(12)
                        .background(isSelected ? metric.tint.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isSelected ? metric.tint.opacity(0.35) : Color.clear, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
            if onRestoreBackup != nil {
                Button {
                    backupImportPresented = true
                } label: {
                    Label("Restore backup from Files", systemImage: "tray.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                if let restoreMessage {
                    Text(restoreMessage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var strapPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingIcon("battery.100percent.bolt", tint: .blue)
            Text("Connect your strap")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("Atria auto-detects the strap. There is no generation picker.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            StrapChargeIllustration()
            VStack(alignment: .leading, spacing: 14) {
                numberedStep(1, title: "Charge the strap", detail: "Snap on the battery pack before first use.")
                numberedStep(2, title: "Close the official WHOOP app", detail: "Only one app can own the strap connection.")
                numberedStep(3, title: "Allow Bluetooth", detail: "Atria uses Bluetooth to scan and connect locally.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
            OnboardingConnectionStatusView(ble: ble)
        }
        .onAppear { ble.startScan(reason: "onboarding_strap") }
        .task(id: ble.status) {
            await debugCompleteFromConnectedStrapIfRequested()
        }
    }

    @MainActor
    private func debugCompleteFromConnectedStrapIfRequested() async {
#if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--atria-ui-onboarding-complete-connected-strap") else { return }
        guard step == .strap, ble.status == .connected, !didDebugCompleteFromConnectedStrap else { return }
        didDebugCompleteFromConnectedStrap = true
        AtriaDebugLog("ATRIADBG onboarding status=debug_complete_connected_strap action=complete")
        try? await Task.sleep(nanoseconds: 700_000_000)
        onComplete(draft)
#endif
    }

    private var youPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingIcon("person.crop.circle.fill", tint: .purple)
            Text("You")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("A few basics help Atria tune calories and heart-rate zones.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(18)
            .atriaCard(emphasis: .soft)
            // Footer used to repeat the header ("...calories and heart-rate
            // zones") verbatim; now it adds the genuinely useful fact that these
            // are optional and editable later instead of duplicating.
            Text("Optional — you can update these anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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
            .frame(maxWidth: 300)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
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
        VStack(alignment: .leading, spacing: 18) {
            onboardingIcon("moon.stars.fill", tint: .indigo)
            Text("Wear it tonight — first sleep tomorrow morning. Recovery calibrates over your first 3–4 nights.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "checkmark.seal.fill", tint: .green, title: "Tonight", detail: "Keep the strap on your wrist while you sleep.")
                featureRow(icon: "sunrise.fill", tint: .orange, title: "Tomorrow", detail: "Open Atria to review your first sleep.")
                featureRow(icon: "chart.line.uptrend.xyaxis", tint: .blue, title: "First week", detail: "Recovery confidence improves after several nights.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
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
            .font(.system(size: 42, weight: .semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
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
            guard let url = urls.first, let onRestoreBackup else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            if onRestoreBackup(url) {
                restoreMessage = "Backup restored."
            } else {
                restoreMessage = "Restore failed. Choose an Atria .json or .json.gz archive."
            }
        case .failure:
            restoreMessage = "Restore canceled."
        }
    }

    private func rowLabel(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func numericProfileField(_ title: String, value: Binding<Int>, suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 74)
                .textFieldStyle(.roundedBorder)
            Text(suffix)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func numericProfileField(_ title: String, value: Binding<Double>, suffix: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 74)
                .textFieldStyle(.roundedBorder)
            Text(suffix)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func featureRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func numberedStep(_ number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct StrapChargeIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
            Capsule()
                .strokeBorder(Color.primary.opacity(0.22), lineWidth: 5)
                .frame(width: 210, height: 58)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.blue.opacity(0.75))
                .frame(width: 72, height: 42)
                .offset(x: 22)
            Image(systemName: "bolt.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .offset(x: 22)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .atriaCard(emphasis: .soft)
        .accessibilityLabel("WHOOP strap charging illustration")
    }
}
