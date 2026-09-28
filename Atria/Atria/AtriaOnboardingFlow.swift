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
    private let reduceMotion: Bool
    @State private var appeared = false

    init(reduceMotion: Bool, @ViewBuilder content: () -> Content) {
        self.reduceMotion = reduceMotion
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
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .accessibilityLabel("Rotate setup view")
                    .accessibilityHint("Shows the next strap setup view")
                }
                .padding(16)
            }
            .frame(height: 226)
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero,
                                        style: .continuous))

            HStack(spacing: 0) {
                ForEach(Scene.allCases) { candidate in
                    Button {
                        select(candidate)
                    } label: {
                        Capsule()
                            .fill(candidate == scene ? Color.accentColor : Color.white.opacity(0.30))
                            .frame(width: candidate == scene ? 22 : 7, height: 7)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(candidate.title)
                    .accessibilityHint("Shows this strap setup view")
                    .accessibilityAddTraits(candidate == scene ? .isSelected : [])
                }
            }
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
/// First-run setup, reworked 2026-09-24 (owner: "easier, deterministic, non
/// sluggish, 100% success rate or clear classified error").
///
/// Four pages: welcome → strap → about you → tonight. Pages are an explicit
/// step switch, not a swipeable paged TabView: paging mounted every page (slow
/// first frame) and let a swipe skip the strap step, which then bounced the
/// user back from the last page. Ring layout, tracked behaviours and cycle
/// tracking keep their defaults and live in Customize / Journal / Settings.
/// The strap page renders `AtriaStrapSetup` verdicts: a four-row checklist
/// and, when something is wrong, one coded problem with the exact fix.
struct AtriaOnboardingFlow: View {
    @State private var draft: AthleteProfile
    let ble: AtriaBLEManager
    @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
    let onComplete: (AthleteProfile) -> Void
    let onAppReviewDemo: () -> Void
    let onRestoreBackup: ((URL) async -> Bool)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var step: Step = .welcome
    /// Held in @State (not @StateObject) so its 1 s verdicts re-render only
    /// the views that observe it, never the whole flow.
    @State private var strapSetup: AtriaStrapSetupCoordinator
    @State private var autoAdvanceScheduled = false
    @State private var nicknameDraft = ""
    @State private var backupImportPresented = false
    @State private var restoreMessage: String?
    @State private var restoreInProgress = false
    @State private var pairingHelpPresented = false
    /// Offered on About you: deleting the app erases its local history
    /// (2026-09-24: a reinstall wiped 38 + 692 sessions with no backup).
    @AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false

    private enum Step: Int, CaseIterable {
        case welcome
        case strap
        case you
        case tonight

        var isFirst: Bool { self == .welcome }
        var isLast: Bool { self == .tonight }

        init?(debugName: String?) {
            guard let debugName else { return nil }
            switch debugName.lowercased() {
            case "welcome", "what-this-is", "what", "hardware", "compatible", "signals": self = .welcome
            case "strap", "connect": self = .strap
            case "you", "profile", "nickname", "name", "you-name": self = .you
            // Pages folded out of onboarding land on the nearest remaining one.
            case "rings", "ring", "behaviors", "track", "tracking", "cycle", "womens-health", "cycle-tracking":
                self = .you
            case "expectations", "expect", "tomorrow", "tonight": self = .tonight
            default: return nil
            }
        }
    }

    private struct PrimaryActionButton: View {
        @ObservedObject var setup: AtriaStrapSetupCoordinator
        @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
        let step: Step
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                HStack(spacing: 8) {
                    if showsProgress {
                        ProgressView().controlSize(.small)
                    }
                    Text(title)
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
            }
            .controlSize(.large)
            .atriaCardAction(tint: step == .strap && !strapDone ? .blue : .green)
            .disabled(step == .strap && !strapActionAvailable)
            .accessibilityIdentifier("atria.onboarding.primary")
        }

        private var strapDone: Bool {
            setup.verdict.isReady || historyBootstrap.isSetupComplete
        }

        private var strapActionAvailable: Bool {
            strapDone || (setup.verdict.problem.map { $0.action != .wait } ?? false)
        }

        private var showsProgress: Bool {
            step == .strap && !strapDone && setup.verdict.problem == nil
        }

        private var title: String {
            switch step {
            case .welcome: return "Get started"
            case .strap:
                if strapDone { return "Continue" }
                switch setup.verdict.problem?.action {
                case .openSettings: return "Open Settings"
                case .retry: return "Try again"
                case .wait: return "Waiting for Bluetooth"
                case nil: return "Connecting…"
                }
            case .you: return "Continue"
            case .tonight:
                return historyBootstrap.isSetupComplete ? "Start using Atria" : "Finish strap setup"
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
                    guard historyBootstrap.isSetupComplete, !didComplete else { return }
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
         onAppReviewDemo: @escaping () -> Void = {},
         onComplete: @escaping (AthleteProfile) -> Void) {
        _draft = State(initialValue: profile)
        _step = State(initialValue: Step(debugName: debugInitialStep) ?? .welcome)
        _strapSetup = State(initialValue: AtriaStrapSetupCoordinator(ble: ble))
        self.ble = ble
        self.historyBootstrap = historyBootstrap
        self.onRestoreBackup = onRestoreBackup
        self.onAppReviewDemo = onAppReviewDemo
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaOnboardingBackdrop()
                    .ignoresSafeArea()

                currentPage
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .opacity))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !step.isFirst {
                        Button {
                            move(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                        .fontWeight(.semibold)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .fileImporter(isPresented: $backupImportPresented,
                          allowedContentTypes: backupArchiveTypes,
                          allowsMultipleSelection: false) { result in
                handleBackupImport(result)
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    progressDots
                    PrimaryActionButton(setup: strapSetup,
                                        historyBootstrap: historyBootstrap,
                                        step: step) {
                        primaryAction()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private var currentPage: some View {
        switch step {
        case .welcome: page { welcomePage(height: $0) }
        case .strap: page { strapPage(height: $0) }
        case .you: page { _ in youPage }
        case .tonight: page { _ in tonightPage }
        }
    }

    private func primaryAction() {
        dismissKeyboard()
        switch step {
        case .welcome:
            move(to: .strap)
        case .strap:
            if strapSetup.verdict.isReady || historyBootstrap.isSetupComplete {
                recordVerifiedStrap()
                if historyBootstrap.isSetupComplete { move(to: .you) }
                return
            }
            switch strapSetup.verdict.problem?.action {
            case .openSettings: openApplicationSettings()
            case .retry: strapSetup.retry()
            case .wait, nil: break
            }
        case .you:
            move(to: .tonight)
        case .tonight:
            if historyBootstrap.isSetupComplete {
                onComplete(draft)
            } else {
                move(to: .strap)
            }
        }
    }

    /// Setup proved this strap; bind completion to its identity. Called on the
    /// verdict edge and again on Continue, so a failed save can be retried.
    private func recordVerifiedStrap() {
        guard let identifier = ble.currentPeripheralIdentifier ?? ble.savedPeripheralIdentifier else { return }
        historyBootstrap.completeVerifiedSetup(peripheralIdentifier: identifier)
    }

    private func strapVerified() {
        recordVerifiedStrap()
        guard !autoAdvanceScheduled, historyBootstrap.isSetupComplete else { return }
        autoAdvanceScheduled = true
        Task { @MainActor in
            // A short beat so the finished checklist is seen, then move on.
            try? await Task.sleep(for: .seconds(1.2))
            if step == .strap { move(to: .you) }
        }
    }

    private func openApplicationSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func move(to next: Step) {
        dismissKeyboard()
        if reduceMotion {
            step = next
        } else {
            withAnimation(.snappy(duration: AtriaDesignTokens.Motion.emphatic)) { step = next }
        }
    }

    /// One screen per page (2026-09-24, owner: less scroll, more breathing
    /// room, use the screen). Pages get the visible height so their picture
    /// can size to it; the scroll view only moves when text is too large to
    /// fit (accessibility sizes) and does not bounce otherwise.
    private func page<Content: View>(@ViewBuilder content: @escaping (CGFloat) -> Content) -> some View {
        GeometryReader { proxy in
            ScrollView(showsIndicators: false) {
                OnboardingEntrance(reduceMotion: reduceMotion) {
                    VStack(alignment: .leading, spacing: 24) {
                        content(proxy.size.height)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    /// Picture height for a page: a share of the visible height, bounded so
    /// small phones keep room for text and large ones don't over-scale.
    private func visualHeight(_ available: CGFloat, share: CGFloat, minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? minimum : min(max(available * share, minimum), maximum)
    }

    // MARK: - Pages

    private func welcomePage(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            onboardingLifestyleHero(height: visualHeight(height, share: 0.5, minimum: 200, maximum: 430))
            VStack(alignment: .leading, spacing: 10) {
                Text("Your strap. Your data.")
                    .font(AtriaDesignTokens.Typography.pageTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHint("Sleep, recovery, and strain insights from your strap.")
                Text("Sleep, recovery and strain from your strap. Setup takes about a minute.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            welcomeLinks
        }
    }

    /// Quiet secondary paths, one line: explore without a strap, restore,
    /// or check which straps work.
    private var welcomeLinks: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(AtriaAppReviewDemo.exploreButtonTitle) {
                onAppReviewDemo()
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("atria.onboarding.explore-sample-data")
            .accessibilityHint("Loads local sample data with no account, password, strap, Bluetooth, or internet.")
            if onRestoreBackup != nil {
                restoreBackupRow
            }
            NavigationLink {
                AtriaCompatibleHardwareScreen()
            } label: {
                Text("Compatible hardware")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("atria.onboarding.hardware-signals")
        }
        .font(.subheadline.weight(.semibold))
        .tint(.secondary)
        .foregroundStyle(.secondary)
    }

    private var restoreBackupRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                backupImportPresented = true
            } label: {
                HStack(spacing: 8) {
                    if restoreInProgress {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(restoreInProgress ? "Restoring…" : "Restore a backup")
                }
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .disabled(restoreInProgress)
            if let restoreMessage {
                Text(restoreMessage)
                    .font(.footnote.weight(.semibold))
            }
        }
    }

    private func strapPage(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connect your strap")
                .font(AtriaDesignTokens.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
            StrapSetupPanel(setup: strapSetup,
                            historyBootstrap: historyBootstrap,
                            sceneHeight: visualHeight(height, share: 0.42, minimum: 180, maximum: 380),
                            onReady: strapVerified,
                            onHelp: { pairingHelpPresented = true })
            ConnectedDebugObserver(ble: ble,
                                   historyBootstrap: historyBootstrap) {
                onComplete(draft)
            }
        }
        .sheet(isPresented: $pairingHelpPresented) {
            PairingHelpSheet()
                .presentationDetents([.medium, .large])
        }
    }

    /// About you: name plus the two fields heart-rate zones need. Height and
    /// weight stay optional; blank means unset.
    private var youPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            onboardingHeader("About you", systemImage: "person.crop.circle.fill", tint: .purple)
            VStack(alignment: .leading, spacing: 12) {
                profileFieldLayout(title: "Name", suffix: "") {
                    TextField("Name", text: $nicknameDraft, prompt: Text("Optional"))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 88, idealWidth: 140, maxWidth: 180)
                        .frame(minHeight: 44)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { dismissKeyboard() }
                        .onChange(of: nicknameDraft) { _, newValue in
                            AtriaOnboardingPersonalization.persistNickname(newValue)
                        }
                }
                numericProfileField("Age", value: ageBinding, suffix: "years")
                Picker("Sex", selection: $draft.biologicalSex) {
                    ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                        Text(sex.label).tag(sex)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                optionalNumericProfileField("Height", value: heightBinding, suffix: "cm")
                optionalNumericProfileField("Weight", value: weightBinding, suffix: "kg")
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            Toggle(isOn: $iCloudBackupEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Back up to iCloud Drive", systemImage: "icloud.and.arrow.up")
                        .font(.body.weight(.semibold))
                    Text("Keeps your history if you delete the app or change phones.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .atriaCard(emphasis: .soft)

            Text("Age and sex set heart-rate zones. Everything else is optional.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            nicknameDraft = AtriaOnboardingPersonalization.loadNickname()
        }
    }

    private var tonightPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            onboardingHeader("Wear it tonight", systemImage: "moon.stars.fill", tint: .indigo)
            VStack(alignment: .leading, spacing: 0) {
                expectationStep(icon: "moon.fill",
                                tint: .indigo,
                                title: "Tonight",
                                detail: "Sleep with the strap on.")
                expectationStep(icon: "sunrise.fill",
                                tint: .orange,
                                title: "Tomorrow morning",
                                detail: "Your first sleep review to confirm, and a first recovery score.")
                expectationStep(icon: "chart.line.uptrend.xyaxis",
                                tint: .green,
                                title: "Over the first two weeks",
                                detail: "Scores firm up as Atria learns your baseline.",
                                isLast: true)
            }
            .padding(20)
            .atriaCard(emphasis: .soft)
            Text("Rings, journal and cycle tracking can be set up anytime in Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

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

    private func onboardingHeader(_ title: String,
                                  systemImage: String,
                                  tint: Color) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 40)
                .accessibilityHidden(true)
            Text(title)
                .font(AtriaDesignTokens.Typography.pageTitle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func onboardingLifestyleHero(height: CGFloat) -> some View {
        if let lifestyleImage = UIImage(named: "AtriaOnboardingLifestyle") {
            // Color.clear takes the page width exactly; a bare aspect-fill
            // image reports its overflow width and pushes text off-screen.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .overlay {
                    Image(uiImage: lifestyleImage)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
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

    /// Height and weight are optional, and the model treats 0 as "unset". The
    /// field is empty when unset, with "Optional" as its prompt, so skipping
    /// it looks like skipping it (never "0 cm").
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
                    if !suffix.isEmpty {
                        Text(suffix)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                Text(title)
                Spacer(minLength: 8)
                editor()
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 44)
        }
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

/// The strap step's live panel (2026-09-24 visual rebuild): one full-width
/// picture of what to do now, one instruction in large type on it, a
/// four-step rail, and — only when something is wrong — the coded fix.
/// Observes only the setup coordinator, so a verdict change re-renders this
/// panel and nothing else.
private struct StrapSetupPanel: View {
    @ObservedObject var setup: AtriaStrapSetupCoordinator
    @ObservedObject var historyBootstrap: AtriaOnboardingHistoryBootstrap
    let sceneHeight: CGFloat
    let onReady: () -> Void
    let onHelp: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var verdict: AtriaStrapSetup.Verdict { setup.verdict }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            sceneCard
            stepRail
            if let problem = verdict.problem {
                problemCard(problem)
            }
            if let warning = verdict.batteryWarning {
                Label(warning, systemImage: "battery.25percent")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            if historyBootstrap.snapshot.phase == .failed {
                Label(historyBootstrap.snapshot.detail, systemImage: "externaldrive.badge.exclamationmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: onHelp) {
                Label("Pairing help", systemImage: "questionmark.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .tint(.secondary)
            .frame(minHeight: 44)
        }
        .animation(reduceMotion ? nil : .snappy(duration: AtriaDesignTokens.Motion.standard), value: verdict)
        .onAppear {
            setup.start()
            if verdict.isReady { onReady() }
        }
        .onDisappear { setup.stop() }
        .onChange(of: verdict.isReady) { _, ready in
            if ready { onReady() }
        }
    }

    // MARK: Scene

    private var sceneCard: some View {
        ZStack(alignment: .bottomLeading) {
            sceneArtwork
                .id(verdict.scene)
                .transition(.opacity)
            LinearGradient(colors: [.clear, Color.black.opacity(0.78)],
                           startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 6) {
                if let bpm = verdict.heartRate, verdict.isReady {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.title2)
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
                        Text("\(bpm)")
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Text("bpm")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(bpm) beats per minute")
                } else {
                    Text(verdict.headline)
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !verdict.detail.isEmpty {
                    Text(verdict.detail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .frame(height: sceneHeight)
        .background(Color(red: 0.03, green: 0.05, blue: 0.10))
        .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.hero, style: .continuous)
                .stroke(verdict.problem == nil ? Color.white.opacity(0.14) : Color.orange.opacity(0.7),
                        lineWidth: verdict.problem == nil ? 1 : 2)
        }
    }

    @ViewBuilder
    private var sceneArtwork: some View {
        switch verdict.scene {
        case .bluetooth:
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.08, blue: 0.16),
                                        Color(red: 0.02, green: 0.03, blue: 0.07)],
                               startPoint: .top, endPoint: .bottom)
                Image(systemName: verdict.problem == nil
                      ? "antenna.radiowaves.left.and.right"
                      : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .symbolRenderingMode(.hierarchical)
                    .offset(y: -sceneHeight * 0.12)
            }
        case .pair, .wear, .charge:
            Color.clear
                .overlay {
                    Image(sceneImageName)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
                .accessibilityHidden(true)
        }
    }

    private var sceneImageName: String {
        switch verdict.scene {
        case .wear: return "AtriaSetupWearScene"
        case .charge: return "AtriaSetupChargeScene"
        case .pair, .bluetooth: return "AtriaSetupPairScene"
        }
    }

    // MARK: Step rail

    private var stepRail: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(AtriaStrapSetup.Step.allCases, id: \.rawValue) { item in
                VStack(spacing: 6) {
                    indicator(verdict.state(item))
                        .frame(width: 26, height: 26)
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(verdict.state(item) == .waiting ? .secondary : .primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityValue(accessibilityValue(verdict.state(item)))
            }
        }
    }

    @ViewBuilder
    private func indicator(_ state: AtriaStrapSetup.StepState) -> some View {
        switch state {
        case .waiting:
            Circle()
                .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                .frame(width: 20, height: 20)
        case .working:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
        case .problem:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        }
    }

    private func accessibilityValue(_ state: AtriaStrapSetup.StepState) -> String {
        switch state {
        case .waiting: return "Not started"
        case .working: return "In progress"
        case .done: return "Done"
        case .problem: return "Needs attention"
        }
    }

    // MARK: Problem

    private func problemCard(_ problem: AtriaStrapSetup.Problem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(problem.steps.enumerated()), id: \.offset) { index, text in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.orange))
                    Text(text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Code \(problem.code)")
                .font(.caption2.weight(.semibold))
                .monospaced()
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
    }
}

/// Everything about pairing in one place, out of the way of the main flow:
/// the illustrated steps and the honest data-handling notes.
private struct PairingHelpSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StrapSetupShowcase()
                    Group {
                        Text("\(AtriaStrapSetup.Problem.pairingMode) Tap Pair when iPhone asks.")
                        Text("Paired with another phone or the WHOOP app before? Forget it there first, and on this iPhone in Settings → Bluetooth.")
                        Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.summary)
                        Text(AtriaOnboardingHistoryBootstrapPolicy.FreshStartPolicy.interruptionDisclosure)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle("Pairing help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
