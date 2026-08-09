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

/// Onboarding step: an optional friendly nickname used for a warmer greeting
/// elsewhere in the app. Purely cosmetic — skipping leaves the key unset and
/// nothing else depends on it. Written directly via `UserDefaults.standard`
/// (not `@AppStorage`/`@AtriaDefault`) since this view exists for a single
/// tap and has no reason to observe the key afterward.
struct AtriaOnboardingNicknameStep: View {
    static let nicknameKey = "atria.user.nickname"

    let onContinue: () -> Void
    @State private var nickname = ""

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "person.text.rectangle.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.blue)
                            .symbolRenderingMode(.hierarchical)
                        Text("What should we call you?")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Optional — used for a friendlier greeting around the app. Skip if you'd rather not.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField("Nickname", text: $nickname)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .padding(18)
                            .atriaCard(emphasis: .soft)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        persistNickname()
                        onContinue()
                    } label: {
                        Text(trimmedNickname.isEmpty ? "Skip" : "Continue")
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

    private var trimmedNickname: String {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func persistNickname() {
        let trimmed = trimmedNickname
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.nicknameKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.nicknameKey)
        }
    }
}

/// Onboarding step: pick which of the five supported metrics (sleep/recovery/
/// strain/hrv/rhr) each of the three home-screen rings shows, and which
/// metric sits in the ring's center number. Pre-checked to the same defaults
/// the Today screen and `AtriaHomeLayoutConfig` already fall back to
/// (sleep/recovery/strain, center recovery) so skipping this step is
/// indistinguishable from never having seen it. Persists to the exact same
/// keys/formats `AtriaTodayScreen.swift` and `AtriaHomeLayoutConfig.swift`
/// read: the `atria.today.ringMetrics` CSV of `AtriaTriRingSlot` raw values,
/// and `ringCenterMetric` inside the `AtriaHomeLayoutConfig` JSON blob at
/// `AtriaHomeLayoutConfig.storageKey`.
struct AtriaOnboardingRingPickerStep: View {
    static let ringMetricsKey = "atria.today.ringMetrics"

    let onContinue: () -> Void
    @State private var ringSlots: [AtriaTriRingSlot] = AtriaTriRingSlot.defaultOrder
    @State private var centerMetric: AtriaHomeLayoutConfig.RingCenterMetric = .recovery

