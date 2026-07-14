import SwiftUI
import UniformTypeIdentifiers

/// Native iOS 26 settings hub. Uses a grouped Form and folds in the
/// community-requested differentiators (no subscription, data ownership/export,
/// custom HR-zone & strain alerts).
struct AtriaSettingsView: View {
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
            case .personal: "Profile, appearance, Today layout, and goals"
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
    var myWeeklyRecovery: Int? = nil
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
    var buildResearchBundle: () async -> AtriaResearchBundleBuilder.Built? = { nil }
    let onSyncMissedData: (() -> Void)?
    let onNutritionHealthToggle: (() -> Void)?
    let backupStatusProvider: () -> SessionBackupStatus
    /// Starts a required backup on the store's serial utility worker. The
    /// completion is MainActor-isolated so Settings only performs the small UI
    /// state commit after encoding, compression and file I/O have finished.
    let onWriteBackup: ((@escaping @MainActor (SessionBackupStatus) -> Void) -> Void)?
    let onVerifyBackup: (() -> Void)?
    let onRestoreBackup: ((URL) -> SessionBackupStatus?)?
    let onForgetStrap: (() -> Void)?
    /// The developer validation surface is intentionally a factory. Building
    /// its large observation graph while the Settings sheet is animating can
    /// miss the scene watchdog on a device with a live strap stream.
    let researchValidationContent: (() -> AnyView)?

