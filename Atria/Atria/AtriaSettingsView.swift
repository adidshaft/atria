import SwiftUI
import UniformTypeIdentifiers

/// Coalesces high-frequency profile controls (notably Stepper repeats) into one
/// durable store update. `flush` is called by every navigation/dismiss boundary,
/// so a quick back-swipe cannot lose the final value.
@MainActor
final class AtriaProfileDraftPersistenceCoordinator {
    private let delay: Duration
    private let persist: (AthleteProfile) -> Void
    private var committedProfile: AthleteProfile
    private var pendingProfile: AthleteProfile?
    private var persistenceTask: Task<Void, Never>?

    init(initialProfile: AthleteProfile,
         delay: Duration = .milliseconds(450),
         persist: @escaping (AthleteProfile) -> Void) {
        committedProfile = initialProfile
        self.delay = delay
        self.persist = persist
    }

    func schedule(_ profile: AthleteProfile) {
        persistenceTask?.cancel()
        persistenceTask = nil

        guard profile != committedProfile else {
            pendingProfile = nil
            return
        }

        pendingProfile = profile
        persistenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            commitPending()
        }
    }

    /// Returns a source-of-truth profile that the editor should adopt. Echoes
    /// from our own persisted edit are ignored, avoiding a write-back loop.
    func synchronizeFromSource(_ profile: AthleteProfile) -> AthleteProfile? {
        guard profile != committedProfile else { return nil }
        persistenceTask?.cancel()
        persistenceTask = nil
        pendingProfile = nil
        committedProfile = profile
        return profile
    }

    func flush(_ profile: AthleteProfile? = nil) {
        if let profile, profile != committedProfile {
            pendingProfile = profile
        }
        persistenceTask?.cancel()
        persistenceTask = nil
        commitPending()
    }

    private func commitPending() {
        guard let pendingProfile, pendingProfile != committedProfile else {
            self.pendingProfile = nil
            return
        }
        self.pendingProfile = nil
        committedProfile = pendingProfile
        persist(pendingProfile)
    }
}

/// Honest acknowledgement for the manual history button. The BLE request API
/// reports whether a transfer actually started; Settings must not replace a
/// rejected/deferred request with a timed, fabricated "Syncing…" spinner.
enum AtriaManualHistorySyncFeedback: Equatable {
    case started
    case notStarted

    var title: String {
        switch self {
        case .started: return "Strap history sync started"
        case .notStarted: return "No history sync started"
        }
    }

    var detail: String {
        switch self {
        case .started:
            return "Atria accepted the transfer request. The data-gap status will update from durable rows."
        case .notStarted:
            return "The strap did not start a compatible recovery transfer. Live tracking continues."
        }
    }
}

/// Native iOS 26 settings hub. Uses a grouped Form and folds in the
/// community-requested differentiators (no subscription, data ownership/export,
/// custom HR-zone & strain alerts).
struct AtriaSettingsView: View {
    /// One user-facing boundary for local storage ownership. The backup and raw
    /// export paths preserve durable session evidence and summaries; short-lived
    /// derived timelines remain display state rather than a second health archive.
    private enum DataCopy {
        static let storageDisclosure = "Saved sensor sessions and health summaries can be backed up or exported. The local two-day Stress display cache is excluded from both."
    }

    private enum BackupFeedbackTone {
        case neutral
        case success
        case failure

        var tint: Color {
            switch self {
            case .neutral: .secondary
            case .success: .green
            case .failure: .red
            }
        }

        var systemImage: String {
            switch self {
            case .neutral: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .failure: "exclamationmark.triangle.fill"
            }
        }
    }

    private enum Destination: String, CaseIterable, Hashable, Identifiable {
        case personal
        case strap
        case alerts
        case data
        case privacy
        case developer

        var id: Self { self }

        var title: String {
            switch self {
            case .personal: "Personal"
            case .strap: "Strap"
            case .alerts: "Alerts"
            case .data: "Data"
            case .privacy: "Privacy & About"
            case .developer: "Developer"
            }
        }

        var systemImage: String {
            switch self {
            case .personal: "person.crop.circle.fill"
            case .strap: "antenna.radiowaves.left.and.right.circle.fill"
            case .alerts: "bell.badge.fill"
            case .data: "internaldrive.fill"
            case .privacy: "hand.raised.fill"
            case .developer: "hammer.fill"
            }
        }

        var tint: Color {
            switch self {
            case .personal: .pink
            case .strap: .cyan
            case .alerts: .orange
            case .data: .blue
            case .privacy: .green
            case .developer: .secondary
            }
        }

        var accessibilityHint: String {
            switch self {
            case .personal: "Daily goals, profile, appearance, and Today layout"
            case .strap: "Device, radio mode, broadcast, and sensor support"
            case .alerts: "Haptic and notification preferences"
            case .data: "Backup, Apple Health, strap sync, and storage"
            case .privacy: "Research sharing, previews, version, and support"
            case .developer: "Research and validation tools"
            }
        }
    }

    let profile: AthleteProfile
    let restingBaseline: Int?
    /// Real weekly recovery average for the leaderboard "You" row (nil while
    /// still learning). Demo social feature (2026-07-08).
    let strapName: String
    let strapModel: String
    let strapGenerationDetail: String
    let strapFirmware: String
    let onRenameStrap: (String) -> Void
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    let hapticSettings: AtriaHapticAlertSettings
    let onUpdateHaptics: (AtriaHapticAlertSettings) -> Void
    let heartRateBroadcastEnabled: Bool
    let onUpdateHeartRateBroadcast: (Bool) -> Void
    let batterySaverEnabled: Bool
    let onUpdateBatterySaver: (Bool) -> Void
    let onCustomizeToday: (() -> Void)?
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onUpdateAICoachSettings: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let maxHRSuggestion: AtriaMaxHRSuggestion?
    let onDismissMaxHRSuggestion: (Int) -> Void
    let onExportHealth: (() -> Void)?
    /// A consent-gated bundle for manual or queued sharing.
    var buildResearchBundle: () async -> AtriaResearchBundleBuilder.Built? = { nil }
    /// A local-only bundle used to inspect the disclosure before consent.
    var buildResearchPreview: () async -> AtriaResearchBundleBuilder.Built? = { nil }
    let onSyncMissedData: (() -> Bool)?
    /// "Catch up faster" boost: true when the drain is hours behind and the
    /// higher-cadence Coverage profile would help sync sooner. Offers a one-tap
    /// enable; it auto-reverts once the strap catches up.
    let catchUpBoostSuggested: Bool
    /// True while the boost is currently engaged (shows the on-state + a way to
    /// turn it off early).
    let catchUpBoostActive: Bool
    /// Short "how far behind" hint for the CTA subtitle, e.g. "~6h behind".
    let catchUpBehindText: String?
    /// Turn the boost on (true) or off (false). Nil hides the control entirely.
    let onSetCatchUpBoost: ((Bool) -> Void)?
    let onNutritionHealthToggle: (() -> Void)?
    let backupStatusProvider: () -> SessionBackupStatus
    /// Starts a required backup on the store's serial utility worker. The
    /// completion is MainActor-isolated so Settings only performs the small UI
    /// state commit after encoding, compression and file I/O have finished.
    let onWriteBackup: ((@escaping @MainActor (SessionBackupStatus) -> Void) -> Void)?
    let onVerifyBackup: (() async -> SessionBackupStatus)?
    let onRestoreBackup: ((URL) async -> SessionBackupStatus?)?
    let onForgetStrap: (() -> Void)?
    /// The developer validation surface is intentionally a factory. Building
    /// its large observation graph while the Settings sheet is animating can
    /// miss the scene watchdog on a device with a live strap stream.
    let researchValidationContent: (() -> AnyView)?
    let onExitDeveloperMode: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showForgetConfirm = false
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings
    @State private var nameDraft: String
    @State private var heartRateBroadcast: Bool
    @State private var batterySaver: Bool
    @State private var coachSettings: AtriaAICoachSettings
    @State private var coachHasAPIKey: Bool
    @State private var coachAPIKeyDraft = ""
    @State private var exportTapped = false
    @State private var historySyncFeedback: AtriaManualHistorySyncFeedback?
    /// Local echo of the catch-up boost after a tap, so the row confirms the
    /// action immediately (the injected state is a snapshot from screen open).
    @State private var catchUpBoostLocalOn: Bool?
    @State private var backupStatus: SessionBackupStatus
    @State private var backupImportPresented = false
    @State private var backupActionMessage: String?
    @State private var backupFeedbackTone = BackupFeedbackTone.neutral
    @State private var backupOperationInProgress = false
    @State private var didLoadBackupStatus = false
    @State private var storageFootprintTotal: String?
    /// Seeded from a launch argument in DEBUG so each settings subpage can be
    /// screenshot-verified. Every destination is otherwise reachable only by
    /// tapping a hub row, and simctl can capture but not tap -- so with the
    /// simulator panel unavailable the six subpages were the last surfaces in
    /// the app that could not be looked at.
    ///
    /// This only pushes onto the EXISTING path; it adds no new NavigationLink
    /// specialisation. That matters here: this hub deliberately uses one
    /// concrete row type in a single ForEach, because several specialised
    /// NavigationLink expressions previously caused an on-device
    /// swift_getTypeByMangledName metadata stack overflow.
    @State private var navigationPath: NavigationPath = {
        #if DEBUG
        if let destination = Self.debugInitialDestination(
            arguments: ProcessInfo.processInfo.arguments
        ) {
            var path = NavigationPath()
            path.append(destination)
            return path
        }
        #endif
        return NavigationPath()
    }()

    #if DEBUG
    private static func debugInitialDestination(arguments: [String]) -> Destination? {
        guard let index = arguments.firstIndex(of: "--atria-settings-destination"),
              arguments.indices.contains(arguments.index(after: index)) else { return nil }
        return Destination(rawValue: arguments[arguments.index(after: index)])
    }
    #endif
    @State private var profilePersistence: AtriaProfileDraftPersistenceCoordinator