    private static let positionLabels = ["Outer ring", "Middle ring", "Inner ring"]

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // Live preview of the actual ring choices (2026-07-07
                        // design handoff) -- fills are illustrative, same
                        // precedent as AtriaOnboardingFlow.onboardingRingCard.
                        ringPreviewCard
                        Text("Choose your rings")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Pick what the three rings track, and which one sits in the center. You can always change this later from Customize Today.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(ringSlots.enumerated()), id: \.offset) { index, slot in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(Self.slotTint(slot))
                                        .frame(width: 10, height: 10)
                                        .accessibilityHidden(true)
                                    Text(Self.positionLabels[index])
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Picker(Self.positionLabels[index], selection: Binding(
                                        get: { slot },
                                        set: { assignRingSlot($0, toPosition: index) }
                                    )) {
                                        ForEach(AtriaTriRingSlot.allCases, id: \.self) { option in
                                            Text(option.label).tag(option)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                }
                            }
                        }
                        .padding(18)
                        .atriaCard(emphasis: .soft)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Center number")
                                .font(.subheadline.weight(.semibold))
                            Picker("Center metric", selection: $centerMetric) {
                                ForEach(AtriaHomeLayoutConfig.RingCenterMetric.allCases, id: \.self) { metric in
                                    Text(centerMetricLabel(metric)).tag(metric)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                        .padding(18)
                        .atriaCard(emphasis: .soft)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                    .padding(.bottom, 124)
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        persistRingChoices()
                        onContinue()
                    } label: {
                        Text("Continue")
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

    private var ringPreviewCard: some View {
        AtriaTriRing(slots: ringSlots.enumerated().map { index, slot in
            AtriaTriRingSlotContent(slot: slot,
                                    metric: AtriaTriRingMetric(title: slot.label,
                                                               value: Self.sampleValue(slot),
                                                               detail: "Example",
                                                               systemImage: Self.slotIcon(slot),
                                                               tint: Self.slotTint(slot),
                                                               fill: [0.82, 0.62, 0.46][index]))
        },
        centerValue: Self.sampleValue(centerSlot),
        centerState: "Example \u{00b7} \(centerMetricLabel(centerMetric))",
        accessibilitySummary: "Preview of your ring choices with example fills, not real data.",
        actions: [:])
        .frame(maxWidth: 240)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .atriaCard(emphasis: .soft)
    }

    /// The slot whose example value shows in the preview's center.
    private var centerSlot: AtriaTriRingSlot {
        switch centerMetric {
        case .recovery: return .recovery
        case .sleep: return .sleep
        case .strain: return .strain
        }
    }

    /// One identity hue per metric -- the same Metrics.electric* hues the
    /// live ring and glance tiles use, so the picker dots and preview match
    /// what the Today screen will actually paint.
    private static func slotTint(_ slot: AtriaTriRingSlot) -> Color {
        switch slot {
        case .sleep: return Metrics.electricSleep
        case .recovery: return Metrics.electricGreen
        case .strain: return Metrics.electricStrain
        case .hrv: return Metrics.electricHRV
        case .rhr: return Metrics.electricRHR
        }
    }

    private static func slotIcon(_ slot: AtriaTriRingSlot) -> String {
        switch slot {
        case .sleep: return "bed.double.fill"
        case .recovery: return "heart.fill"
        case .strain: return "flame.fill"
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.circle.fill"
        }
    }

    private static func sampleValue(_ slot: AtriaTriRingSlot) -> String {
        switch slot {
        case .sleep: return "7h 24m"
        case .recovery: return "78%"
        case .strain: return "12.4"
        case .hrv: return "62 ms"
        case .rhr: return "55 bpm"
        }
    }

    /// Same swap-rather-than-duplicate assignment `AtriaTodayScreen.swift`
    /// uses: if the picked metric already occupies a different ring, the two
    /// positions trade places instead of leaving a metric on two rings.
    private func assignRingSlot(_ slot: AtriaTriRingSlot, toPosition position: Int) {
        var slots = ringSlots
        guard slots.indices.contains(position) else { return }
        if let existing = slots.firstIndex(of: slot), existing != position {
            slots.swapAt(existing, position)
        } else {
            slots[position] = slot
        }
        ringSlots = slots
    }

    private func centerMetricLabel(_ metric: AtriaHomeLayoutConfig.RingCenterMetric) -> String {
        switch metric {
        case .recovery: return "Recovery"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        }
    }

    private func persistRingChoices() {
        let csv = ringSlots.map(\.rawValue).joined(separator: ",")
        UserDefaults.standard.set(csv, forKey: Self.ringMetricsKey)

        var config: AtriaHomeLayoutConfig = .default
        if let data = UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey)?.data(using: .utf8),
           !data.isEmpty,
           let decoded = try? AtriaHomeLayoutConfig.decoded(from: data) {
            config = decoded
        }
        config.ringCenterMetric = centerMetric
        if let encoded = try? config.encodedData(),
           let json = String(data: encoded, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: AtriaHomeLayoutConfig.storageKey)
        }
    }
}

