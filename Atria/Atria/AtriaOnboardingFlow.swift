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
    @State private var didDebugCompleteFromConnectedStrap = false
    @State private var backupImportPresented = false
    @State private var restoreMessage: String?

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
                            .frame(maxWidth: .infinity)
                    }
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
            onboardingIcon("waveform.path.ecg", tint: .green)
            Text("Your WHOOP strap, no subscription. Data stays on your phone.")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "heart.text.square.fill", tint: .green, title: "Recovery", detail: "Morning readiness from your overnight signal.")
                featureRow(icon: "bed.double.fill", tint: .cyan, title: "Sleep", detail: "Wear it tonight and review sleep tomorrow.")
                featureRow(icon: "flame.fill", tint: .orange, title: "Strain", detail: "Workout and day load from heart-rate effort.")
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
                .buttonStyle(.bordered)
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
                Stepper(value: birthYear, in: 1926...2013, step: 1) {
                    rowLabel("Birth year", value: "\(currentBirthYear)")
                }
                Picker("Sex", selection: $draft.biologicalSex) {
                    ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .pickerStyle(.segmented)
                Stepper(value: $draft.heightCm, in: 0...230, step: 1) {
                    rowLabel("Height", value: draft.heightCm > 0 ? "\(Int(draft.heightCm.rounded())) cm" : "Not set")
                }
                Stepper(value: $draft.weightKg, in: 0...250, step: 1) {
                    rowLabel("Weight", value: draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded())) kg" : "Not set")
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
            Text("Used for calories and heart-rate zones.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

    private var birthYear: Binding<Int> {
        Binding {
            currentBirthYear
        } set: { year in
            let currentYear = Calendar.current.component(.year, from: Date())
            draft.age = min(max(currentYear - year, 13), 100)
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
