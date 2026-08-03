import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Calm one-shot entrance for onboarding page content (2026-07-30, user: onboarding
/// should feel a little more alive). Content fades + rises ~10pt once when the page
/// appears, then settles — it is NOT a perpetual animation (the SwiftUI perf audit
/// forbids those) and it fully respects Reduce Motion. Crucially the RESTING state
/// is the correct layout (opacity 1, offset 0), so even if a paged TabView delivers
/// `onAppear` oddly, the page can never get stuck invisible — worst case it simply
/// doesn't animate.
private struct OnboardingEntrance<Content: View>: View {
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var settled: Bool { appeared || reduceMotion }

    var body: some View {
        content
            .opacity(settled ? 1 : 0)
            .offset(y: settled ? 0 : 10)
            .onAppear {
                guard !reduceMotion, !appeared else { return }
                withAnimation(.easeOut(duration: 0.42)) { appeared = true }
            }
    }
}

/// Uses the quiet, appearance-aware onboarding artwork when it is available while
/// retaining the established code-drawn backdrop for accessibility and a missing
/// asset catalog entry. The image is decorative: onboarding content remains the
/// only accessibility surface.
private struct AtriaOnboardingBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency, UIImage(named: "AtriaOnboardingBackdrop") != nil {
            // Color.clear takes the container's size EXACTLY; the image just fills
            // it as an overlay and is clipped. A bare scaledToFill image reports
            // its aspect-fill overflow size even inside a flexible .frame, which
            // grows the parent ZStack wider than the screen and pushes every page's
            // horizontal padding off the left edge (verified 2026-07-30: the
            // welcome title's "Y" was clipped, cards + button went edge-to-edge).
            // Color.clear is the definitive clamp so siblings keep their margins.
            Color.clear
                .overlay {
                    Image("AtriaOnboardingBackdrop")
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .accessibilityHidden(true)
        } else {
            AtriaDashboardBackdrop()
        }
    }
}

/// The generated metric haloes are intentionally quiet decoration behind the
/// sample ring, never an additional data signal. Reduce Transparency removes
/// them completely so the existing code-drawn ring remains the clean fallback.
private struct OnboardingMetricAccents: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        if !reduceTransparency {
            GeometryReader { proxy in
                let accentSize = min(proxy.size.width, proxy.size.height) * 0.56
                ZStack {
                    accent("AtriaMetricSleepAccent", size: accentSize)
                        .position(x: proxy.size.width * 0.27, y: proxy.size.height * 0.28)
                    accent("AtriaMetricRecoveryAccent", size: accentSize)
                        .position(x: proxy.size.width * 0.49, y: proxy.size.height * 0.60)
                    accent("AtriaMetricStrainAccent", size: accentSize)
                        .position(x: proxy.size.width * 0.74, y: proxy.size.height * 0.50)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func accent(_ name: String, size: CGFloat) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .opacity(0.10)
    }
}

/// A user-controlled product turntable inspired by premium hardware onboarding,
/// not a perpetual animation. Each tap advances the render to the next setup
/// moment; Reduce Motion keeps the same choice immediate and fully functional.
private struct StrapSetupShowcase: View {
    private enum Scene: Int, CaseIterable, Identifiable {
        case unbox
        case charge
        case wear
        case pair

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .unbox: return "Meet your strap"
            case .charge: return "Charge to begin"
            case .wear: return "Wear it snug"
            case .pair: return "Pairing-ready"
            }
        }

        var detail: String {
            switch self {
            case .unbox: return "A screen-free sensor built for the day ahead."
            case .charge: return "Seat the sensor in the dock before your first use."
            case .wear: return "Keep the band secure and comfortable on your wrist."
            case .pair: return "A soft blue glow means it is ready for iPhone pairing."
            }
        }

        var imageName: String {
            switch self {
            case .unbox: return "AtriaStrapHero"
            case .charge: return "AtriaSetupChargeScene"
            case .wear: return "AtriaSetupWearScene"
            case .pair: return "AtriaSetupPairScene"
            }
        }