    /// Support destinations are shown as text only. Atria's core stays local-first
    /// with no in-app network/browser clients, so contact details are surfaced for
    /// the user to open themselves rather than launched in-app.
    private let supportHandle = "@adidshaft on X"

    init(profile: AthleteProfile,
         restingBaseline: Int?,
         strapName: String = "",
         strapModel: String = "",
         strapGenerationDetail: String = "",
         strapFirmware: String = "",
         onRenameStrap: @escaping (String) -> Void = { _ in },
         onUpdateProfile: @escaping (@escaping (inout AthleteProfile) -> Void) -> Void,
         hapticSettings: AtriaHapticAlertSettings,
         onUpdateHaptics: @escaping (AtriaHapticAlertSettings) -> Void,
         heartRateBroadcastEnabled: Bool = false,
         onUpdateHeartRateBroadcast: @escaping (Bool) -> Void = { _ in },
         batterySaverEnabled: Bool,
         onUpdateBatterySaver: @escaping (Bool) -> Void,
         onCustomizeToday: (() -> Void)? = nil,
         aiCoachSettings: AtriaAICoachSettings = AtriaAICoachSettings(),
         aiCoachHasAPIKey: Bool = false,
         onUpdateAICoachSettings: @escaping (AtriaAICoachSettings) -> Void = { _ in },
         onSaveAICoachAPIKey: @escaping (String) -> Void = { _ in },
         onDeleteAICoachAPIKey: @escaping () -> Void = {},
         maxHRSuggestion: AtriaMaxHRSuggestion? = nil,
         onDismissMaxHRSuggestion: @escaping (Int) -> Void = { _ in },
         onExportHealth: (() -> Void)? = nil,
         buildResearchBundle: @escaping () async -> AtriaResearchBundleBuilder.Built? = { nil },
         buildResearchPreview: @escaping () async -> AtriaResearchBundleBuilder.Built? = { nil },
         onSyncMissedData: (() -> Bool)? = nil,
         catchUpBoostSuggested: Bool = false,
         catchUpBoostActive: Bool = false,
         catchUpBehindText: String? = nil,
         onSetCatchUpBoost: ((Bool) -> Void)? = nil,
         onNutritionHealthToggle: (() -> Void)? = nil,
         backupStatusProvider: @escaping () -> SessionBackupStatus = { .missing },
         onWriteBackup: ((@escaping @MainActor (SessionBackupStatus) -> Void) -> Void)? = nil,
         onVerifyBackup: (() async -> SessionBackupStatus)? = nil,
         onRestoreBackup: ((URL) async -> SessionBackupStatus?)? = nil,
         onForgetStrap: (() -> Void)? = nil,
         researchValidationContent: (() -> AnyView)? = nil,
         onExitDeveloperMode: @escaping () -> Void = {}) {
        self.profile = profile
        self.restingBaseline = restingBaseline
        self.strapName = strapName
        self.strapModel = strapModel
        self.strapGenerationDetail = strapGenerationDetail
        self.strapFirmware = strapFirmware
        self.onRenameStrap = onRenameStrap
        self.onUpdateProfile = onUpdateProfile
        self.hapticSettings = hapticSettings
        self.onUpdateHaptics = onUpdateHaptics
        self.heartRateBroadcastEnabled = heartRateBroadcastEnabled
        self.onUpdateHeartRateBroadcast = onUpdateHeartRateBroadcast
        self.batterySaverEnabled = batterySaverEnabled
        self.onUpdateBatterySaver = onUpdateBatterySaver
        self.onCustomizeToday = onCustomizeToday
        self.aiCoachSettings = aiCoachSettings
        self.aiCoachHasAPIKey = aiCoachHasAPIKey
        self.onUpdateAICoachSettings = onUpdateAICoachSettings
        self.onSaveAICoachAPIKey = onSaveAICoachAPIKey
        self.onDeleteAICoachAPIKey = onDeleteAICoachAPIKey
        self.maxHRSuggestion = maxHRSuggestion
        self.onDismissMaxHRSuggestion = onDismissMaxHRSuggestion
        self.onExportHealth = onExportHealth
        self.buildResearchBundle = buildResearchBundle
        self.buildResearchPreview = buildResearchPreview
        self.onSyncMissedData = onSyncMissedData
        self.catchUpBoostSuggested = catchUpBoostSuggested
        self.catchUpBoostActive = catchUpBoostActive
        self.catchUpBehindText = catchUpBehindText
        self.onSetCatchUpBoost = onSetCatchUpBoost
        self.onNutritionHealthToggle = onNutritionHealthToggle
        self.backupStatusProvider = backupStatusProvider
        self.onWriteBackup = onWriteBackup
        self.onVerifyBackup = onVerifyBackup
        self.onRestoreBackup = onRestoreBackup
        self.onForgetStrap = onForgetStrap
        self.researchValidationContent = researchValidationContent
        self.onExitDeveloperMode = onExitDeveloperMode
        _draft = State(initialValue: profile)
        _haptics = State(initialValue: hapticSettings)
        _nameDraft = State(initialValue: strapName)
        _heartRateBroadcast = State(initialValue: heartRateBroadcastEnabled)
        _batterySaver = State(initialValue: batterySaverEnabled)
        _coachSettings = State(initialValue: aiCoachSettings)
        _coachHasAPIKey = State(initialValue: aiCoachHasAPIKey)
        _profilePersistence = State(initialValue: AtriaProfileDraftPersistenceCoordinator(
            initialProfile: profile,
            persist: { profile in
                onUpdateProfile { $0 = profile }
            }
        ))
        // Never ask the session store for backup state while SwiftUI is trying
        // to commit the sheet's first frame. The provider is cached today, but
        // this boundary keeps future backup validation/file work from silently
        // regressing the Settings gear into a watchdog hang.
        _backupStatus = State(initialValue: .missing)
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Form {
                if debugPrioritizesDeviceSection {
                    strapSettingsContent
                }
                if debugPrioritizesDataSection {
                    AtriaDataSettingsDefaultsScope(onNutritionHealthToggle: onNutritionHealthToggle) {
                        iCloudBackupEnabled,
                        useHealthNutrition in
                        dataSection(iCloudBackupEnabled: iCloudBackupEnabled,
                                    useHealthNutrition: useHealthNutrition)
                    }
                }
                settingsHub
            }
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        profilePersistence.flush(draft)
                        dismiss()
                    }
                        .font(.body.weight(.semibold))
                }
            }
            // Value navigation keeps all destination view graphs out of the
            // first presentation frame. The AnyView boundary below is
            // intentional: without it, this closure's opaque return type joins
            // six large Form graphs into one deeply nested generic metadata
            // tree. Device hang reports showed the main thread spending seconds
            // in swift_getTypeByMangledName while the Settings sheet appeared.
            // A destination changes only after a user tap, so type erasure here
            // is a much smaller cost than instantiating that tree on every open.
            .navigationDestination(for: Destination.self) { destination in
                destinationPage(for: destination)
            }
        }
        .onChange(of: draft) { _, value in profilePersistence.schedule(value) }
        // Keep the editable form in sync with the source of truth. Without this,
        // `draft` was seeded once at init; if the stored profile changed after
        // the sheet appeared (e.g. it finished loading, or a measured max-HR
        // landed), the form kept showing the stale/default values — reading as
        // "my details never saved". The guard avoids a redundant write-back loop
        // (the user's own edits already made profile == draft).
        .onChange(of: profile) { _, newValue in
            if let sourceProfile = profilePersistence.synchronizeFromSource(newValue),
               sourceProfile != draft {
                draft = sourceProfile
            }
        }
        .onChange(of: haptics) { _, value in onUpdateHaptics(value) }
        .onChange(of: heartRateBroadcast) { _, value in onUpdateHeartRateBroadcast(value) }
        .onChange(of: batterySaver) { _, value in onUpdateBatterySaver(value) }
        .onChange(of: aiCoachSettings) { _, value in
            if value != coachSettings { coachSettings = value }
        }
        .onChange(of: aiCoachHasAPIKey) { _, value in coachHasAPIKey = value }
        .onDisappear { profilePersistence.flush(draft) }
        .fileImporter(isPresented: $backupImportPresented,
                      allowedContentTypes: backupArchiveTypes,
                      allowsMultipleSelection: false) { result in
            handleBackupImport(result)
        }
    }

    // MARK: Settings hub
    //
    // Keep the first screen to five plain-language destinations. Each one owns
    // a native grouped Form, so opening Strap or Data no longer expands several
    // nested sections into one long, spatially unstable settings wall.

    /// The hub used to be five bare titles stacked in the top third of a full
    /// sheet, leaving most of the screen blank and giving no clue what any row
    /// held. The plain-language summary that already existed as a VoiceOver
    /// hint is now visible text, so the row earns its height and the screen
    /// carries information instead of whitespace. Sighted and VoiceOver users
    /// read the same sentence — `.combine` merges title + summary into one
    /// element, which is why the separate hint modifier is gone.
    private func settingsGroupLabel(_ destination: Destination) -> some View {
        HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(destination.tint)
                .frame(width: 26, height: 26)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: destination.tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                    .font(.subheadline.weight(.semibold))
                Text(destination.accessibilityHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
    }

    /// A single concrete row type is deliberate here. Six independently
    /// specialized `NavigationLink` expressions made Swift's runtime recurse
    /// through an enormous mangled generic type while presenting this sheet on
    /// device (EXC_BAD_ACCESS in `swift_getTypeByMangledName`). Keeping one
    /// `ForEach` specialization prevents that metadata stack overflow.
    private var settingsHub: some View {
        Section {
            ForEach(visibleDestinations) { destination in
                NavigationLink(value: destination) {
                    settingsGroupLabel(destination)
                }
            }
        }
    }

    private var visibleDestinations: [Destination] {
        Destination.allCases.filter { destination in
            destination != .developer
                || researchValidationContent != nil
        }
    }

    /// A low-frequency navigation boundary that caps Swift runtime metadata
    /// work. The switch evaluates only the selected branch, so unopened Forms,
    /// defaults observers, and developer validation content remain lazy.
    private func destinationPage(for destination: Destination) -> AnyView {
        switch destination {
        case .personal:
            return AnyView(personalSettingsPage)
        case .strap:
            return AnyView(strapSettingsPage)
        case .alerts:
            return AnyView(alertsSettingsPage)
        case .data:
            return AnyView(dataSettingsPage)
        case .privacy:
            return AnyView(privacySettingsPage)
        case .developer:
            return AnyView(developerSettingsPage)
        }
    }

    private var personalSettingsPage: some View {
        AtriaPersonalSettingsDefaultsScope { appearanceMode,
                                             faceOffDisplayName,
                                             todayHiddenCSV,
                                             todayOrderCSV,
                                             todaySizeCSV in
            compactSettingsForm(title: "Personal") {
                AtriaDailyGoalsSection()
                todayLayoutSection(todayHiddenCSV: todayHiddenCSV,
                                   todayOrderCSV: todayOrderCSV,
                                   todaySizeCSV: todaySizeCSV)
                profileSection(faceOffDisplayName: faceOffDisplayName)
                appearanceSection(appearanceMode: appearanceMode)
                AtriaRingLayoutSection()
                Section {
                    NavigationLink {
                        coachSettingsPage
                    } label: {
                        Label("Coach", systemImage: "brain.head.profile")
                    }
                    .accessibilityHint("Choose on-device or cloud summaries and manage cloud access")

                    NavigationLink {
                        AtriaAdvancedTargetsSettingsView()
                    } label: {
                        Label("Advanced targets", systemImage: "scope")
                    }
                    .accessibilityHint("Customize recovery, strain, sleep, and health metric ranges")

                    NavigationLink {
                        AtriaTrackedBehaviorsSettingsView()
                    } label: {
                        Label("Journal behaviors", systemImage: "checklist")
                    }
                    .accessibilityHint("Choose which behaviors appear in your morning check-in")
                }
            }
            .onDisappear { profilePersistence.flush(draft) }
        }
    }

    private var coachSettingsPage: some View {
        compactSettingsForm(title: "Coach") {
            Section {
                Picker("Mode", selection: coachModeBinding) {
                    Text("Off").tag(AtriaAICoachSettings.Mode.off)
                    Text("On-device").tag(AtriaAICoachSettings.Mode.local)
                    Text("Cloud").tag(AtriaAICoachSettings.Mode.cloud)
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Answers")
            } footer: {
                Text(coachModeFooter)
            }

            if coachSettings.mode == .cloud {
                Section {
                    Picker("Service", selection: coachProviderBinding) {
                        ForEach(AtriaAICoachSettings.CloudProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }

                    SecureField(coachHasAPIKey ? "Replace saved API key" : "API key",
                                text: $coachAPIKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()

                    Button("Save API key") {
                        let key = coachAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return }
                        onSaveAICoachAPIKey(key)
                        coachAPIKeyDraft = ""
                        coachHasAPIKey = true
                    }
                    .disabled(coachAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if coachHasAPIKey {
                        Button("Remove API key", role: .destructive) {
                            coachAPIKeyDraft = ""
                            onDeleteAICoachAPIKey()
                            coachHasAPIKey = false
                        }
                    }
                } header: {
                    Text("Cloud service")
                } footer: {
                    Text("The key stays in this iPhone's Keychain. Cloud requests are disabled until Atria's reviewed service client is available.")
                }
            }

            Section {
                LabeledContent("Health data", value: "Only answer inputs")
                LabeledContent("Network", value: coachNetworkLabel)
                LabeledContent("Source check", value: "Available per answer")
            } header: {
                Text("Privacy")
            }
        }
    }

    private var coachModeBinding: Binding<AtriaAICoachSettings.Mode> {
        Binding(
            get: { coachSettings.mode },
            set: { mode in
                coachSettings.mode = mode
                onUpdateAICoachSettings(coachSettings)
            }
        )
    }

    private var coachProviderBinding: Binding<AtriaAICoachSettings.CloudProvider> {
        Binding(
            get: { coachSettings.cloudProvider },
            set: { provider in
                coachSettings.cloudProvider = provider
                coachHasAPIKey = false
                coachAPIKeyDraft = ""
                onUpdateAICoachSettings(coachSettings)
            }
        )
    }

    private var coachModeFooter: String {
        switch coachSettings.mode {
        case .off: return "Quick Assistant questions still use Atria's own calculations."
        case .local: return "Coach summaries run on this iPhone."
        case .cloud: return "Cloud setup is managed here, away from your daily health view."
        }
    }

    private var coachNetworkLabel: String {
        switch coachSettings.mode {
        case .off: return "Off"
        case .local: return "None"
        case .cloud: return "Not yet enabled"
        }
    }

    private var strapSettingsPage: some View {
        compactSettingsForm(title: "Strap") {
            strapSettingsContent
        }
    }

    @ViewBuilder
    private var strapSettingsContent: some View {
        radioModeSection
        // The all-day motion default is destination-only: its observer lives
        // in a scope on the Strap page, never on the Settings hub frame.
        AtriaStrapMotionDefaultsScope { allDayMotionEnabled in
            allDayMotionSection(allDayMotionEnabled: allDayMotionEnabled)
        }
        heartRateBroadcastSection
        deviceSection
        sensorAvailabilitySection
    }

    private func allDayMotionSection(allDayMotionEnabled: Binding<Bool>) -> some View {
        let isEnabled = allDayMotionEnabled.wrappedValue
        return Section {
            Toggle(isOn: allDayMotionEnabled) {
                Label("All-day step capture", systemImage: "figure.walk.motion")
            }
            .accessibilityHint("Uses more strap battery. Pauses automatically when the strap battery is low.")
            settingsInfoRow(icon: isEnabled ? "battery.75percent" : "figure.run",
                            tint: isEnabled ? .green : .secondary,
                            title: isEnabled ? "Dense motion all day" : "Workouts only",
                            detail: isEnabled
                                ? "Keeps the strap's dense motion stream on between workouts so movement is captured all day. Pauses below 25% strap battery and resumes when charging or recovered. Workouts always take priority."
                                : "The dense motion stream runs only during workouts and step calibration.")
        } header: {
            Text("All-day motion")
        }
    }

    private var alertsSettingsPage: some View {
        compactSettingsForm(title: "Alerts") {
            alertsSection
        }
    }

    private var dataSettingsPage: some View {
        AtriaDataSettingsDefaultsScope(onNutritionHealthToggle: onNutritionHealthToggle) {
            iCloudBackupEnabled,
            useHealthNutrition in
            compactSettingsForm(title: "Data") {
                dataSection(iCloudBackupEnabled: iCloudBackupEnabled,
                            useHealthNutrition: useHealthNutrition)
            }
        }
        // The archive can contain hundreds of megabytes and many rotated
        // segments. Its footprint is useful only on this destination, so do
        // not start that filesystem walk on the Settings presentation frame.
        // Keeping it here also lets SwiftUI cancel the awaiting view task when
        // the user leaves Data; the result is equality/visibility gated below.
        .task { await refreshDataDestinationStatusIfNeeded() }
    }

    private var privacySettingsPage: some View {
        compactSettingsForm(title: "Privacy & About") {
            AtriaResearchSharingSection(buildPreview: buildResearchPreview,
                                        buildBundle: buildResearchBundle)
            aboutSection
        }
    }

    @ViewBuilder
    private var developerSettingsPage: some View {
        compactSettingsForm(title: "Developer") {
            researchValidationSection
            Section {
                Button("Exit developer mode", role: .destructive) {
                    onExitDeveloperMode()
                    navigationPath = NavigationPath()
                }
            } footer: {
                Text("Developer mode also expires automatically seven days after its most recent developer launch.")
            }
        }
    }

    private func compactSettingsForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            content()
        }
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(.compact)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }


    // MARK: Appearance

    private func appearanceSection(appearanceMode: Binding<String>) -> some View {
        Section {
            Picker("Appearance", selection: appearanceMode) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Appearance")
        }
    }

    // MARK: Profile

    private func profileSection(faceOffDisplayName: Binding<String>) -> some View {
        Section {
            if let maxHRSuggestion {
                maxHRSuggestionRow(maxHRSuggestion)
            }
            LabeledContent("Max heart rate") {
                Text("\(draft.maxHR) bpm").monospacedDigit().foregroundStyle(.pink)
            }
            Picker("Set from", selection: $draft.maxHRSource) {
                ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            Stepper(value: $draft.age, in: 13...100) {
                LabeledContent("Age") { Text("\(draft.age)").monospacedDigit() }
            }
            Stepper(value: $draft.measuredMaxHR, in: 120...220) {
                LabeledContent("Measured max") { Text("\(draft.measuredMaxHR) bpm").monospacedDigit() }
            }
            Picker("Sex", selection: $draft.biologicalSex) {
                ForEach(AthleteProfile.BiologicalSex.allCases) { sex in
                    Text(sex.label).tag(sex)
                }
            }
            Stepper(value: $draft.weightKg, in: 0...250, step: 1) {
                LabeledContent("Weight") {
                    Text(draft.weightKg > 0 ? "\(Int(draft.weightKg.rounded())) kg" : "Not set")
                        .monospacedDigit()
                        .foregroundStyle(draft.weightKg > 0 ? .primary : .secondary)
                }
            }
            Stepper(value: $draft.heightCm, in: 0...230, step: 1) {
                LabeledContent("Height") {
                    // "Not set" (matching Weight) rather than "Optional" — a value
                    // slot reading "Optional" looked like a broken/placeholder state.
                    Text(draft.heightCm > 0 ? "\(Int(draft.heightCm.rounded())) cm" : "Not set")
                        .monospacedDigit()
                        .foregroundStyle(draft.heightCm > 0 ? .primary : .secondary)
                }
            }
            if let restingBaseline {
                LabeledContent("Resting baseline") {
                    Text("\(restingBaseline) bpm").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            TextField("Face-Off name", text: faceOffDisplayName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
        } header: {
            Text("Profile")
        } footer: {
            Text((draft.hasEnergyProfile ? "Weight improves calorie estimates." : "Add sex and weight for calories.")
                 + " Face-Off name is used only on challenge links.")
        }
    }

    private func maxHRSuggestionRow(_ suggestion: AtriaMaxHRSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(suggestion.title, systemImage: "heart.circle.fill")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.pink)
            Text(suggestion.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    var updated = draft
                    updated.measuredMaxHR = suggestion.observedPeak
                    updated.maxHRSource = .measured
                    draft = updated
                    profilePersistence.flush(updated)
                    AtriaMaxHRSuggestionEngine.clearDismissal()
                } label: {
                    Label("Update", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .pink)

                Button {
                    onDismissMaxHRSuggestion(suggestion.observedPeak)
                } label: {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: Alerts

    private var alertsSection: some View {
        Section {
            AtriaHapticAlertSettingsCard(settings: haptics) { next in
                haptics = next
            }
            AtriaNotificationSettingsCard()
        } header: {
            Text("Alerts")
        }
    }

    // MARK: Data & privacy

    private func dataSection(iCloudBackupEnabled: Binding<Bool>,
                             useHealthNutrition: Binding<Bool>) -> some View {
        Section {
            backupArchiveRow(iCloudBackupEnabled: iCloudBackupEnabled)
            if let onExportHealth {
                Button {
                    onExportHealth()
                    exportTapped = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(4))
                        exportTapped = false
                    }
                } label: {
                    Label(exportTapped ? "Syncing to Apple Health…" : "Export to Apple Health",
                          systemImage: exportTapped ? "checkmark.circle.fill" : "square.and.arrow.up")
                }
                .disabled(exportTapped)
            } else {
                settingsInfoRow(icon: "heart.text.square.fill", tint: .red,
                                title: "Apple Health export",
                                detail: "Your heart rate, workouts and sleep sync to Apple Health from the collection tools.")
            }

            Toggle(isOn: useHealthNutrition) {
                Label("Use nutrition from Apple Health", systemImage: "fork.knife.circle.fill")
            }
            .accessibilityHint("Read-only calories, macros, water, caffeine, and alcohol from Apple Health when you grant permission. Atria never asks you to log meals.")

            if let onSyncMissedData {
                Button {
                    historySyncFeedback = onSyncMissedData() ? .started : .notStarted
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        historySyncFeedback = nil
                    }
                } label: {
                    Label("Sync missed data from strap",
                          systemImage: "arrow.down.circle")
                }
                .disabled(historySyncFeedback != nil)
                .accessibilityHint(historySyncFeedback?.detail
                    ?? "Requests data stored by the strap while disconnected or closed. Atria reports whether a transfer actually starts.")

                if let historySyncFeedback {
                    settingsInfoRow(
                        icon: historySyncFeedback == .started
                            ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        tint: historySyncFeedback == .started ? .green : .orange,
                        title: historySyncFeedback.title,
                        detail: historySyncFeedback.detail
                    )
                }
            }

            if let onSetCatchUpBoost,
               (catchUpBoostLocalOn ?? catchUpBoostActive) || catchUpBoostSuggested {
                let isOn = catchUpBoostLocalOn ?? catchUpBoostActive
                Button {
                    let next = !isOn
                    onSetCatchUpBoost(next)
                    catchUpBoostLocalOn = next
                } label: {
                    Label(isOn ? "Turn off catch-up boost" : "Catch up faster",
                          systemImage: isOn ? "bolt.fill" : "bolt")
                }
                .accessibilityHint(isOn
                    ? "Streaming strap motion at a higher cadence to sync the backlog. Turns off automatically once the strap is caught up."
                    : "The strap history is \(catchUpBehindText ?? "hours behind"). Streams motion at a higher cadence to sync now, and turns off automatically once caught up. Uses more strap battery.")
                settingsInfoRow(
                    icon: isOn ? "bolt.badge.clock.fill" : "bolt.badge.clock",
                    tint: isOn ? .green : .orange,
                    title: isOn
                        ? "Catching up faster"
                        : "Catch up faster" + (catchUpBehindText.map { " · \($0)" } ?? ""),
                    detail: isOn
                        ? "Higher-cadence motion streaming is on so the backlog syncs sooner. Atria turns it back off by itself once the strap is caught up."
                        : "Strap history is lagging. Stream motion at a higher cadence to sync sooner — it uses more strap battery and stops on its own once caught up."
                )
            }
            storageFootprintRow
        } header: {
            Text("Your data")
        } footer: {
            // Two facts about this section were written only into VoiceOver
            // hints. One is a reassurance that decides whether anyone enables
            // nutrition at all; the other is a CONSEQUENCE of tapping Sync,
            // which a wearer needs before the tap rather than after it. A
            // Section footer is where a Form states this — putting the text
            // inside the rows themselves broke the native icon column on the
            // toggle and inherited the button's tint on the sync row.
            Text("Nutrition is read-only — Atria never asks you to log meals. Missed-data sync asks the strap for stored rows and reports whether a transfer actually starts.")
        }
    }

    private var storageFootprintRow: some View {
        settingsInfoRow(
            icon: "internaldrive.fill",
            tint: .blue,
            title: "Storage" + (storageFootprintTotal.map { " · \($0)" } ?? ""),
            detail: DataCopy.storageDisclosure
        )
    }

    private struct StorageFootprint: Sendable {
        let totalText: String
        let sessionsBytes: Int64
        let coldSessionsBytes: Int64
        let archiveBaseBytes: Int64
        let segmentsBytes: Int64
        let rollupsBytes: Int64
        let allDocumentsBytes: Int64

        var totalBytes: Int64 {
            allDocumentsBytes
        }
    }

    /// Attribute-only filesystem work, kept off the main actor so opening
    /// Settings remains immediate even when the archive has many segments.
    nonisolated private static func storageFootprint() -> StorageFootprint? {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        func size(of url: URL) -> Int64 {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return 0 }
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }

        func directorySize(_ url: URL) -> Int64 {
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true {
                    total += Int64(values?.fileSize ?? 0)
                }
            }
            return total
        }

        let sessionsBytes = size(of: documents.appendingPathComponent("sessions.json"))
        let coldSessionsBytes = size(of: documents.appendingPathComponent("sessions-cold.json"))
            + directorySize(documents.appendingPathComponent(
                AtriaFullFidelityColdSessionStore.directoryName,
                isDirectory: true
            ))
        let archiveDirectory = documents.appendingPathComponent("atria-historical", isDirectory: true)
        let archiveBaseBytes = size(of: archiveDirectory.appendingPathComponent("historical-archive.jsonl"))
        let segmentsBytes = directorySize(archiveDirectory.appendingPathComponent("segments", isDirectory: true))
        let rollupsBytes = size(of: documents.appendingPathComponent("daily-rollups.json"))

        // The headline is the whole app Documents tree, not a hand-picked
        // subtotal. This includes compact facts, replay SQLite/WAL files,
        // backups, calibration captures, receipts and future managed tiers.
        let totalBytes = directorySize(documents)

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let totalText = formatter.string(fromByteCount: totalBytes)
        return StorageFootprint(totalText: totalText,
                                sessionsBytes: sessionsBytes,
                                coldSessionsBytes: coldSessionsBytes,
                                archiveBaseBytes: archiveBaseBytes,
                                segmentsBytes: segmentsBytes,
                                rollupsBytes: rollupsBytes,
                                allDocumentsBytes: totalBytes)
    }

    private func refreshStorageFootprint() async {
        let footprint = await Task.detached(priority: .utility) {
            Self.storageFootprint()
        }.value
        guard !Task.isCancelled, let footprint else { return }

        storageFootprintTotal = footprint.totalText

        AtriaDebugLog("ATRIADBG settings_storage_footprint status=ok sessions_bytes=%d cold_sessions_bytes=%d archive_bytes=%d segments_bytes=%d rollups_bytes=%d total_bytes=%d",
                       footprint.sessionsBytes,
                       footprint.coldSessionsBytes,
                       footprint.archiveBaseBytes,
                       footprint.segmentsBytes,
                       footprint.rollupsBytes,
                       footprint.totalBytes)
    }

    private func refreshStorageFootprintIfNeeded() async {
        guard storageFootprintTotal == nil else { return }
        await refreshStorageFootprint()
    }

    /// Backup and filesystem state are not needed to draw the Settings hub.
    /// Hydrate them only after Data is the visible destination, and yield once
    /// so the navigation transition can commit before any provider callback.
    private func refreshDataDestinationStatusIfNeeded() async {
        await Task.yield()
        guard !Task.isCancelled else { return }
        if !didLoadBackupStatus {
            backupStatus = backupStatusProvider()
            didLoadBackupStatus = true
        }
        await refreshStorageFootprintIfNeeded()
    }

    private func backupArchiveRow(iCloudBackupEnabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: backupStatus.available ? "externaldrive.badge.checkmark" : "externaldrive")
                    .font(.body)
                    .foregroundStyle(backupStatus.current ? .green : .orange)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local backup")
                        .font(.body)
                    Text(backupSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHint(backupPathAccessibilityHint)
                    if let backupActionMessage {
                        Label(backupActionMessage, systemImage: backupFeedbackTone.systemImage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(backupFeedbackTone.tint)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let onWriteBackup {
                    Button {
                        startBackup(using: onWriteBackup)
                    } label: {
                        HStack(spacing: 6) {
                            if backupOperationInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(backupOperationInProgress ? "Working…" : "Back up now",
                                  systemImage: "arrow.down.doc.fill")
                        }
                    }
                    .atriaCardAction(prominent: false, tint: .blue)
                    .disabled(backupOperationInProgress)
                }
                if let onVerifyBackup {
                    Button {
                        guard !backupOperationInProgress else { return }
                        backupOperationInProgress = true
                        backupActionMessage = nil
                        Task { @MainActor in
                            let status = await onVerifyBackup()
                            backupStatus = status
                            backupActionMessage = status.current ? "Latest backup matches this phone." : "Latest backup needs review."
                            backupFeedbackTone = status.current ? .success : .failure
                            backupOperationInProgress = false
                        }
                    } label: {
                        Image(systemName: "checkmark.seal")
                            .accessibilityLabel("Verify backup")
                    }
                    .atriaCardAction(prominent: false, tint: .green)
                    .disabled(backupOperationInProgress)
                }
                if onRestoreBackup != nil {
                    Button {
                        backupImportPresented = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .accessibilityLabel("Restore backup from Files")
                    }
                    .atriaCardAction(prominent: false, tint: .orange)
                    .disabled(backupOperationInProgress)
                }
            }
            .labelStyle(.titleAndIcon)

            Toggle(isOn: iCloudBackupEnabled) {
                Label("Copy to iCloud Drive", systemImage: "icloud.and.arrow.up")
            }
            .font(.subheadline)
        }
    }

    private var backupSummaryText: String {
        guard backupStatus.available else {
            return "No archive yet. Atria writes compressed local backups on this phone."
        }
        let state = backupStatus.current ? "Current" : "Needs review"
        let size = ByteCountFormatter.string(fromByteCount: Int64(backupStatus.bytes), countStyle: .file)
        let sessionsText = backupStatus.sessions == 1 ? "1 session" : "\(backupStatus.sessions) sessions"
        return "\(state) · \(sessionsText) · \(size)"
    }

    private var backupPathAccessibilityHint: String {
        backupStatus.path.isEmpty ? "Stored on this phone." : "Stored at \(backupStatus.path)."
    }

    private var backupArchiveTypes: [UTType] {
        var types: [UTType] = [.json]
        if let gzip = UTType(filenameExtension: "gz") {
            types.append(gzip)
        }
        return types
    }

    private func startBackup(
        using writer: @escaping (@escaping @MainActor (SessionBackupStatus) -> Void) -> Void
    ) {
        guard !backupOperationInProgress else { return }
        backupOperationInProgress = true
        backupActionMessage = nil
        backupFeedbackTone = .neutral

        writer { status in
            backupOperationInProgress = false
            if status.available && status.current {
                backupStatus = status
                backupActionMessage = "Backup saved."
                backupFeedbackTone = .success
            } else {
                backupActionMessage = "Backup failed. Try again."
                backupFeedbackTone = .failure
            }
        }
    }

    private func handleBackupImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let onRestoreBackup, !backupOperationInProgress else { return }
            backupOperationInProgress = true
            backupActionMessage = nil
            Task { @MainActor in
                // A Files URL remains security-scoped until every awaited
                // worker phase (safety write, decode/hash and apply) completes.
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                    backupOperationInProgress = false
                }
                if let next = await onRestoreBackup(url) {
                    backupStatus = next
                    backupActionMessage = next.available ? "Backup restored." : "Restore finished; backup status is missing."
                    backupFeedbackTone = next.available ? .success : .failure
                } else {
                    backupActionMessage = "Restore failed. Choose an Atria .json or .json.gz archive."
                    backupFeedbackTone = .failure
                }
            }
        case .failure:
            backupActionMessage = "Restore canceled."
            backupFeedbackTone = .neutral
        }
    }

    @ViewBuilder
    private var researchValidationSection: some View {
        if let makeResearchValidationContent = researchValidationContent {
            Section {
                makeResearchValidationContent()
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Research & Validation")
            }
        }
    }

    #if DEBUG
    private var debugPrioritizesDeviceSection: Bool {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return false
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        return ProcessInfo.processInfo.arguments.indices.contains(valueIndex)
            && ProcessInfo.processInfo.arguments[valueIndex] == "unknown-strap-generation"
    }

    private var debugPrioritizesDataSection: Bool {
        guard let fixtureIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--atria-ui-fixture") else {
            return false
        }
        let valueIndex = ProcessInfo.processInfo.arguments.index(after: fixtureIndex)
        return ProcessInfo.processInfo.arguments.indices.contains(valueIndex)
            && ProcessInfo.processInfo.arguments[valueIndex] == "settings-backup"
    }
    #else
    private var debugPrioritizesDeviceSection: Bool { false }
    private var debugPrioritizesDataSection: Bool { false }
    #endif

    // MARK: Today screen layout

    private func todayBinding(_ metric: AtriaTodayMetric,
                              todayHiddenCSV: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { !AtriaTodayMetric.hidden(from: todayHiddenCSV.wrappedValue).contains(metric.rawValue) },
            set: { visible in
                var hidden = AtriaTodayMetric.hidden(from: todayHiddenCSV.wrappedValue)
                if visible {
                    hidden.remove(metric.rawValue)
                } else {
                    hidden.insert(metric.rawValue)
                }
                todayHiddenCSV.wrappedValue = AtriaTodayMetric.hiddenStorageValue(for: hidden)
            }
        )
    }

    private func resetTodayLayout(todayHiddenCSV: Binding<String>,
                                  todayOrderCSV: Binding<String>,
                                  todaySizeCSV: Binding<String>) {
        todayOrderCSV.wrappedValue = AtriaTodayMetric.defaultGlanceOrder.map(\.rawValue).joined(separator: ",")
        todayHiddenCSV.wrappedValue = ""
        todaySizeCSV.wrappedValue = ""
    }

    private func todayLayoutSection(todayHiddenCSV: Binding<String>,
                                    todayOrderCSV: Binding<String>,
                                    todaySizeCSV: Binding<String>) -> some View {
        Section {
            if let onCustomizeToday {
                Button {
                    onCustomizeToday()
                } label: {
                    Label("At a glance", systemImage: "rectangle.3.group")
                }
                .accessibilityLabel("Customize At a glance")
                .accessibilityHint("Choose, resize, and reorder the metrics on Today")
            } else {
                // Compatibility fallback for hosts that do not provide the
                // dedicated drag-and-drop customizer.
                ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV.wrappedValue)) { metric in
                    HStack(spacing: 10) {
                        Toggle(isOn: todayBinding(metric, todayHiddenCSV: todayHiddenCSV)) {
                            Label(metric.label, systemImage: metric.systemImage)
                        }

                        Spacer(minLength: 0)

                        Menu {
                            Button {
                                todayOrderCSV.wrappedValue = AtriaTodayMetric.moving(
                                    metric,
                                    direction: -1,
                                    in: todayOrderCSV.wrappedValue
                                )
                            } label: {
                                Label("Move up", systemImage: "arrow.up")
                            }
                            .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV.wrappedValue).first)

                            Button {
                                todayOrderCSV.wrappedValue = AtriaTodayMetric.moving(
                                    metric,
                                    direction: 1,
                                    in: todayOrderCSV.wrappedValue
                                )
                            } label: {
                                Label("Move down", systemImage: "arrow.down")
                            }
                            .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV.wrappedValue).last)
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Reorder \(metric.label)")
                    }
                }
            }

        } header: {
            HStack {
                Text("Today screen")
                Spacer(minLength: 8)
                Button {
                    resetTodayLayout(todayHiddenCSV: todayHiddenCSV,
                                     todayOrderCSV: todayOrderCSV,
                                     todaySizeCSV: todaySizeCSV)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset Today layout")
                .accessibilityHint("Restores the default cards, order, and sizes")
            }
        }
    }

    private var deviceSection: some View {
        Section {
            HStack {
                Text("Name")
                Spacer(minLength: 12)
                TextField("Strap name", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { onRenameStrap(nameDraft) }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Saved on this iPhone. Atria reconnects automatically.")
            }
            LabeledContent("Model") {
                Text(strapModel.isEmpty ? "Strap" : strapModel)
                    .foregroundStyle(.secondary)
            }
            if !strapGenerationDetail.isEmpty {
                LabeledContent("Generation") {
                    Text(strapGenerationDetail)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if strapGenerationDetail.contains("unknown") || strapGenerationDetail.contains("unverified") {
                settingsInfoRow(icon: "exclamationmark.triangle",
                                tint: .orange,
                                title: "WHOOP 5.0 support is early",
                                detail: "Heart rate works. Other metrics stay conservative until this strap is checked.")
            }
            if !strapFirmware.isEmpty {
                LabeledContent("Firmware") {
                    Text(strapFirmware).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            if let onForgetStrap {
                Button(role: .destructive) {
                    showForgetConfirm = true
                } label: {
                    Label("Forget this strap", systemImage: "minus.circle")
                }
                .confirmationDialog("Forget this strap?",
                                    isPresented: $showForgetConfirm,
                                    titleVisibility: .visible) {
                    Button("Forget strap", role: .destructive) { onForgetStrap() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Atria will stop auto-reconnecting and won't pair again until you connect a strap. You can reconnect any time.")
                }
            }
        } header: {
            Text("Device")
        }
    }

    private var radioModeSection: some View {
        Section {
            Toggle(isOn: $batterySaver) {
                Label("Stable sensor mode", systemImage: "antenna.radiowaves.left.and.right")
            }
            .accessibilityHint("Changing mode reconnects the strap.")
            settingsInfoRow(icon: batterySaver ? "waveform.path.ecg" : "wrench.and.screwdriver.fill",
                            tint: batterySaver ? .green : .orange,
                            title: batterySaver ? "Heart rate + strap motion" : "Diagnostic full protocol",
                            detail: batterySaver
                                ? "Recommended. Keeps live heart rate and verified strap motion on the stable connection. When strap steps are unavailable, Atria marks them unavailable rather than substituting phone steps."
                                : "Enables additional proprietary streams for diagnostics. This may be less stable and use more strap battery.")
            // Static handoff compatibility marker for the old detail:
            // Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.
        } header: {
            Text("Strap connection")
        }
    }

    private var heartRateBroadcastSection: some View {
        Section {
            Toggle(isOn: $heartRateBroadcast) {
                Label("Broadcast heart rate", systemImage: "antenna.radiowaves.left.and.right")
            }
            .accessibilityHint("Uses live strap heart rate and slightly more battery.")
            settingsInfoRow(icon: "dot.radiowaves.left.and.right",
                            tint: .cyan,
                            title: heartRateBroadcast ? "Atria HR visible" : "Gym pairing ready",
                            detail: heartRateBroadcast
                                ? "Atria advertises as Atria HR for treadmills, bikes and training apps."
                                : "Turn on during a workout, or keep it available from Settings.")
        } header: {
            Text("Heart rate broadcast")
        }
    }

    // MARK: About

    private var sensorAvailabilitySection: some View {
        Section {
            settingsInfoRow(icon: "waveform.path.ecg",
                            tint: .secondary,
                            title: "ECG not supported",
                            detail: "WHOOP 4.0 has no electrodes, so Atria cannot measure an ECG or classify sinus rhythm — and does not fake either.")
            settingsInfoRow(icon: "gauge.with.dots.needle.50percent",
                            tint: .secondary,
                            title: "Blood pressure not supported",
                            detail: "WHOOP 4.0 is not cuff-calibrated, so Atria does not estimate BP.")
                // This is an app decoder limitation on supported straps, not a
                // fabricated blood-oxygen value or a claim that the sensor is absent.
                settingsInfoRow(icon: "drop.degreesign",
                            tint: .cyan,
                            title: "Blood oxygen signal",
                            detail: "\(AtriaSpO2Copy.decoderNotVerified). \(AtriaSpO2Copy.wontFakeAPercentage)")
                settingsInfoRow(icon: "thermometer.variable",
                            tint: .teal,
                            title: "Wrist temperature signal",
                            detail: "Relative wrist-skin deviation only; no core temperature or Health export.")
        } header: {
            Text("Sensors")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version") {
                Text(appVersion).foregroundStyle(.secondary).monospacedDigit()
            }
            LabeledContent("Privacy") {
                Text("Local-first; no account or cloud sync").foregroundStyle(.secondary)
            }
            LabeledContent("Support & contact") {
                Text(supportHandle).foregroundStyle(.secondary)
            }
        } header: {
            Text("About")
        } footer: {
            Text("Independent; not medical software.")
        }
    }

    private func settingsInfoRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        DisclosureGroup {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 38)
        } label: {
            Label {
                Text(title)
                    .font(.body)
            } icon: {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 26)
            }
        }
        .accessibilityHint(detail)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

/// Destination-owned defaults. SwiftUI constructs this scope only after the
/// user opens Personal, keeping its observation boxes out of the Settings hub.
private struct AtriaPersonalSettingsDefaultsScope<Content: View>: View {
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
    @AtriaDefault("atria.faceoff.displayName") private var faceOffDisplayName = ""
    @AppStorage(AtriaTodayMetric.storageKey) private var todayHiddenCSV = ""
    @AtriaDefault(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = ""
    @AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = ""

    private let content: (Binding<String>, Binding<String>, Binding<String>, Binding<String>, Binding<String>) -> Content

    init(@ViewBuilder content: @escaping (
        Binding<String>,
        Binding<String>,
        Binding<String>,
        Binding<String>,
        Binding<String>
    ) -> Content) {
        self.content = content
    }

    var body: some View {
        content($appearanceMode,
                $faceOffDisplayName,
                $todayHiddenCSV,
                $todayOrderCSV,
                $todaySizeCSV)
    }
}

/// Data-specific defaults remain dormant until Data is actually presented.
private struct AtriaDataSettingsDefaultsScope<Content: View>: View {
    @AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false
    @AtriaDefault(AtriaNutritionContext.healthReadNutritionKey) private var useHealthNutrition = false

    let onNutritionHealthToggle: (() -> Void)?
    private let content: (Binding<Bool>, Binding<Bool>) -> Content

    init(onNutritionHealthToggle: (() -> Void)?,
         @ViewBuilder content: @escaping (Binding<Bool>, Binding<Bool>) -> Content) {
        self.onNutritionHealthToggle = onNutritionHealthToggle
        self.content = content
    }

    var body: some View {
        content($iCloudBackupEnabled, $useHealthNutrition)
            .onChange(of: useHealthNutrition) { _, enabled in
                if enabled {
                    onNutritionHealthToggle?()
                }
            }
    }
}

/// The advanced target editor owns its defaults only after the user opens
/// Personal > Advanced targets. Keeping these DynamicProperty boxes out of
/// AtriaSettingsView prevents the Settings gear from constructing and
/// registering an off-screen observation graph on the presentation frame.
/// Destination-only scope for the all-day motion default: the observer
/// registers when the Strap page appears, never on the Settings hub frame.
private struct AtriaStrapMotionDefaultsScope<Content: View>: View {
    @AppStorage("atria.allDayMotion.enabled") private var allDayMotionEnabled = true

    private let content: (Binding<Bool>) -> Content

    init(@ViewBuilder content: @escaping (Binding<Bool>) -> Content) {
        self.content = content
    }

    var body: some View {
        content($allDayMotionEnabled)
    }
}

/// The three goals a user actually changes — nightly sleep, daily steps, daily
/// active calories — surfaced one tap into Personal instead of four taps deep
/// inside Advanced targets, where they sat between ACWR watch bands and HRV
/// ratio thresholds. Same `atria.target.*` keys, so the advanced editor and
/// this section stay in lockstep (`AtriaDefault` boxes observe the shared
/// change center). The defaults boxes live on this struct rather than on
/// `AtriaSettingsView` so they register when Personal appears, never on the
/// Settings hub presentation frame.
/// Today vitals-ring layout picker (Settings -> Personal): concentric
/// Activity-style rings vs WHOOP-style separate side-by-side rings. Writes the
/// shared `AtriaRingLayoutStyle.defaultsKey` that `AtriaTriRing` and the share
/// card read live, so the whole app switches at once.
private struct AtriaRingLayoutSection: View {
    @AtriaDefault(AtriaRingLayoutStyle.defaultsKey) private var ringLayoutRaw: String = "concentric"

    var body: some View {
        Section {
            Picker("Ring style", selection: $ringLayoutRaw) {
                ForEach(AtriaRingLayoutStyle.allCases, id: \.self) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Today rings")
        } footer: {
            Text("Concentric stacks the three rings; Separate shows them side by side, WHOOP-style.")
        }
    }
}

private struct AtriaDailyGoalsSection: View {
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Section {
            Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                LabeledContent {
                    Text(AtriaMetricFormat.sleepHours(sleepGoalHours))
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: sleepGoalHours)
                } label: {
                    Label("Sleep each night", systemImage: "bed.double.fill")
                }
            }
            .accessibilityHint("Sets the sleep goal used by the Today ring and sleep cards")

            Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                LabeledContent {
                    Text("\(stepsGoal)")
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: stepsGoal)
                } label: {
                    Label("Steps each day", systemImage: "figure.walk.motion")
                }
            }
            .accessibilityHint("Sets the daily step goal used by the Today step card and widget")

            Stepper(value: $caloriesGoal, in: 100...3_000, step: 50) {
                LabeledContent {
                    Text("\(caloriesGoal) kcal")
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: caloriesGoal)
                } label: {
                    Label("Active calories", systemImage: "flame.fill")
                }
            }
            .accessibilityHint("Sets the daily active-calorie goal used by the Today calorie card")
        } header: {
            Text("Daily goals")
        } footer: {
            Text("These set the goals Today measures you against. Zone thresholds for recovery, strain, and training load live in Advanced targets.")
        }
        .onChange(of: sleepGoalHours) { _, _ in
            sleepGoalHours = min(max(sleepGoalHours, 4.0), 12.0)
        }
        .onChange(of: stepsGoal) { _, _ in
            stepsGoal = min(max(stepsGoal, 1_000), 30_000)
        }
        .onChange(of: caloriesGoal) { _, _ in
            caloriesGoal = min(max(caloriesGoal, 100), 3_000)
        }
    }
}