    @Environment(\.dismiss) private var dismiss
    @State private var showForgetConfirm = false
    @State private var showLeaderboard = false
    @State private var showSparring = false
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings
    @State private var nameDraft: String
    @State private var heartRateBroadcast: Bool
    @State private var batterySaver: Bool
    @State private var coachSettings: AtriaAICoachSettings
    @State private var coachHasAPIKey: Bool
    @State private var coachAPIKeyDraft = ""
    @State private var exportTapped = false
    @State private var syncTapped = false
    @State private var backupStatus: SessionBackupStatus
    @State private var backupImportPresented = false
    @State private var backupActionMessage: String?
    @State private var backupFeedbackTone = BackupFeedbackTone.neutral
    @State private var backupWriteInProgress = false
    @State private var didLoadBackupStatus = false
    @State private var storageFootprintTotal: String?
    @State private var navigationPath = NavigationPath()
    @AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false
    @AtriaDefault(AtriaNutritionContext.healthReadNutritionKey) private var useHealthNutrition = false
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
    @AtriaDefault("atria.faceoff.displayName") private var faceOffDisplayName = ""
    @AppStorage(AtriaTodayMetric.storageKey) private var todayHiddenCSV = ""
    @AtriaDefault(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = ""
    @AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = ""

    /// Support destinations are shown as text only. Atria's core stays local-first
    /// with no in-app network/browser clients, so contact details are surfaced for
    /// the user to open themselves rather than launched in-app.
    private let supportHandle = "@adidshaft on X"

    init(profile: AthleteProfile,
         restingBaseline: Int?,
         myWeeklyRecovery: Int? = nil,
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
         onSyncMissedData: (() -> Void)? = nil,
         onNutritionHealthToggle: (() -> Void)? = nil,
         backupStatusProvider: @escaping () -> SessionBackupStatus = { .missing },
         onWriteBackup: ((@escaping @MainActor (SessionBackupStatus) -> Void) -> Void)? = nil,
         onVerifyBackup: (() -> Void)? = nil,
         onRestoreBackup: ((URL) -> SessionBackupStatus?)? = nil,
         onForgetStrap: (() -> Void)? = nil,
         researchValidationContent: (() -> AnyView)? = nil) {
        self.profile = profile
        self.restingBaseline = restingBaseline
        self.myWeeklyRecovery = myWeeklyRecovery
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
        self.onSyncMissedData = onSyncMissedData
        self.onNutritionHealthToggle = onNutritionHealthToggle
        self.backupStatusProvider = backupStatusProvider
        self.onWriteBackup = onWriteBackup
        self.onVerifyBackup = onVerifyBackup
        self.onRestoreBackup = onRestoreBackup
        self.onForgetStrap = onForgetStrap
        self.researchValidationContent = researchValidationContent
        _draft = State(initialValue: profile)
        _haptics = State(initialValue: hapticSettings)
        _nameDraft = State(initialValue: strapName)
        _heartRateBroadcast = State(initialValue: heartRateBroadcastEnabled)
        _batterySaver = State(initialValue: batterySaverEnabled)
        _coachSettings = State(initialValue: aiCoachSettings)
        _coachHasAPIKey = State(initialValue: aiCoachHasAPIKey)
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
                    dataSection
                }
                settingsHub
            }
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
            // Value navigation keeps all five destination view graphs out of
            // the first presentation frame. SwiftUI asks for exactly one page
            // only after the user selects it.
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .personal:
                    personalSettingsPage
                case .strap:
                    strapSettingsPage
                case .alerts:
                    alertsSettingsPage
                case .data:
                    dataSettingsPage
                case .privacy:
                    privacySettingsPage
                case .developer:
                    developerSettingsPage
                }
            }
        }
        .onChange(of: draft) { _, value in onUpdateProfile { $0 = value } }
        // Keep the editable form in sync with the source of truth. Without this,
        // `draft` was seeded once at init; if the stored profile changed after
        // the sheet appeared (e.g. it finished loading, or a measured max-HR
        // landed), the form kept showing the stale/default values — reading as
        // "my details never saved". The guard avoids a redundant write-back loop
        // (the user's own edits already made profile == draft).
        .onChange(of: profile) { _, newValue in
            if newValue != draft { draft = newValue }
        }
        .onChange(of: haptics) { _, value in onUpdateHaptics(value) }
        .onChange(of: heartRateBroadcast) { _, value in onUpdateHeartRateBroadcast(value) }
        .onChange(of: batterySaver) { _, value in onUpdateBatterySaver(value) }
        .onChange(of: aiCoachSettings) { _, value in
            if value != coachSettings { coachSettings = value }
        }
        .onChange(of: aiCoachHasAPIKey) { _, value in coachHasAPIKey = value }
        .onChange(of: useHealthNutrition) { _, enabled in
            if enabled {
                onNutritionHealthToggle?()
            }
        }
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

    private func settingsGroupLabel(_ destination: Destination) -> some View {
        HStack(spacing: 10) {
            Image(systemName: destination.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(destination.tint)
                .frame(width: 26, height: 26)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: destination.tint))
            Text(destination.title)
                .font(.subheadline.weight(.semibold))
        }
        .frame(minHeight: 44)
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
                .accessibilityHint(destination.accessibilityHint)
            }
        }
    }

    private var visibleDestinations: [Destination] {
        Destination.allCases.filter { destination in
            destination != .developer
                || researchValidationContent != nil
        }
    }

    private var personalSettingsPage: some View {
        compactSettingsForm(title: "Personal") {
            todayLayoutSection
            profileSection
            appearanceSection
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
            }
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
        heartRateBroadcastSection
        deviceSection
        sensorAvailabilitySection
    }

    private var alertsSettingsPage: some View {
        compactSettingsForm(title: "Alerts") {
            alertsSection
        }
    }

    private var dataSettingsPage: some View {
        compactSettingsForm(title: "Data") {
            dataSection
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
            AtriaResearchSharingSection(buildBundle: buildResearchBundle)
            Section {
                leaderboardRow
                sparringRow
            } header: {
                Text("Community")
            }
            aboutSection
        }
    }

    @ViewBuilder
    private var developerSettingsPage: some View {
        compactSettingsForm(title: "Developer") {
            researchValidationSection
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

    /// Entry to the leaderboard demo (2026-07-08). Self-contained button +
    /// sheet so it needs no Form-level plumbing.
    private var leaderboardRow: some View {
        Button {
            showLeaderboard = true
        } label: {
            HStack {
                Label("Leaderboard", systemImage: "trophy.fill")
                Spacer(minLength: 8)
                Text("Preview")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.orange.opacity(0.16), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .sheet(isPresented: $showLeaderboard) {
            AtriaLeaderboardScreen(myWeeklyRecovery: myWeeklyRecovery)
        }
    }

    /// Entry to the sparring demo (2026-07-08), sibling of the leaderboard.
    private var sparringRow: some View {
        Button {
            showSparring = true
        } label: {
            HStack {
                Label("Sparring", systemImage: "figure.fencing")
                Spacer(minLength: 8)
                Text("Preview")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.purple.opacity(0.16), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .sheet(isPresented: $showSparring) {
            AtriaSparringScreen(myWeeklyRecovery: myWeeklyRecovery)
        }
    }


    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            Picker("Appearance", selection: $appearanceMode) {
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

    private var profileSection: some View {
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
            TextField("Face-Off name", text: $faceOffDisplayName)
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
                    draft.measuredMaxHR = suggestion.observedPeak
                    draft.maxHRSource = .measured
                    onUpdateProfile {
                        $0.measuredMaxHR = suggestion.observedPeak
                        $0.maxHRSource = .measured
                    }
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
        } footer: {
            Text("Phone-side alerts and on-device notifications only. Nothing leaves your phone.")
        }
    }

    // MARK: Data & privacy

    private var dataSection: some View {
        Section {
            backupArchiveRow
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

            Toggle(isOn: $useHealthNutrition) {
                Label("Use nutrition from Apple Health", systemImage: "fork.knife.circle.fill")
            }
            .accessibilityHint("Read-only calories, macros, water, caffeine, and alcohol from Apple Health when you grant permission. Atria never asks you to log meals.")

            if let onSyncMissedData {
                Button {
                    onSyncMissedData()
                    syncTapped = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        syncTapped = false
                    }
                } label: {
                    Label(syncTapped ? "Syncing from strap…" : "Sync missed data from strap",
                          systemImage: syncTapped ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                }
                .disabled(syncTapped)
                .accessibilityHint("Pulls data stored by the strap while disconnected or closed. Briefly pauses live tracking.")
            }
            storageFootprintRow
        } header: {
            Text("Your data")
        }
    }

    private var storageFootprintRow: some View {
        settingsInfoRow(
            icon: "internaldrive.fill",
            tint: .blue,
            title: "Storage" + (storageFootprintTotal.map { " · \($0)" } ?? ""),
            detail: "Stored locally and exportable."
        )
    }

    private struct StorageFootprint: Sendable {
        let totalText: String
        let sessionsBytes: Int64
        let coldSessionsBytes: Int64
        let archiveBaseBytes: Int64
        let segmentsBytes: Int64
        let rollupsBytes: Int64

        var totalBytes: Int64 {
            sessionsBytes + coldSessionsBytes + archiveBaseBytes + segmentsBytes + rollupsBytes
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
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            var total: Int64 = 0
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(values?.fileSize ?? 0)
            }
            return total
        }

        let sessionsBytes = size(of: documents.appendingPathComponent("sessions.json"))
        let coldSessionsBytes = size(of: documents.appendingPathComponent("sessions-cold.json"))
        let archiveDirectory = documents.appendingPathComponent("atria-historical", isDirectory: true)
        let archiveBaseBytes = size(of: archiveDirectory.appendingPathComponent("historical-archive.jsonl"))
        let segmentsBytes = directorySize(archiveDirectory.appendingPathComponent("segments", isDirectory: true))
        let rollupsBytes = size(of: documents.appendingPathComponent("daily-rollups.json"))

        let totalBytes = sessionsBytes + coldSessionsBytes + archiveBaseBytes + segmentsBytes + rollupsBytes

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let totalText = formatter.string(fromByteCount: totalBytes)
        return StorageFootprint(totalText: totalText,
                                sessionsBytes: sessionsBytes,
                                coldSessionsBytes: coldSessionsBytes,
                                archiveBaseBytes: archiveBaseBytes,
                                segmentsBytes: segmentsBytes,
                                rollupsBytes: rollupsBytes)
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

    private var backupArchiveRow: some View {
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
                            if backupWriteInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Label(backupWriteInProgress ? "Backing up…" : "Back up now",
                                  systemImage: "arrow.down.doc.fill")
                        }
                    }
                    .atriaCardAction(prominent: false, tint: .blue)
                    .disabled(backupWriteInProgress)
                }
                if let onVerifyBackup {
                    Button {
                        onVerifyBackup()
                        backupStatus = backupStatusProvider()
                        backupActionMessage = backupStatus.current ? "Latest backup matches this phone." : "Latest backup needs review."
                        backupFeedbackTone = backupStatus.current ? .success : .failure
                    } label: {
                        Image(systemName: "checkmark.seal")
                            .accessibilityLabel("Verify backup")
                    }
                    .atriaCardAction(prominent: false, tint: .green)
                    .disabled(backupWriteInProgress)
                }
                if onRestoreBackup != nil {
                    Button {
                        backupImportPresented = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .accessibilityLabel("Restore backup from Files")
                    }
                    .atriaCardAction(prominent: false, tint: .orange)
                    .disabled(backupWriteInProgress)
                }
            }
            .labelStyle(.titleAndIcon)

            Toggle(isOn: $iCloudBackupEnabled) {
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
        return "\(state) · \(backupStatus.sessions) sessions · \(size)"
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
        guard !backupWriteInProgress else { return }
        backupWriteInProgress = true
        backupActionMessage = nil
        backupFeedbackTone = .neutral

        writer { status in
            backupWriteInProgress = false
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
            guard let url = urls.first, let onRestoreBackup else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            if let next = onRestoreBackup(url) {
                backupStatus = next
                backupActionMessage = next.available ? "Backup restored." : "Restore finished; backup status is missing."
                backupFeedbackTone = next.available ? .success : .failure
            } else {
                backupActionMessage = "Restore failed. Choose an Atria .json or .json.gz archive."
                backupFeedbackTone = .failure
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

    private func todayBinding(_ metric: AtriaTodayMetric) -> Binding<Bool> {
        Binding(
            get: { !AtriaTodayMetric.hidden(from: todayHiddenCSV).contains(metric.rawValue) },
            set: { visible in
                var hidden = AtriaTodayMetric.hidden(from: todayHiddenCSV)
                if visible {
                    hidden.remove(metric.rawValue)
                } else {
                    hidden.insert(metric.rawValue)
                }
                todayHiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)
            }
        )
    }

    private func resetTodayLayout() {
        todayOrderCSV = AtriaTodayMetric.defaultGlanceOrder.map(\.rawValue).joined(separator: ",")
        todayHiddenCSV = ""
        todaySizeCSV = ""
    }

    private var todayLayoutSection: some View {
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
                ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV)) { metric in
                    HStack(spacing: 10) {
                        Toggle(isOn: todayBinding(metric)) {
                            Label(metric.label, systemImage: metric.systemImage)
                        }

                        Spacer(minLength: 0)

                        Menu {
                            Button {
                                todayOrderCSV = AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)
                            } label: {
                                Label("Move up", systemImage: "arrow.up")
                            }
                            .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV).first)

                            Button {
                                todayOrderCSV = AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)
                            } label: {
                                Label("Move down", systemImage: "arrow.down")
                            }
                            .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV).last)
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
                Button(action: resetTodayLayout) {
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
        } footer: {
            Text("Name is local. Atria reconnects automatically.")
        }
    }

    private var radioModeSection: some View {
        Section {
            Toggle(isOn: $batterySaver) {
                Label("Stable sensor mode", systemImage: "antenna.radiowaves.left.and.right")
            }
            settingsInfoRow(icon: batterySaver ? "waveform.path.ecg" : "wrench.and.screwdriver.fill",
                            tint: batterySaver ? .green : .orange,
                            title: batterySaver ? "Heart rate + strap motion" : "Diagnostic full protocol",
                            detail: batterySaver
                                ? "Recommended. Keeps live heart rate and strap-native steps on the physically verified minimal connection. Atria never substitutes phone motion."
                                : "Enables additional proprietary streams for diagnostics. This may be less stable and use more strap battery.")
            // Static handoff compatibility marker for the old detail:
            // Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.
        } header: {
            Text("Strap connection")
        } footer: {
            Text("Atria reconnects the strap when the radio mode changes.")
        }
    }

    private var heartRateBroadcastSection: some View {
        Section {
            Toggle(isOn: $heartRateBroadcast) {
                Label("Broadcast heart rate", systemImage: "antenna.radiowaves.left.and.right")
            }
            settingsInfoRow(icon: "dot.radiowaves.left.and.right",
                            tint: .cyan,
                            title: heartRateBroadcast ? "Atria HR visible" : "Gym pairing ready",
                            detail: heartRateBroadcast
                                ? "Atria advertises as Atria HR for treadmills, bikes and training apps."
                                : "Turn on during a workout, or keep it available from Settings.")
        } header: {
            Text("Heart rate broadcast")
        } footer: {
            Text("Uses live strap HR and a little extra battery.")
        }
    }

    // MARK: About

    private var sensorAvailabilitySection: some View {
        Section {
            settingsInfoRow(icon: "waveform.path.ecg",
                            tint: .secondary,
                            title: "ECG not supported",
                            detail: "WHOOP 4.0 has no electrodes, so Atria does not fake an ECG.")
            settingsInfoRow(icon: "gauge.with.dots.needle.50percent",
                            tint: .secondary,
                            title: "Blood pressure not supported",
                            detail: "WHOOP 4.0 is not cuff-calibrated, so Atria does not estimate BP.")
                settingsInfoRow(icon: "drop.degreesign",
                            tint: .cyan,
                            title: "Blood oxygen signal",
                            detail: "Sleep-only evidence; no SpO2 percentage or Health export yet.")
                settingsInfoRow(icon: "thermometer.variable",
                            tint: .teal,
                            title: "Body temperature signal",
                            detail: "Skin-temp deviation only; no absolute body temperature or Health export.")
        } header: {
            Text("Sensors")
        } footer: {
            Text("Atria shows only hardware-backed readings.")
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

/// The advanced target editor owns its defaults only after the user opens
/// Personal > Advanced targets. Keeping these DynamicProperty boxes out of
/// AtriaSettingsView prevents the Settings gear from constructing and
/// registering an off-screen observation graph on the presentation frame.
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
                                  tint: .green,
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
                                  tint: .orange,
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
                                  tint: .orange,
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
                                  tint: .green,
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
                                  tint: .cyan,
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
                                  tint: .pink,
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
                                  tint: .teal,
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
                                  tint: .purple,
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
                                  tint: .blue,
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
                                   tint: Color,
                                   resetTitle: String,
                                   onReset: @escaping () -> Void) -> some View {
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
        }
        .accessibilityHint("Restores the recommended \(title.lowercased()) values")
    }
}
