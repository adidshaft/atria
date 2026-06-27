import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    let ble: AtriaBLEManager
    let store: SessionStore
    @State private var showOnboarding = false

    var body: some View {
        AtriaHomeContainer(ble: ble, store: store)
            .equatable()
            .onAppear {
                let debugOnboardingStep = Self.debugOnboardingStepArgument()
                let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled
                    && ProcessInfo.processInfo.arguments.contains("--atria-complete-onboarding")
                showOnboarding = debugOnboardingStep != nil || (!store.profile.hasCompletedOnboarding && !debugCompletesOnboarding)
            }
            .sheet(isPresented: $showOnboarding) {
                ProfileOnboardingView(profile: store.profile,
                                      debugInitialStep: Self.debugOnboardingStepArgument()) { profile in
                    store.completeOnboarding(with: profile)
                    showOnboarding = false
                }
                .interactiveDismissDisabled()
            }
    }

    private static func debugOnboardingStepArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
#if DEBUG
        guard let index = arguments.firstIndex(of: "--atria-ui-onboarding-step") else { return nil }
        let valueIndex = arguments.index(after: index)
        guard arguments.indices.contains(valueIndex) else { return "welcome" }
        return arguments[valueIndex]
#else
        return nil
#endif
    }
}

private enum OfficialAppCoexistenceRisk {
    static var mayBeInstalled: Bool {
        guard let url = URL(string: "whoop://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}

struct AtriaDashboardBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(colors: gradientColors,
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
        .overlay(alignment: .topTrailing) {
            // Radial gradient glow instead of a blurred circle: same soft look,
            // but no blur modifier pass (blur is very expensive, especially in the
            // Simulator, and was a source of UI lag).
            Circle()
                .fill(RadialGradient(colors: [topGlowColor, .clear],
                                     center: .center, startRadius: 0, endRadius: 150))
                .frame(width: 300, height: 300)
                .offset(x: 70, y: -70)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(RadialGradient(colors: [bottomGlowColor, .clear],
                                     center: .center, startRadius: 0, endRadius: 140))
                .frame(width: 280, height: 280)
                .offset(x: -80, y: 90)
        }
    }

    private var gradientColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.020, green: 0.024, blue: 0.034),
                Color(red: 0.024, green: 0.030, blue: 0.044),
                Color(red: 0.016, green: 0.020, blue: 0.030)
            ]
        }
        return [
            Color(red: 0.96, green: 0.97, blue: 0.99),
            Color(red: 0.89, green: 0.93, blue: 0.98),
            Color(red: 0.97, green: 0.96, blue: 0.94)
        ]
    }

    private var topGlowColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.12) : Color.white.opacity(0.42)
    }

    private var bottomGlowColor: Color {
        colorScheme == .dark ? Color.blue.opacity(0.10) : Color.cyan.opacity(0.12)
    }
}

struct ProfileOnboardingView: View {
    @State private var draft: AthleteProfile
    let onComplete: (AthleteProfile) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step: OnboardingStep = .welcome
    @State private var officialAppMayBeInstalled = OfficialAppCoexistenceRisk.mayBeInstalled
    @State private var didRecheckOfficialApp = false

