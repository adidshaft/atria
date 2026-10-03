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
    @State private var appReviewDemoActive = AtriaAppReviewDemo.isActive
    @State private var appReviewDemoUnavailable = false
    @StateObject private var onboardingHistoryBootstrap: AtriaOnboardingHistoryBootstrap

    /// The active flow owns the eight compact setup and personalization pages;
    /// this outer coordinator adds only the explicit research-sharing choice.
    /// Keeping that consent stage separate preserves its inspect-before-agree
    /// gate without duplicating any of the in-flow choices.
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
            // Floats above the tab bar. At the top it covered the full-bleed
            // header and hid the Settings gear, so a reviewer could not open
            // Settings with sample data (2026-09-28).
            .overlay(alignment: .bottom) {
                if appReviewDemoActive {
                    AtriaDemoDataBanner {
                        Task { @MainActor in
                            await store.clearAppReviewDemo()
                            ble.exitAppReviewDemoMode()
                            appReviewDemoActive = false
                            onboardingStage = .flow
                            showOnboarding = true
                        }
                    }
                }
            }
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
                                                || !onboardingHistoryBootstrap.isSetupComplete
                                            return true
                                        },
                                        onAppReviewDemo: {
                                            Task { @MainActor in
                                                // Activation refuses when this install already
                                                // holds real data. Say so instead of a dead tap.
                                                guard await store.activateAppReviewDemo() else {
                                                    appReviewDemoUnavailable = true
                                                    return
                                                }
                                                ble.enterAppReviewDemoMode()
                                                appReviewDemoActive = true
                                                showOnboarding = false
                                            }
                                        }) { profile in
                        onboardingStage = .sharingChoice(
                            store.profile.hasCompletedOnboarding ? store.profile : profile
                        )
                    }
                    .interactiveDismissDisabled()
                    .alert("Sample data unavailable", isPresented: $appReviewDemoUnavailable) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Sample data only loads on a fresh install, so it can never mix with or replace your own history.")
                    }
                case .sharingChoice(let profile):
                    AtriaOnboardingSharingChoiceStep { sharingEnabled in
                        if sharingEnabled {
                            // Same inspector-gated consent flow as Settings:
                            // Agree stays disabled until the real bundle has
                            // been opened. Dismissing without agreeing means
                            // sharing stays off — onboarding still completes.
                            showOnboardingConsentSheet = true
                        } else {
                            if onboardingHistoryBootstrap.isSetupComplete {
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
                               if onboardingHistoryBootstrap.isSetupComplete {
                                   store.completeOnboarding(with: profile)
                                   showOnboarding = false
                               } else {
                                   onboardingStage = .flow
                               }
                           }) {
                        AtriaResearchConsentSheet(buildPreview: { await AtriaResearchBundleBuilder.preview(store: store) },
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
                        // Same 84pt gradient tile the flow pages open with
                        // (2026-09-02 screenshot audit): this final page used a
                        // bare 36pt symbol, so the last screen read as a
                        // different app from the seven before it.
                        RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
                            .fill(LinearGradient(colors: [Color.blue.opacity(0.38), Color.cyan.opacity(0.22)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 84, height: 84)
                            .overlay {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 36, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
                                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
                            }
                            .accessibilityHidden(true)
                        Text("Help improve Atria")
                            .font(AtriaDesignTokens.Typography.pageTitle)
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
                        // Same metrics as the flow's PrimaryActionButton so the
                        // final "Start using Atria" is not a smaller pill than
                        // every "Continue" before it.
                        Text("Start using Atria")
                            .font(.headline.weight(.bold))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 30)
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
        AtriaDesignTokens.Surface.appBackground(isDark: colorScheme == .dark)
    }

    private var topGlowColor: Color {
        colorScheme == .dark ? Color.cyan.opacity(0.12) : Color.white.opacity(0.42)
    }

    private var bottomGlowColor: Color {
        colorScheme == .dark ? Color.blue.opacity(0.10) : Color.cyan.opacity(0.12)
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
