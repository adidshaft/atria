import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    let ble: AtriaBLEManager
    let store: SessionStore
    let workoutRouteRecorder: AtriaWorkoutRouteRecorder
    @State private var showOnboarding = false
    @State private var onboardingStage: OnboardingStage = .flow
    @State private var showOnboardingConsentSheet = false
    @StateObject private var onboardingHistoryBootstrap: AtriaOnboardingHistoryBootstrap

    /// Keep first launch bounded: the four core pages are followed only by the
    /// explicit research-sharing choice. Nickname, ring layout, and cycle
    /// tracking remain available from Customize/Settings instead of blocking
    /// entry with three additional full-screen steps.
    private enum OnboardingStage {
        case flow
        case sharingChoice(AthleteProfile)
    }

    /// Both onboarding-presentation state variables are seeded here at init,
    /// not in `.onAppear`: setting `onboardingStage` to a non-`.flow` value
    /// and flipping `showOnboarding` to true in the same `onAppear` closure
    /// hit a real SwiftUI staleness quirk where `fullScreenCover(isPresented:)`
    /// presents using the content-driving state's value from *before* that
    /// closure ran, for the very first presentation only (subsequent content
    /// changes, e.g. `AtriaOnboardingFlow`'s completion callback below, apply
    /// correctly since the cover is already presented by then). This was
    /// invisible previously because `onboardingStage`'s initial value and its
    /// onAppear-assigned value were both always `.flow`. Computing both in
    /// `init` sidesteps the whole class of bug: the very first render already
    /// reflects the right stage.
    init(ble: AtriaBLEManager,
         store: SessionStore,
         workoutRouteRecorder: AtriaWorkoutRouteRecorder) {
        self.ble = ble
        self.store = store
        self.workoutRouteRecorder = workoutRouteRecorder
        let debugOnboardingStep = Self.debugOnboardingStepArgument()
        let debugCompletesOnboarding = AtriaDeveloperMode.isEnabled
            && ProcessInfo.processInfo.arguments.contains("--atria-complete-onboarding")
        _onboardingStage = State(initialValue: Self.initialOnboardingStage(debugStepName: debugOnboardingStep, profile: store.profile))
        _showOnboarding = State(initialValue: debugOnboardingStep != nil || (!store.profile.hasCompletedOnboarding && !debugCompletesOnboarding))
        _onboardingHistoryBootstrap = StateObject(
            wrappedValue: AtriaOnboardingHistoryBootstrap(ble: ble, store: store)
        )
    }

    var body: some View {
        AtriaHomeContainer(ble: ble,
                           store: store,
                           workoutRouteRecorder: workoutRouteRecorder)
            .equatable()
            .fullScreenCover(isPresented: $showOnboarding) {
                switch onboardingStage {
                case .flow:
                    AtriaOnboardingFlow(profile: store.profile,
                                        ble: ble,
                                        historyBootstrap: onboardingHistoryBootstrap,
                                        debugInitialStep: Self.debugOnboardingStepArgument(),
                                        onRestoreBackup: { url in
                                            guard await store.restoreSessionBackup(from: url) else { return false }
                                            // A restored phone backup does not prove that this
                                            // physical strap's pending flash history was safely
                                            // imported and retired. Keep first-run setup visible
                                            // until the strap-specific bootstrap fence completes.
                                            showOnboarding = !store.profile.hasCompletedOnboarding
                                                || !onboardingHistoryBootstrap.isCompleteForCurrentStrap
                                            return true
                                        }) { profile in
                        onboardingStage = .sharingChoice(
                            store.profile.hasCompletedOnboarding ? store.profile : profile
                        )
                    }
                    .interactiveDismissDisabled()
                case .sharingChoice(let profile):
                    AtriaOnboardingSharingChoiceStep { sharingEnabled in
                        if sharingEnabled {
                            // Same inspector-gated consent flow as Settings:
                            // Agree stays disabled until the real bundle has
                            // been opened. Dismissing without agreeing means
                            // sharing stays off — onboarding still completes.
                            showOnboardingConsentSheet = true
                        } else {
                            if onboardingHistoryBootstrap.isCompleteForCurrentStrap {
                                store.completeOnboarding(with: profile)
                                showOnboarding = false
                            } else {
                                onboardingStage = .flow
                            }
                        }
                    }
                    .interactiveDismissDisabled()
                    .sheet(isPresented: $showOnboardingConsentSheet,
                           onDismiss: {
                               if onboardingHistoryBootstrap.isCompleteForCurrentStrap {
                                   store.completeOnboarding(with: profile)
                                   showOnboarding = false
                               } else {
                                   onboardingStage = .flow
                               }
                           }) {
                        AtriaResearchConsentSheet(buildPreview: { await AtriaResearchBundleBuilder.build(store: store) },
                                                  onConsented: {
                                                      showOnboardingConsentSheet = false
                                                  })
                    }
                }
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

    /// The only post-flow mandatory choice is research sharing. Retired
    /// personalization debug names fall through to the core flow.
    private static func initialOnboardingStage(debugStepName: String?, profile: AthleteProfile) -> OnboardingStage {
#if DEBUG
        switch debugStepName?.lowercased() {
        case "sharing", "sharing-choice", "sharingchoice": return .sharingChoice(profile)
        default: return .flow
        }
#else
        return .flow
#endif
    }
}

/// Final onboarding step: the anonymous research-sharing choice. Opt-out —
/// the toggle starts ON, honest about what leaves the phone, and the user can
/// decline right here or later in Settings. Consent itself is still only ever
/// recorded through `AtriaResearchSharing.grantConsent()` (never bypassed),
/// and declining here simply skips that call — the existing revoke path in
/// Settings is untouched.
struct AtriaOnboardingSharingChoiceStep: View {
    let onContinue: (Bool) -> Void
    @State private var sharingEnabled = true

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.hierarchical)
                        Text("Help improve Atria")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Anonymous data only. No identity or location. Review the bundle before sharing.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle(isOn: $sharingEnabled) {
                            Label("Share anonymously with developers", systemImage: "shippingbox")
                        }
                        .padding(14)
                        .atriaCard(emphasis: .soft)
                        .accessibilityHint("Includes heart rate, sleep, workouts, daily scores, and journal answers after you inspect the bundle.")

                        DisclosureGroup("Privacy details") {
                            Text("Nightly bundles use a random code and scrambled dates. They stay on this phone until a server is configured. Turn sharing off anytime.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        onContinue(sharingEnabled)
                    } label: {
                        Text("Start using Atria")
                            .frame(maxWidth: .infinity)
                    }
                    .atriaCardAction(tint: .green)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
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
        AtriaDesignTokens.Surface.appBackground(isDark: colorScheme == .dark)
    }

    private var topGlowColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.12) : Color.white.opacity(0.42)
    }

    private var bottomGlowColor: Color {
        colorScheme == .dark ? Color.blue.opacity(0.10) : Color.cyan.opacity(0.12)
    }
}