    private enum OnboardingStep: Int, CaseIterable {
        case welcome
        case coexistence
        case connect
        case profile

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .profile }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome": self = .welcome
            case "coexistence": self = .coexistence
            case "connect", "strap": self = .connect
            case "profile": self = .profile
            default: return nil
            }
        }
    }

    init(profile: AthleteProfile,
         debugInitialStep: String? = nil,
         onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        _step = State(initialValue: OnboardingStep(debugName: debugInitialStep) ?? .welcome)
        self.onComplete = onComplete
    }

    private func recheckOfficialApp() {
        let installed = OfficialAppCoexistenceRisk.mayBeInstalled
        didRecheckOfficialApp = true
        if reduceMotion {
            officialAppMayBeInstalled = installed
        } else {
            withAnimation(.snappy(duration: 0.28)) { officialAppMayBeInstalled = installed }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        switch step {
                        case .welcome: welcomeStep
                        case .coexistence: coexistenceStep
                        case .connect: connectStep
                        case .profile: profileStep
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                    .transition(.opacity)
                    .id(step)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !step.isFirst {
                        Button {
                            advance(to: OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 14) {
                    onboardingProgressDots
                    Button {
                        if step.isLast {
                            onComplete(draft)
                        } else {
                            advance(to: OnboardingStep(rawValue: step.rawValue + 1) ?? .profile)
                        }
                    } label: {
                        Text(primaryButtonTitle)
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .blue)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get started"
        case .coexistence: return officialAppMayBeInstalled ? "I’ll do this — continue" : "Continue"
        case .connect: return "Continue"
        case .profile: return "Use this profile"
        }
    }

    private func advance(to next: OnboardingStep) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: 0.28)) { step = next }
        }
    }

    private var onboardingProgressDots: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                Capsule()
                    .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: item == step ? 22 : 7, height: 7)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: step)
            }
        }
        .accessibilityLabel("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    // MARK: - Step 1: Welcome

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Image("AtriaLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .accessibilityLabel("Atria")
                Text("Welcome to Atria")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Your strap, your data — free and entirely on your phone.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingFeatureRow(icon: "lock.shield.fill",
                                     tint: .green,
                                     title: "Local data",
                                     detail: "No account, cloud, or subscription.")
                onboardingFeatureRow(icon: "waveform.path.ecg",
                                     tint: .pink,
                                     title: "Strap first",
                                     detail: "Heart rate drives every score.")
                onboardingFeatureRow(icon: "checkmark.seal.fill",
                                     tint: .blue,
                                     title: "Confidence shown",
                                     detail: "Unready metrics stay marked.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    // MARK: - Step 2: app coexistence

    @ViewBuilder
    private var coexistenceStep: some View {
        if officialAppMayBeInstalled {
            officialAppConflictStep
        } else {
            officialAppClearStep
        }
    }

    private var officialAppConflictStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.orange)
                Text("Make room for Atria")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("The official strap app can reclaim the strap and fragment readings.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Pick one")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                onboardingNumberedStep(1,
                                       title: "Delete the official strap app (recommended)",
                                       detail: "Remove App, then Delete App.")
                onboardingNumberedStep(2,
                                       title: "Or fully disable it",
                                       detail: "Log out, then disable Bluetooth.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            VStack(alignment: .leading, spacing: 12) {
                Label("Why this matters", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("iOS gives one app strap ownership.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    recheckOfficialApp()
                } label: {
                    Label("I removed it — recheck", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .atriaCardAction(tint: .orange)

                if didRecheckOfficialApp && officialAppMayBeInstalled {
                    Label("Official strap app still detected.",
                          systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    private var officialAppClearStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.green)
                Text(didRecheckOfficialApp ? "Nicely done" : "You’re clear")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("No competing app detected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                onboardingFeatureRow(icon: "antenna.radiowaves.left.and.right",
                                     tint: .green,
                                     title: "One reader at a time",
                                     detail: "Atria owns the strap.")
                onboardingFeatureRow(icon: "bell.badge",
                                     tint: .blue,
                                     title: "We’ll warn you",
                                     detail: "Interference becomes visible.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    // MARK: - Step 3: Connect your strap

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.blue)
                Text("Connect your strap")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Atria reads your strap over Bluetooth.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                onboardingNumberedStep(1,
                                       title: "Put the strap on",
                                       detail: "Wear it snug.")
                onboardingNumberedStep(2,
                                       title: "Keep your phone nearby",
                                       detail: "Atria connects on its own.")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            Label("Switch apps freely; don’t force quit.",
                  systemImage: "hand.raised.fill")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Label("No strap nearby? Continue anyway.",
                  systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Step 4: Profile

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Set your max heart rate")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("Atria uses this for strain and effort.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                Text("How should we set it?")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                onboardingSourcePicker

                HStack(spacing: 12) {
                    onboardingStepperCard(title: "Your age",
                                          value: "\(draft.age)",
                                          detail: "13-100") {
                        draft.age = max(13, draft.age - 1)
                    } increment: {
                        draft.age = min(100, draft.age + 1)
                    }

                    onboardingStepperCard(title: "Measured max",
                                          value: "\(draft.measuredMaxHR)",
                                          detail: "120-220 bpm") {
                        draft.measuredMaxHR = max(120, draft.measuredMaxHR - 1)
                    } increment: {
                        draft.measuredMaxHR = min(220, draft.measuredMaxHR + 1)
                    }
                }

                Picker("Sex", selection: $draft.biologicalSex) {
                    ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    onboardingStepperCard(title: "Weight",
                                          value: draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded()))" : "--",
                                          detail: "kg") {
                        draft.weightKg = draft.weightKg <= 0 ? 70 : max(30, draft.weightKg - 1)
                    } increment: {
                        draft.weightKg = draft.weightKg <= 0 ? 70 : min(250, draft.weightKg + 1)
                    }

                    onboardingStepperCard(title: "Height",
                                          value: draft.heightCm > 0 ? "\(Int(draft.heightCm.rounded()))" : "--",
                                          detail: "cm optional") {
                        draft.heightCm = draft.heightCm <= 0 ? 170 : max(120, draft.heightCm - 1)
                    } increment: {
                        draft.heightCm = draft.heightCm <= 0 ? 170 : min(230, draft.heightCm + 1)
                    }
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Your max heart rate")
                        .font(.headline.weight(.semibold))
                    Spacer()
                    Text("\(draft.maxHR)")
                        .font(.title3.weight(.bold).monospacedDigit())
                }

                Text(draft.maxHRSource == .ageEstimate ? "Age estimate; measured is better." : "Measured max selected.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    onboardingMetricPill(label: "Source", value: draft.maxHRSource.label, tint: .cyan)
                    onboardingMetricPill(label: "Age", value: "\(draft.age)", tint: .green)
                    onboardingMetricPill(label: "Weight", value: draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded())) kg" : "Add", tint: .orange)
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)
        }
    }

    private func onboardingFeatureRow(icon: String,
                                      tint: Color,
                                      title: String,
                                      detail: String) -> some View {
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func onboardingNumberedStep(_ number: Int,
                                        title: String,
                                        detail: String) -> some View {
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
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var onboardingSourcePicker: some View {
        HStack(spacing: 8) {
            ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                Button {
                    if reduceMotion {
                        draft.maxHRSource = source
                    } else {
                        withAnimation(.snappy(duration: 0.22)) {
                            draft.maxHRSource = source
                        }
                    }
                } label: {
                    Text(source.label)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .atriaGlassSelectable(selected: draft.maxHRSource == source)
            }
        }
        .padding(8)
        .atriaCard(emphasis: .soft)
    }

    private func onboardingStepperCard(title: String,
                                       value: String,
                                       detail: String,
                                       decrement: @escaping () -> Void,
                                       increment: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.05) : Color.white.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.24), lineWidth: 1)
                }
        )
    }

    private func onboardingMetricPill(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? tint.opacity(0.10) : tint.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20), lineWidth: 1)
                }
        )
    }
}