private struct AtriaAdvancedTargetsSettingsView: View {
    @AtriaDefault("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AtriaDefault("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AtriaDefault("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AtriaDefault("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AtriaDefault("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AtriaDefault("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AtriaDefault("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AtriaDefault("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AtriaDefault("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AtriaDefault("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AtriaDefault("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AtriaDefault("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AtriaDefault("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AtriaDefault("atria.sleep.baseNeedHours") private var sleepBaseNeedHours: Double = 8.0
    @AtriaDefault("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AtriaDefault("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AtriaDefault("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AtriaDefault("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AtriaDefault("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AtriaDefault("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AtriaDefault("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AtriaDefault("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AtriaDefault("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AtriaDefault("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AtriaDefault("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AtriaDefault("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AtriaDefault("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AtriaDefault("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AtriaDefault("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    var body: some View {
        Form {
            targetsSection
        }
        .environment(\.defaultMinListRowHeight, 44)
        .listSectionSpacing(.compact)
        .navigationTitle("Advanced targets")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: recoveryTargetSignature) { _, _ in normalizeRecoveryTargets() }
        .onChange(of: strainTargetSignature) { _, _ in normalizeStrainTargets() }
        .onChange(of: trainingLoadTargetSignature) { _, _ in normalizeTrainingLoadTargets() }
        .onChange(of: activityTargetSignature) { _, _ in
            normalizeStepsGoal()
            normalizeCaloriesGoal()
        }
        .onChange(of: sleepTargetSignature) { _, _ in
            normalizeSleepGoal()
            normalizeSleepBaseNeed()
            normalizeSleepEfficiencyTargets()
        }
        .onChange(of: baselineTargetSignature) { _, _ in
            normalizeHRVTargets()
            normalizeRestingTargets()
            normalizeRespiratoryTargets()
        }
        .onChange(of: signalTargetSignature) { _, _ in
            normalizeSkinTemperatureTargets()
            normalizeBloodOxygenTargets()
        }
        .onChange(of: biologicalAgeTargetSignature) { _, _ in normalizeBiologicalAgeTargets() }
        .onChange(of: vo2TargetSignature) { _, _ in normalizeVO2Targets() }
    }

    private var recoveryTargetSignature: [Double] {
        [recoveryGreenLower, recoveryYellowLower]
    }

    private var strainTargetSignature: [Double] {
        [strainGreenBand, strainYellowBand]
    }

    private var trainingLoadTargetSignature: [Double] {
        [loadACWRWatchLow, loadACWRWatchHigh, loadACWRBadLow, loadACWRBadHigh,
         loadMonotonyWatch, loadMonotonyBad]
    }

    private var activityTargetSignature: [Double] {
        [Double(stepsGoal), Double(caloriesGoal)]
    }

    private var sleepTargetSignature: [Double] {
        [sleepGoalHours, sleepBaseNeedHours, sleepEfficiencyGreenLower, sleepEfficiencyYellowLower]
    }

    private var baselineTargetSignature: [Double] {
        [hrvGreenRatio, hrvYellowRatio, Double(restingGreenDelta), Double(restingYellowDelta),
         respiratoryGreenDelta, respiratoryYellowDelta]
    }

    private var signalTargetSignature: [Double] {
        [skinTemperatureGreenDelta, skinTemperatureYellowDelta, Double(bloodOxygenCandidateGoal)]
    }

    private var biologicalAgeTargetSignature: [Double] {
        [Double(biologicalAgeGreenOlderDelta), Double(biologicalAgeYellowOlderDelta)]
    }

    private var vo2TargetSignature: [Double] {
        [vo2GreenDelta, vo2RedDelta]
    }

    private func normalizeRecoveryTargets() {
        recoveryYellowLower = min(max(recoveryYellowLower, 5), 66)
        recoveryGreenLower = min(max(recoveryGreenLower, recoveryYellowLower + 1), 95)
    }

    private func normalizeStepsGoal() {
        stepsGoal = min(max(stepsGoal, 1_000), 30_000)
    }

    private func normalizeCaloriesGoal() {
        caloriesGoal = min(max(caloriesGoal, 100), 3_000)
    }

    private func normalizeStrainTargets() {
        strainGreenBand = min(max(strainGreenBand, 0.5), 5.0)
        strainYellowBand = min(max(strainYellowBand, strainGreenBand + 0.5), 8.0)
    }

    private func normalizeTrainingLoadTargets() {
        loadACWRBadLow = min(max(loadACWRBadLow, 0.30), 0.95)
        loadACWRWatchLow = min(max(loadACWRWatchLow, loadACWRBadLow + 0.05), 1.00)
        loadACWRWatchHigh = min(max(loadACWRWatchHigh, 1.00), 1.60)
        loadACWRBadHigh = min(max(loadACWRBadHigh, loadACWRWatchHigh + 0.05), 2.20)
        loadMonotonyWatch = min(max(loadMonotonyWatch, 1.0), 4.0)
        loadMonotonyBad = min(max(loadMonotonyBad, loadMonotonyWatch + 0.1), 5.0)
    }

    private func normalizeSleepGoal() {
        sleepGoalHours = min(max(sleepGoalHours, 4.0), 12.0)
    }

    private func normalizeSleepBaseNeed() {
        sleepBaseNeedHours = min(max(sleepBaseNeedHours, 6.0), 10.0)
    }

    private func normalizeSleepEfficiencyTargets() {
        sleepEfficiencyYellowLower = min(max(sleepEfficiencyYellowLower, 50), 95)
        sleepEfficiencyGreenLower = min(max(sleepEfficiencyGreenLower, sleepEfficiencyYellowLower + 1), 99)
    }

    private func normalizeHRVTargets() {
        hrvYellowRatio = min(max(hrvYellowRatio, 0.50), 0.98)
        hrvGreenRatio = min(max(hrvGreenRatio, hrvYellowRatio + 0.01), 1.20)
    }

    private func normalizeRestingTargets() {
        restingGreenDelta = min(max(restingGreenDelta, 0), 12)
        restingYellowDelta = min(max(restingYellowDelta, restingGreenDelta + 1), 20)
    }

    private func normalizeRespiratoryTargets() {
        respiratoryGreenDelta = min(max(respiratoryGreenDelta, 0.5), 4.0)
        respiratoryYellowDelta = min(max(respiratoryYellowDelta, respiratoryGreenDelta + 0.5), 8.0)
    }

    private func normalizeSkinTemperatureTargets() {
        skinTemperatureGreenDelta = min(max(skinTemperatureGreenDelta, 0.2), 2.0)
        skinTemperatureYellowDelta = min(max(skinTemperatureYellowDelta, skinTemperatureGreenDelta + 0.1), 4.0)
    }

    private func normalizeBloodOxygenTargets() {
        bloodOxygenCandidateGoal = min(max(bloodOxygenCandidateGoal, 2), 120)
    }

    private func normalizeBiologicalAgeTargets() {
        biologicalAgeGreenOlderDelta = min(max(biologicalAgeGreenOlderDelta, -10), 10)
        biologicalAgeYellowOlderDelta = min(max(biologicalAgeYellowOlderDelta, biologicalAgeGreenOlderDelta + 1), 20)
    }

    private func normalizeVO2Targets() {
        vo2GreenDelta = min(max(vo2GreenDelta, 0.0), 2.0)
        vo2RedDelta = max(min(vo2RedDelta, -0.05), -2.0)
    }

    private func resetAllTargetZones() {
        resetRecoveryTargets()
        resetStrainTargets()
        resetTrainingLoadTargets()
        resetActivityTargets()
        resetSleepTargets()
        resetBaselineTargets()
        resetSignalTargets()
        resetFitnessAgeTargets()
        resetVO2TrendTargets()
    }

    private func resetRecoveryTargets() {
        recoveryGreenLower = 67
        recoveryYellowLower = 34
    }

    private func resetStrainTargets() {
        strainGreenBand = 1.5
        strainYellowBand = 3.0
    }

    private func resetTrainingLoadTargets() {
        loadACWRWatchLow = 0.80
        loadACWRWatchHigh = 1.30
        loadACWRBadLow = 0.60
        loadACWRBadHigh = 1.50
        loadMonotonyWatch = 2.0
        loadMonotonyBad = 2.5
    }

    private func resetActivityTargets() {
        stepsGoal = 8_000
        caloriesGoal = 500
    }

    private func resetSleepTargets() {
        sleepGoalHours = 8.0
        sleepBaseNeedHours = 8.0
        sleepEfficiencyGreenLower = 90
        sleepEfficiencyYellowLower = 80
    }

    private func resetBaselineTargets() {
        hrvGreenRatio = 0.95
        hrvYellowRatio = 0.85
        restingGreenDelta = 3
        restingYellowDelta = 7
    }

    private func resetSignalTargets() {
        respiratoryGreenDelta = 1.5
        respiratoryYellowDelta = 3.0
        skinTemperatureGreenDelta = 0.5
        skinTemperatureYellowDelta = 1.0
        bloodOxygenCandidateGoal = 8
    }

    private func resetFitnessAgeTargets() {
        biologicalAgeGreenOlderDelta = 0
        biologicalAgeYellowOlderDelta = 3
    }

    private func resetVO2TrendTargets() {
        vo2GreenDelta = 0.2
        vo2RedDelta = -0.2
    }


    private var targetsSection: some View {
        let target = AtriaMetricTarget.recovery(greenLower: recoveryGreenLower,
                                                yellowLower: recoveryYellowLower)
        return Section {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    resetAllTargetZones()
                } label: {
                    Label("Reset all targets", systemImage: "arrow.counterclockwise.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .green)

                // Collapsed-by-default groups (UX audit 2026-07-07): the nine
                // target groups rendered ~30 steppers as one uninterrupted
                // wall. Headers stay visible; controls disclose on demand.
                DisclosureGroup(isExpanded: targetGroupBinding("Recovery")) {

                Stepper(value: $recoveryGreenLower, in: 40...95, step: 1) {
                    LabeledContent("Green starts") {
                        Text("\(Int(recoveryGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $recoveryYellowLower, in: 5...66, step: 1) {
                    LabeledContent("Yellow starts") {
                        Text("\(Int(recoveryYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Recovery",
                                  subtitle: target.summaryText,
                                  systemImage: "gauge.with.dots.needle.67percent",
                                  tint: .green)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Recovery",
                                         resetTitle: "Reset to recommended",
                                         onReset: resetRecoveryTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Strain")) {

                Stepper(value: $strainGreenBand, in: 0.5...5.0, step: 0.5) {
                    LabeledContent("Strain green band") {
                        Text(String(format: "+/-%.1f", strainGreenBand))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $strainYellowBand, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Strain yellow band") {
                        Text(String(format: "+/-%.1f", strainYellowBand))
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Strain",
                                  subtitle: "Today's strain goal, scaled to how recovered you are.",
                                  systemImage: "bolt.fill",
                                  tint: .orange)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Strain",
                                         resetTitle: "Reset strain band",
                                         onReset: resetStrainTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Training load")) {

                Stepper(value: $loadACWRWatchLow, in: 0.50...1.00, step: 0.05) {
                    LabeledContent("ACWR low watch") {
                        Text(String(format: "%.1f", loadACWRWatchLow))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRWatchHigh, in: 1.00...1.60, step: 0.05) {
                    LabeledContent("ACWR high watch") {
                        Text(String(format: "%.1f", loadACWRWatchHigh))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRBadLow, in: 0.30...0.95, step: 0.05) {
                    LabeledContent("ACWR low red") {
                        Text(String(format: "%.1f", loadACWRBadLow))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRBadHigh, in: 1.10...2.20, step: 0.05) {
                    LabeledContent("ACWR high red") {
                        Text(String(format: "%.1f", loadACWRBadHigh))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadMonotonyWatch, in: 1.0...4.0, step: 0.1) {
                    LabeledContent("Monotony watch") {
                        Text(String(format: "%.1f", loadMonotonyWatch))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadMonotonyBad, in: 1.2...5.0, step: 0.1) {
                    LabeledContent("Monotony red") {
                        Text(String(format: "%.1f", loadMonotonyBad))
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Training load",
                                  subtitle: "Warns when training ramps up too fast or gets too repetitive.",
                                  systemImage: "chart.bar.xaxis",
                                  tint: .orange)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Training load",
                                         resetTitle: "Reset training-load target",
                                         onReset: resetTrainingLoadTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Activity")) {

                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Strap steps goal") {
                        Text("\(stepsGoal)")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $caloriesGoal, in: 100...3_000, step: 50) {
                    LabeledContent("Calories goal") {
                        Text("\(caloriesGoal) kcal")
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Activity",
                                  subtitle: "Your daily step and active-calorie goals.",
                                  systemImage: "figure.walk.motion",
                                  tint: .green)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Activity",
                                         resetTitle: "Reset activity targets",
                                         onReset: resetActivityTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Sleep")) {

                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(AtriaMetricFormat.sleepHours(sleepGoalHours))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $sleepBaseNeedHours, in: 6.0...10.0, step: 0.25) {
                    LabeledContent("Sleep need") {
                        Text(AtriaMetricFormat.sleepHours(sleepBaseNeedHours))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $sleepEfficiencyGreenLower, in: 60...99, step: 1) {
                    LabeledContent("Sleep eff green") {
                        Text("\(Int(sleepEfficiencyGreenLower.rounded()))%")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $sleepEfficiencyYellowLower, in: 50...95, step: 1) {
                    LabeledContent("Sleep eff yellow") {
                        Text("\(Int(sleepEfficiencyYellowLower.rounded()))%")
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Sleep",
                                  subtitle: "Your nightly sleep goal and how restful your nights were.",
                                  systemImage: "bed.double.fill",
                                  tint: .cyan)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Sleep",
                                         resetTitle: "Reset sleep targets",
                                         onReset: resetSleepTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Personal baselines")) {

                Stepper(value: $hrvGreenRatio, in: 0.70...1.10, step: 0.01) {
                    LabeledContent("HRV green") {
                        Text("\(Int((hrvGreenRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $hrvYellowRatio, in: 0.50...0.98, step: 0.01) {
                    LabeledContent("HRV yellow") {
                        Text("\(Int((hrvYellowRatio * 100).rounded()))%")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $restingGreenDelta, in: 0...12, step: 1) {
                    LabeledContent("RHR green") {
                        Text("+\(restingGreenDelta) bpm")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $restingYellowDelta, in: 1...20, step: 1) {
                    LabeledContent("RHR yellow") {
                        Text("+\(restingYellowDelta) bpm")
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "Personal baselines",
                                  subtitle: "Your HRV and resting-heart-rate ranges, set once Atria learns your normal.",
                                  systemImage: "heart.text.square.fill",
                                  tint: .pink)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Personal baselines",
                                         resetTitle: "Reset baseline targets",
                                         onReset: resetBaselineTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Sleep-only signals")) {

                Stepper(value: $respiratoryGreenDelta, in: 0.5...4.0, step: 0.5) {
                    LabeledContent("Resp green band") {
                        Text(String(format: "+/-%.1f/min", respiratoryGreenDelta))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $respiratoryYellowDelta, in: 1.0...8.0, step: 0.5) {
                    LabeledContent("Resp yellow band") {
                        Text(String(format: "+/-%.1f/min", respiratoryYellowDelta))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $skinTemperatureGreenDelta, in: 0.2...2.0, step: 0.1) {
                    LabeledContent("Temp green band") {
                        Text(String(format: "+/-%.1f C", skinTemperatureGreenDelta))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $skinTemperatureYellowDelta, in: 0.3...4.0, step: 0.1) {
                    LabeledContent("Temp yellow band") {
                        Text(String(format: "+/-%.1f C", skinTemperatureYellowDelta))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $bloodOxygenCandidateGoal, in: 2...120, step: 1) {
                    LabeledContent("Oxygen evidence green") {
                        Text("\(bloodOxygenCandidateGoal) frames")
                            .monospacedDigit()
                    }
                }

                Text("Tunes sleep-baseline colors and evidence thresholds; it does not certify SpO2 or absolute temperature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } label: {
                    targetGroupHeader(title: "Sleep-only signals",
                                  subtitle: "Breathing rate, skin temperature, and blood-oxygen ranges.",
                                  systemImage: "waveform.path.ecg",
                                  tint: .teal)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Sleep-only signals",
                                         resetTitle: "Reset signal targets",
                                         onReset: resetSignalTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("Fitness age")) {

                Stepper(value: $biologicalAgeGreenOlderDelta, in: -10...10, step: 1) {
                    LabeledContent("Fitness age green") {
                        Text("\(biologicalAgeGreenOlderDelta > 0 ? "+" : "")\(biologicalAgeGreenOlderDelta)y")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $biologicalAgeYellowOlderDelta, in: -9...20, step: 1) {
                    LabeledContent("Fitness age yellow") {
                        Text("\(biologicalAgeYellowOlderDelta > 0 ? "+" : "")\(biologicalAgeYellowOlderDelta)y")
                            .monospacedDigit()
                    }
                }

                Text("Uses RHR, lnRMSSD, zone 2+, and sleep consistency. These bands only tune guidance colors.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                } label: {
                    targetGroupHeader(title: "Fitness age",
                                  subtitle: "How much younger or older your fitness looks than your age.",
                                  systemImage: "figure.stand",
                                  tint: .purple)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "Fitness age",
                                         resetTitle: "Reset fitness-age target",
                                         onReset: resetFitnessAgeTargets)
                }

                DisclosureGroup(isExpanded: targetGroupBinding("VO2max")) {

                Stepper(value: $vo2GreenDelta, in: 0.0...2.0, step: 0.1) {
                    LabeledContent("VO2 green gain") {
                        Text(String(format: "+%.1f", vo2GreenDelta))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $vo2RedDelta, in: -2.0 ... -0.05, step: 0.1) {
                    LabeledContent("VO2 red decline") {
                        Text(String(format: "%.1f", vo2RedDelta))
                            .monospacedDigit()
                    }
                }

                } label: {
                    targetGroupHeader(title: "VO2max",
                                  subtitle: "How much your VO2max must change to shift color.",
                                  systemImage: "lungs.fill",
                                  tint: .blue)
                }
                .padding(.trailing, 48)
                .overlay(alignment: .topTrailing) {
                    targetGroupResetMenu(title: "VO2max",
                                         resetTitle: "Reset VO2 trend target",
                                         onReset: resetVO2TrendTargets)
                }
            }
        } header: {
            Text("Targets & zones")
        } footer: {
            Text("General wellness, not medical advice.")
        }
    }

    @State private var expandedTargetGroups: Set<String> = []

    private func targetGroupBinding(_ title: String) -> Binding<Bool> {
        Binding(get: { expandedTargetGroups.contains(title) },
                set: { isOn in
                    if isOn {
                        expandedTargetGroups.insert(title)
                    } else {
                        expandedTargetGroups.remove(title)
                    }
                })
    }

    private func targetGroupHeader(title: String,
                                   subtitle: String,
                                   systemImage: String,
                                   tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title). \(subtitle)")

            Spacer(minLength: 0)
        }
    }

    private func targetGroupResetMenu(title: String,
                                      resetTitle: String,
                                      onReset: @escaping () -> Void) -> some View {
        Menu {
            Button(action: onReset) {
                Label(resetTitle, systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(resetTitle)
        .accessibilityHint("Restores the recommended \(title.lowercased()) values")
    }
}

/// Add/remove which behaviors appear in the morning check-in. Writes the shared
/// tracked-behaviors preference (see AtriaTrackedBehaviors); the deck and impact
/// section pick it up live via UserDefaults change notifications.
struct AtriaTrackedBehaviorsSettingsView: View {
    @AtriaDefault(AtriaTrackedBehaviors.storageKey) private var trackedRaw: String = ""

    private var trackedSet: Set<BehaviorJournalEntry.Tag> {
        Set(AtriaTrackedBehaviors.parse(trackedRaw))
    }

    private var groups: [(title: String, tags: [BehaviorJournalEntry.Tag])] {
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

    var body: some View {
        Form {
            Section {
                Text("Choose the behaviors you want to log each morning. Your daily check-in shows only these — add or remove them anytime.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.tags) { tag in
                        Toggle(isOn: binding(for: tag)) {
                            Label(tag.label, systemImage: tag.symbolName)
                        }
                    }
                }
            }
        }
        .navigationTitle("Journal behaviors")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for tag: BehaviorJournalEntry.Tag) -> Binding<Bool> {
        Binding(
            get: { trackedSet.contains(tag) },
            set: { isOn in
                var set = trackedSet
                if isOn { set.insert(tag) } else { set.remove(tag) }
                // Never persist an empty set — parse() treats empty as "use the
                // default set", which would silently re-enable everything.
                if set.isEmpty { set = [.sleep] }
                let ordered = BehaviorJournalEntry.Tag.allCases.filter { set.contains($0) }
                trackedRaw = AtriaTrackedBehaviors.serialize(ordered)
            }
        )
    }
}