        var usesTransparentArtwork: Bool { self == .unbox }

        var next: Scene {
            Scene(rawValue: (rawValue + 1) % Scene.allCases.count) ?? .unbox
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scene: Scene = .unbox

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                // Dark showcase base so the card reads as a dark "window" in BOTH
                // light and dark mode (2026-07-31 light-mode fix): the .unbox scene
                // uses a transparent strap render, so without this plate its
                // transparent areas showed the light onboarding backdrop through and
                // the white caption washed out. Scene photos fill over this and hide
                // it; only the transparent render relies on it.
                Color(red: 0.05, green: 0.06, blue: 0.10)

                artwork
                    .id(scene)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))

                LinearGradient(colors: [.clear, Color.black.opacity(0.75)],
                               startPoint: .center,
                               endPoint: .bottom)
                    .allowsHitTesting(false)

                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(scene.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(scene.detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.76))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button(action: advance) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.title3.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Rotate setup view")
                    .accessibilityHint("Shows the next strap setup view")
                }
                .padding(16)
            }
            .frame(height: 226)
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero,
                                        style: .continuous))

            HStack(spacing: 7) {
                ForEach(Scene.allCases) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Capsule()
                            .fill(candidate == scene ? Color.accentColor : Color.white.opacity(0.30))
                            .frame(width: candidate == scene ? 22 : 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.title)
                    .accessibilityAddTraits(candidate == scene ? .isSelected : [])
                }
            }
            .padding(.top, 10)
            .accessibilityElement(children: .contain)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
                .frame(height: 226)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if scene.usesTransparentArtwork {
            ZStack {
                LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.12),
                                        Color(red: 0.03, green: 0.04, blue: 0.07)],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                Image(scene.imageName)
                    .resizable()
                    .scaledToFit()
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        } else {
            Image(scene.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
    }

    private func advance() {
        select(scene.next)
    }

    private func select(_ next: Scene) {
        guard next != scene else { return }
        if reduceMotion {
            scene = next
        } else {
            withAnimation(.snappy(duration: 0.52)) { scene = next }
        }
    }
}

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
    // Design-parity slice 6 (2026-08-01) page state. Each is seeded from — and
    // written back to — the real backing store via AtriaOnboardingPersonalization
    // (nickname / ring slots / ring center) and AtriaCycleTracking (cycle), so
    // the onboarding choice takes effect the moment it is made.
    @State private var nicknameDraft = ""
    @State private var ringSlots: [AtriaTriRingSlot] = AtriaTriRingSlot.defaultOrder
    @State private var ringCenterMetric: AtriaHomeLayoutConfig.RingCenterMetric = .recovery
    @State private var cycleTrackingEnabled = false
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

        // No sample numbers anywhere in the product (2026-07-31): the
        // onboarding ring shows the same honest pre-data state the Home ring
        // uses — "--" centers and dashed learning bands — so the first thing
        // a new user sees is exactly what the app will look like until real
        // nights arrive, not a fabricated 64%.
        var centerValue: String { "--" }
    }

    private enum Step: Int, CaseIterable {
        case whatThisIs
        // 2026-08-01 (design-parity slice 6): nickname (P1), rings (P2), and
        // cycle (P3) pages were woven INTO this flow. They sit between the
        // existing pages rather than replacing any of them, so whatThisIs stays
        // first and expectations stays last exactly as before. Research (P4)
        // keeps its existing inspector-gated post-flow consent step so the user
        // is never asked to consent twice.
        case nickname
        case strap
        case you
        case rings
        case behaviors
        case cycle
        case expectations

        var isFirst: Bool { self == .whatThisIs }
        var isLast: Bool { self == .expectations }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome", "what-this-is", "what": self = .whatThisIs
            case "nickname", "name", "you-name": self = .nickname
            case "strap", "connect": self = .strap
            case "you", "profile": self = .you
            case "rings", "ring": self = .rings
            case "behaviors", "track", "tracking": self = .behaviors
            case "cycle", "womens-health", "cycle-tracking": self = .cycle
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
            case .nickname: return "Continue"
            case .strap:
                if strapIsReady { return "Continue" }
                if historyBootstrap.isWorking { return "Preparing your strap…" }
                if historyBootstrap.snapshot.phase == .failed { return "Retry secure import" }
                return ble.status == .connected ? "Waiting for live data…" : "Connect"
            case .you: return "Continue"
            case .rings: return "Continue"
            case .behaviors: return "Continue"
            case .cycle: return "Continue"
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
                AtriaOnboardingBackdrop()
                    .ignoresSafeArea()

                TabView(selection: $step) {
                    page { whatThisIsPage }
                        .tag(Step.whatThisIs)
                    page { nicknamePage }
                        .tag(Step.nickname)
                    page { strapPage }
                        .tag(Step.strap)
                    page { youPage }
                        .tag(Step.you)
                    page { ringsPage }
                        .tag(Step.rings)
                    page { behaviorsPage }
                        .tag(Step.behaviors)
                    page { cyclePage }
                        .tag(Step.cycle)
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
                    if stepIsSkippablePersonalization {
                        Button("Skip for now") {
                            move(to: Step(rawValue: step.rawValue + 1) ?? .expectations)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minHeight: 44)
                        .accessibilityHint("Skips this optional setup step. You can set it later in Settings.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    private var onboardingStrapIsReady: Bool { historyBootstrap.isCompleteForCurrentStrap }

    /// The three design-adopted personalization pages are optional: each persists
    /// continuously with a sensible default (blank nickname, default ring layout,
    /// cycle off), so a "Skip for now" simply advances and leaves the defaults in
    /// place. Everything here is changeable later from Settings/Customize.
    private var stepIsSkippablePersonalization: Bool {
        step == .nickname || step == .rings || step == .cycle
    }

    private func move(to next: Step) {
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.emphatic)) { step = next }
        }
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView(showsIndicators: false) {
            OnboardingEntrance {
                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 116)
            }
        }
    }

    private var whatThisIsPage: some View {
        // Image-led + minimal (2026-07-31, user: onboarding should lead with imagery,
        // "not just texts"). Lead with the lifestyle hero, then the tagline, then the
        // interactive sample ring. Visible copy stays to the one honest "sample
        // numbers" line and the quiet returning-user restore path.
        VStack(alignment: .leading, spacing: 16) {
            onboardingLifestyleHero
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
            Text("Your numbers appear here after your first night of wear.")
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

    // MARK: - Design-parity slice 6 pages (2026-08-01)

    /// P1 Welcome + nickname. Binds to the real "atria.user.nickname" store the
    /// Today screen reads for its greeting (via AtriaOnboardingPersonalization) —
    /// leaving it blank removes the key, so skipping looks like skipping.
    private var nicknamePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingGradientTile(systemImage: "sparkles",
                                   colors: [Color.purple.opacity(0.35), Color.blue.opacity(0.25)])
            Text("Welcome to Atria")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Your strap becomes a calm, honest readiness coach. What should we call you?")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Nickname", text: $nicknameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .frame(minHeight: 44)
                    .onChange(of: nicknameDraft) { _, newValue in
                        AtriaOnboardingPersonalization.persistNickname(newValue)
                    }
            }
            .padding(16)
            .atriaCard(emphasis: .soft)

            Text("Optional — used only for a friendlier greeting on this phone.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            nicknameDraft = AtriaOnboardingPersonalization.loadNickname()
        }
    }

    /// P2 Choose your rings. Ring assignment + CENTER NUMBER picker wired to the
    /// SAME real stores the Today screen and Customize sheet use: the
    /// "atria.today.ringMetrics" CSV and `ringCenterMetric` inside the
    /// AtriaHomeLayoutConfig JSON blob. The preview ring stays in the honest
    /// pre-data state (dashed learning bands, "--" center) — no sample numbers.
    private var ringsPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            ringsPreviewCard
            Text("Choose your rings")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick what the three rings track, and which one sits in the center. You can change this anytime from Customize Today.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(ringSlots.enumerated()), id: \.offset) { index, slot in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(ringSlotTint(slot))
                            .frame(width: 10, height: 10)
                            .accessibilityHidden(true)
                        Text(Self.ringPositionLabels[index])
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        Picker(Self.ringPositionLabels[index], selection: Binding(
                            get: { slot },
                            set: { assignRing($0, toPosition: index) }
                        )) {
                            ForEach(AtriaTriRingSlot.allCases, id: \.self) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .padding(16)
            .atriaCard(emphasis: .soft)

            VStack(alignment: .leading, spacing: 10) {
                Text("Center number")
                    .font(.subheadline.weight(.semibold))
                Picker("Center metric", selection: Binding(
                    get: { ringCenterMetric },
                    set: { setRingCenterMetric($0) }
                )) {
                    ForEach(AtriaHomeLayoutConfig.RingCenterMetric.allCases, id: \.self) { metric in
                        Text(ringCenterMetricLabel(metric)).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint("Selects the metric shown in the center of the ring")
            }
            .padding(16)
            .atriaCard(emphasis: .soft)
        }
        .onAppear {
            ringSlots = AtriaOnboardingPersonalization.loadRingSlots()
            ringCenterMetric = AtriaOnboardingPersonalization.loadRingCenterMetric()
        }
    }

    private var ringsPreviewCard: some View {
        AtriaTriRing(slots: ringSlots.map { slot in
                         // fill: nil is the learning sentinel — the preview shows
                         // the same honest dashed pre-data band the live Home ring
                         // uses before real nights arrive.
                         AtriaTriRingSlotContent(slot: slot,
                                                 metric: AtriaTriRingMetric(title: slot.label,
                                                                            value: "--",
                                                                            detail: "Preview",
                                                                            systemImage: ringSlotIcon(slot),
                                                                            tint: ringSlotTint(slot),
                                                                            fill: nil))
                     },
                     centerValue: "--",
                     centerState: ringCenterMetricLabel(ringCenterMetric),
                     accessibilitySummary: "Preview of your ring choices. Real numbers appear after your first night of wear.",
                     actions: [:])
            .frame(maxWidth: 240)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .atriaCard(emphasis: .soft)
    }

    /// P3 Cycle tracking opt-in. Toggle wired to the real AtriaCycleTracking
    /// enable flag through its canonical `setEnabled` path (default OFF), so
    /// enabling it here is exactly the same action Settings/Journal perform.
    private var cyclePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            onboardingGradientTile(systemImage: "calendar.circle.fill",
                                   colors: [Self.cycleHue.opacity(0.38),
                                            Color.red.opacity(0.22)])
            Text("Cycle tracking")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Text("Track your cycle alongside recovery. Your own store, kept separate from research sharing — always.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { cycleTrackingEnabled },
                    set: { setCycleTracking($0) }
                )) {
                    Label("Enable cycle tracking", systemImage: "calendar.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(Self.cycleHue)
                Text("Off by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .atriaCard(emphasis: .soft)

            DisclosureGroup {
                Text("Turn it on any time from Journal. Phase-aware notes are estimates, never a diagnosis, and never leave this phone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Label("How it works", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.secondary)
        }
        .onAppear {
            cycleTrackingEnabled = AtriaCycleTracking.isEnabled
        }
    }

    // MARK: - Slice 6 helpers

    private static let ringPositionLabels = ["Outer ring", "Middle ring", "Inner ring"]
    /// Design cycle hue #FF6482 (spec §0 · Cycle #FF6482). Kept local so this
    /// slice never edits the shared Metrics palette.
    private static let cycleHue = Color(red: 1.0, green: 0.392, blue: 0.51)

    private func onboardingGradientTile(systemImage: String, colors: [Color]) -> some View {
        RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 84, height: 84)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolRenderingMode(.hierarchical)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.tile, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private func assignRing(_ slot: AtriaTriRingSlot, toPosition position: Int) {
        let updated = AtriaOnboardingPersonalization.assign(slot, toPosition: position, in: ringSlots)
        ringSlots = updated
        AtriaOnboardingPersonalization.persistRingSlots(updated)
    }

    private func setRingCenterMetric(_ metric: AtriaHomeLayoutConfig.RingCenterMetric) {
        ringCenterMetric = metric
        AtriaOnboardingPersonalization.persistRingCenterMetric(metric)
    }

    private func setCycleTracking(_ enabled: Bool) {
        cycleTrackingEnabled = enabled
        AtriaCycleTracking.setEnabled(enabled)
    }

    private func ringCenterMetricLabel(_ metric: AtriaHomeLayoutConfig.RingCenterMetric) -> String {
        switch metric {
        case .recovery: return "Recovery"
        case .sleep: return "Sleep"
        case .strain: return "Strain"
        }
    }

    private func ringSlotTint(_ slot: AtriaTriRingSlot) -> Color {
        switch slot {
        case .sleep: return Metrics.electricSleep
        case .recovery: return Metrics.electricGreen
        case .strain: return Metrics.electricStrain
        case .hrv: return Metrics.electricHRV
        case .rhr: return Metrics.electricRHR
        }
    }

    private func ringSlotIcon(_ slot: AtriaTriRingSlot) -> String {
        switch slot {
        case .sleep: return "bed.double.fill"
        case .recovery: return "heart.fill"
        case .strain: return "flame.fill"
        case .hrv: return "waveform.path.ecg"
        case .rhr: return "heart.circle.fill"
        }
    }

    private var strapPage: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Image-led + minimal (2026-07-31, user: onboarding should be minimal
            // and image-first like the WHOOP reference screens, "not just texts").
            // The showcase already narrates setup (Meet / Charge / Wear / Pair) in
            // pictures, so the old redundant "Connect your strap" header + the
            // Charge/Close WHOOP/Tap tiles + the pairing wall-of-text are gone. Live
            // status stays visible; the exact pairing steps and the honest data-
            // handling details collapse behind one clearly-labeled tap — nothing is
            // hidden, just tidied out of the default view.
            StrapSetupShowcase()

            OnboardingConnectionStatusView(ble: ble)
            onboardingHistoryStatus

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Take the strap off, wait for its green sensor lights to stop, then tap the top repeatedly until the side light pulses blue. Close WHOOP first. Atria securely asks iPhone to pair — accept the system prompt, put the strap back on snugly, and keep it nearby. The strap stops its blue light when pairing finishes — Atria does not force the light off.")
                        .accessibilityLabel("Pairing instructions")
                    Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.summary)
                    Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.disclosure)
                    Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.interruptionDisclosure)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            } label: {
                Label("Pairing steps & how your data is handled",
                      systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.secondary)

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
            ("Sleep & recovery", [.sleep, .consistentBedtime, .nap, .melatonin, .magnesium,
                                  .sharedBed, .warmRoom, .screenInBed, .readBeforeBed, .sauna,
                                  .coldExposure, .massage, .stretching, .soreness]),
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
        ZStack {
            OnboardingMetricAccents()
            AtriaTriRing(slots: onboardingRingSlots,
                         centerValue: focusMetric.centerValue,
                         centerState: focusMetric.title,
                         accessibilitySummary: "Preview ring focused on \(focusMetric.title). Choose a focus below.",
                         actions: [
                            .sleep: { moveFocus(to: .sleep) },
                            .recovery: { moveFocus(to: .recovery) },
                            .strain: { moveFocus(to: .strain) }
                         ])
        }
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .atriaCard(emphasis: .soft)
    }

    private var onboardingRingSlots: [AtriaTriRingSlotContent] {
        [
            AtriaTriRingSlotContent(slot: .sleep, metric: onboardingMetric(.sleep)),
            AtriaTriRingSlotContent(slot: .recovery, metric: onboardingMetric(.recovery)),
            AtriaTriRingSlotContent(slot: .strain, metric: onboardingMetric(.strain))
        ]
    }

    private func onboardingMetric(_ metric: OnboardingFocusMetric) -> AtriaTriRingMetric {
        // `fill: nil` is the learning sentinel — the ring draws its dashed
        // pre-data band, identical to a genuinely fresh install's Home ring.
        AtriaTriRingMetric(title: metric.title,
                           value: metric.centerValue,
                           detail: metric.detail,
                           systemImage: metric.icon,
                           tint: metric.tint,
                           fill: nil)
    }

    private var expectationsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingHeader("Wear it tonight", systemImage: "moon.stars.fill", tint: .indigo)

            // A visible "what to expect" timeline (2026-07-30). The old page was
            // three compact pills whose useful copy ("Recovery begins after 3-4
            // nights") lived only in an invisible accessibilityHint, leaving the
            // page ~60% empty. Surfacing the sequence as a connected timeline sets
            // honest first-run expectations (numbers build over time) and fills the
            // space with meaningful, visual intel rather than blank margin.
            VStack(alignment: .leading, spacing: 0) {
                expectationStep(icon: "moon.fill",
                                tint: .indigo,
                                title: "Tonight",
                                detail: "Wear your strap to sleep — it captures your night automatically.")
                expectationStep(icon: "sunrise.fill",
                                tint: .orange,
                                title: "Tomorrow morning",
                                detail: "Your first sleep review is ready to confirm.")
                expectationStep(icon: "chart.line.uptrend.xyaxis",
                                tint: .green,
                                title: "After 3–4 nights",
                                detail: "Your recovery score kicks in as Atria learns your baseline.",
                                isLast: true)
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

    /// Image-led hero for the strap step (2026-07-30, user: onboarding should lead
    /// with a real strap image and feel more visual). Shows the strap photo once one
    /// is added to Assets.xcassets → AtriaStrapHero; until then a calm gradient panel
    /// with a wireless-sensor glyph keeps the page premium and never broken-looking.
    /// The slot is intentionally empty so dropping an image in Xcode is all it takes.
    @ViewBuilder
    private var strapHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.blue.opacity(0.14), Color.blue.opacity(0.04)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous)
                        .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                }

            if let strapImage = UIImage(named: "AtriaStrapHero") {
                Image(uiImage: strapImage)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .accessibilityLabel("Your Atria strap")
            } else if let strapIllustration = UIImage(named: "AtriaStrapHero3D") {
                Image(uiImage: strapIllustration)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .accessibilityLabel("Your Atria strap")
            } else {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 68, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 190)
    }

    /// Optional lifestyle art from the onboarding image handoff. It gives the
    /// introduction a warmer visual anchor while the sample ring stays the
    /// primary explanation of Atria's recovery, sleep, and strain model.
    @ViewBuilder
    private var onboardingLifestyleHero: some View {
        if let lifestyleImage = UIImage(named: "AtriaOnboardingLifestyle") {
            Image(uiImage: lifestyleImage)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero,
                                            style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
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

    private func expectationStep(icon: String,
                                 tint: Color,
                                 title: String,
                                 detail: String,
                                 isLast: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    Circle().fill(tint.opacity(0.15))
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .symbolRenderingMode(.hierarchical)
                }
                .frame(width: 44, height: 44)
                if !isLast {
                    // Greedy connector: fills the row's remaining height so it
                    // always reaches the next node regardless of detail wrap.
                    Rectangle()
                        .fill(tint.opacity(0.22))
                        .frame(width: 2)
                }
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 22)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}