extension View {
    /// Cheap selectable chrome for in-scroll controls. Real Liquid Glass stays on
    /// floating toolbar/safe-area controls; repeated glass buttons in cards and
    /// grids are too expensive during scroll.
    @ViewBuilder
    func atriaGlassSelectable(selected: Bool, tint: Color = .blue) -> some View {
        self.buttonStyle(AtriaSegmentButtonStyle(selected: selected, tint: tint))
    }
}

private struct ProfileOnboardingSourceButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.11 : 0.72),
                                colorScheme == .dark
                                    ? Color(red: 0.060, green: 0.078, blue: 0.116).opacity(0.84)
                                    : Color.white.opacity(0.44)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28), lineWidth: 1)
                        }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct ProfileOnboardingPrimaryButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.92 : 1))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 30)
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
            .background(
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                    .fill(
                        LinearGradient(colors: colorScheme == .dark
                            ? [
                                Color(red: 0.18, green: 0.52, blue: 0.98),
                                Color(red: 0.06, green: 0.28, blue: 0.82)
                            ]
                            : [
                                Color(red: 0.24, green: 0.56, blue: 0.98),
                                Color(red: 0.12, green: 0.40, blue: 0.90)
                            ],
                                       startPoint: .topLeading,
                                       endPoint: .bottomTrailing)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous)
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.14 : 0.28), lineWidth: 1)
                    }
            )
            .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
    }
}

private struct ProfileOnboardingStepperButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.88 : 1))
            .padding(.vertical, 10)
            .atriaCard(emphasis: .soft)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Minimal heart-rate sparkline.
struct Sparkline: View, Equatable {
    let values: [Int]

    static func == (lhs: Sparkline, rhs: Sparkline) -> Bool {
        lhs.values == rhs.values
    }

    var body: some View {
        Group {
            if values.count > 1 {
                SparklineShape(values: values)
                    .stroke(.red.gradient, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .padding(.vertical, 2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipped()
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct SparklineShape: Shape, Equatable {
    let values: [Int]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }

        let lo = Double(values.min() ?? 0)
        let hi = Double(values.max() ?? 1)
        let span = max(hi - lo, 1)

        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.width * CGFloat(Double(index) / Double(values.count - 1))
            let y = rect.height * CGFloat(1 - (Double(value) - lo) / span)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }
}

#Preview {
    ContentView(ble: AtriaBLEManager(), store: SessionStore())
}