/// Onboarding step: optional, off-by-default cycle-tracking opt-in. Honest
/// about scope (stays on this phone, never in research bundles) and phrased
/// with no gendered assumptions — the toggle is for anyone who wants
/// phase-aware notes, not addressed to a presumed audience. Writes through
/// the same `AtriaCycleTracking.setEnabled` path Settings/Journal use, so the
/// existing off-by-default and no-history-loss guarantees are unchanged.
struct AtriaOnboardingWomensHealthStep: View {
    let onContinue: () -> Void
    @State private var cycleTrackingEnabled = false

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        Image(systemName: "calendar.circle.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.pink)
                            .symbolRenderingMode(.hierarchical)
                        Text("Cycle tracking")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("Optional. Stays on this phone. Not in research bundles.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Toggle(isOn: $cycleTrackingEnabled) {
                            Label("Track menstrual cycle", systemImage: "calendar.circle.fill")
                        }
                        .padding(18)
                        .atriaCard(emphasis: .soft)

                        DisclosureGroup("How it works") {
                            Text("Turn it on any time from Journal. Phase-aware notes are estimates, never a diagnosis.")
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
                        AtriaCycleTracking.setEnabled(cycleTrackingEnabled)
                        onContinue()
                    } label: {
                        Text("Continue")
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

/// Recovery action for Bluetooth states that CoreBluetooth folds into the
/// transport's `.poweredOff` presentation. Permission denial is persistent until
/// the user changes Atria's system setting, while a powered-off radio is a
/// transient device state; onboarding must never present them as the same fault.
enum AtriaOnboardingBluetoothRecovery: Equatable {
    case none
    case radioPoweredOff
    case permissionDenied

    init(status: AtriaBLEManager.Status, permissionDenied: Bool) {
        if permissionDenied {
            self = .permissionDenied
        } else if status == .poweredOff {
            self = .radioPoweredOff
        } else {
            self = .none
        }
    }

    var primaryActionTitle: String? {
        switch self {
        case .none: return nil
        case .radioPoweredOff: return "Turn on Bluetooth"
        case .permissionDenied: return "Open Settings"
        }
    }

    /// A radio-off state resolves when Bluetooth is turned back on. Permission
    /// denial cannot resolve inside CoreBluetooth, so its primary action must stay
    /// enabled and route to the app's system settings instead of becoming a dead end.
    var disablesPrimaryAction: Bool {
        self == .radioPoweredOff
    }
}

/// Live, observed connection state for the onboarding "Connect your strap" step.
/// A dedicated `@ObservedObject` subview so heart-rate ticks only re-render this
/// card, not the whole onboarding screen.
struct OnboardingConnectionStatusView: View {
    @ObservedObject var ble: AtriaBLEManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isHealthyContact: Bool { ble.hasContact || ble.heartRate > 0 }

    private var hasFreshHeartRate: Bool { ble.currentConnectionHasFreshHeartRate }

    private var bluetoothRecovery: AtriaOnboardingBluetoothRecovery {
        AtriaOnboardingBluetoothRecovery(status: ble.status,
                                          permissionDenied: ble.bluetoothPermissionDenied)
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 14) {
                        statusIcon
                        statusCopy
                    }
                    if hasFreshHeartRate {
                        heartRateReading
                    }
                }
            } else {
                HStack(spacing: 14) {
                    statusIcon
                    statusCopy
                    Spacer(minLength: 8)
                    if hasFreshHeartRate {
                        heartRateReading
                    }
                }
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

    private var statusIcon: some View {
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
        .accessibilityHidden(true)
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var heartRateReading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(ble.heartRate)")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("bpm")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .transition(.opacity)
        .accessibilityHidden(true)
    }

    private var isSearching: Bool {
        ble.status == .scanning || ble.status == .connecting || ble.status == .disconnected
    }

    private var title: String {
        if bluetoothRecovery == .permissionDenied {
            return "Bluetooth access needed"
        }
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
        if bluetoothRecovery == .permissionDenied {
            return "Allow Atria to use Bluetooth in Settings, then return to connect your strap."
        }
        switch ble.status {
        case .poweredOff: return "Turn on Bluetooth in Control Center or Settings to connect."
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
        if bluetoothRecovery == .permissionDenied {
            return "hand.raised.fill"
        }
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