/// Live, observed connection state for the onboarding "Connect your strap" step.
/// A dedicated `@ObservedObject` subview so heart-rate ticks only re-render this
/// card, not the whole onboarding screen.
struct OnboardingConnectionStatusView: View {
    @ObservedObject var ble: AtriaBLEManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHealthyContact: Bool { ble.hasContact || ble.heartRate > 0 }

    private var hasFreshHeartRate: Bool { ble.currentConnectionHasFreshHeartRate }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.16))
                    .frame(width: 46, height: 46)
                if isSearching {
                    ProgressView().tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                }
            }

            Text(title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if hasFreshHeartRate {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(ble.heartRate)")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .atriaCard(emphasis: .soft)
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: ble.status)
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: ble.hasContact)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle)")
    }

    private var isSearching: Bool {
        ble.status == .scanning || ble.status == .connecting || ble.status == .disconnected
    }

    private var title: String {
        switch ble.status {
        case .poweredOff: return "Bluetooth is off"
        case .scanning, .disconnected: return "Searching for your strap…"
        case .connecting: return "Connecting…"
        case .connected:
            if hasFreshHeartRate { return "Live" }
            return isHealthyContact ? "Confirming live data…" : "Put the strap back on"
        }
    }

    private var subtitle: String {
        switch ble.status {
        case .poweredOff: return "Turn on Bluetooth in Settings to connect."
        case .scanning, .disconnected: return "Make sure the strap is on your wrist."
        case .connecting: return "Linking to your strap."
        case .connected:
            if hasFreshHeartRate { return "Atria is reading fresh heart-rate data." }
            return isHealthyContact
                ? "The Bluetooth link is connected; Atria is waiting for a fresh strap sample."
                : "Pairing can take up to 3 minutes. The blue light stops when it finishes; then wear the strap snugly."
        }
    }

    private var symbol: String {
        switch ble.status {
        case .poweredOff: return "bolt.slash.fill"
        case .scanning, .disconnected, .connecting: return "dot.radiowaves.left.and.right"
        case .connected: return hasFreshHeartRate ? "checkmark.circle.fill" : "waveform.path.ecg"
        }
    }

    private var tint: Color {
        switch ble.status {
        case .poweredOff: return .red
        case .scanning, .disconnected: return .blue
        case .connecting: return .yellow
        case .connected: return hasFreshHeartRate ? .green : .orange
        }
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

/// Minimal heart-rate sparkline.
struct Sparkline: View, Equatable {
    let values: [Int]
    var tint: Color = .red

    static func == (lhs: Sparkline, rhs: Sparkline) -> Bool {
        lhs.values == rhs.values
            && lhs.tint == rhs.tint
    }

    var body: some View {
        Group {
            if values.count > 1 {
                SparklineShape(values: values)
                    .stroke(tint.gradient, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
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
    ContentView(ble: AtriaBLEManager(),
                store: SessionStore(),
                workoutRouteRecorder: AtriaWorkoutRouteRecorder())
}
