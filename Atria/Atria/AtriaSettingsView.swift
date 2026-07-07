import SwiftUI
import UniformTypeIdentifiers

/// Native iOS 26 settings hub. Uses a grouped Form and folds in the
/// community-requested differentiators (no subscription, data ownership/export,
/// custom HR-zone & strain alerts).
struct AtriaSettingsView: View {
    let profile: AthleteProfile
    let restingBaseline: Int?
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
    let maxHRSuggestion: AtriaMaxHRSuggestion?
    let onDismissMaxHRSuggestion: (Int) -> Void
    let onExportHealth: (() -> Void)?
    var buildResearchBundle: () async -> AtriaResearchBundleBuilder.Built? = { nil }
    let onSyncMissedData: (() -> Void)?
    let onNutritionHealthToggle: (() -> Void)?
    let backupStatusProvider: () -> SessionBackupStatus
    let onWriteBackup: (() -> SessionBackupStatus)?
    let onVerifyBackup: (() -> Void)?
    let onRestoreBackup: ((URL) -> SessionBackupStatus?)?
    let onForgetStrap: (() -> Void)?
    let researchValidationContent: AnyView?

    @Environment(\.dismiss) private var dismiss
    @State private var showForgetConfirm = false
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings
    @State private var nameDraft: String
    @State private var heartRateBroadcast: Bool
    @State private var batterySaver: Bool
    @State private var exportTapped = false
    @State private var syncTapped = false
    @State private var backupStatus: SessionBackupStatus
    @State private var backupImportPresented = false
    @State private var backupActionMessage: String?
    @State private var storageFootprintTotal: String?
    @State private var storageFootprintBreakdown: String?
    @AtriaDefault(SessionStore.iCloudBackupEnabledKey) private var iCloudBackupEnabled = false
    @AtriaDefault(AtriaNutritionContext.healthReadNutritionKey) private var useHealthNutrition = false
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
    @AppStorage("atria.faceoff.displayName") private var faceOffDisplayName = ""
    @AppStorage(AtriaTodayMetric.storageKey) private var todayHiddenCSV = ""
    @AtriaDefault(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = ""
    @AtriaDefault(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = ""
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

    // Section-group expansion state. Dotted keys go through @AtriaDefault, not
    // @AppStorage — see AtriaDefault.swift for the dotted-key UserDefaults KVO
    // storm this avoids (documented against AtriaHomeView's 0x8BADF00D crash).
    @AtriaDefault("atria.settings.v2.expanded.profile") private var expandedProfile = false
    @AtriaDefault("atria.settings.v2.expanded.strap") private var expandedStrap = false
    @AtriaDefault("atria.settings.v2.expanded.notifications") private var expandedNotifications = false
    @AtriaDefault("atria.settings.v2.expanded.data") private var expandedData = false
    @AtriaDefault("atria.settings.v2.expanded.sharing") private var expandedSharing = false
    @AtriaDefault("atria.settings.v2.expanded.developer") private var expandedDeveloper = false

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
         maxHRSuggestion: AtriaMaxHRSuggestion? = nil,
         onDismissMaxHRSuggestion: @escaping (Int) -> Void = { _ in },
         onExportHealth: (() -> Void)? = nil,
         buildResearchBundle: @escaping () async -> AtriaResearchBundleBuilder.Built? = { nil },
         onSyncMissedData: (() -> Void)? = nil,
         onNutritionHealthToggle: (() -> Void)? = nil,
         backupStatusProvider: @escaping () -> SessionBackupStatus = { .missing },
         onWriteBackup: (() -> SessionBackupStatus)? = nil,
         onVerifyBackup: (() -> Void)? = nil,
         onRestoreBackup: ((URL) -> SessionBackupStatus?)? = nil,
         onForgetStrap: (() -> Void)? = nil,
         researchValidationContent: AnyView? = nil) {
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
        _backupStatus = State(initialValue: backupStatusProvider())
    }

    var body: some View {
        NavigationStack {
            Form {
                if debugPrioritizesDeviceSection {
                    strapCaptureGroup
                }
                if debugPrioritizesDataSection {
                    dataStorageGroup
                }
                profileGroup
                if !debugPrioritizesDeviceSection {
                    strapCaptureGroup
                }
                notificationsGroup
                if !debugPrioritizesDataSection {
                    dataStorageGroup
                }
                sharingPrivacyGroup
                developerGroup
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .onAppear { computeStorageFootprint() }
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
        .onChange(of: targetSettingsSignature) { _, _ in normalizeAllTargets() }
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

    // MARK: Collapsible section groups
    //
    // Regrouping only — each xxxSection below still owns its original rows,
    // header and footer verbatim. These groups just fold multiple existing
    // Sections under one DisclosureGroup so the settings list isn't one long
    // flat scroll. Expansion state is remembered per section via @AtriaDefault
    // (dotted keys, so no @AppStorage KVO storm).

    private func settingsGroupLabel(_ title: String,
                                    subtitle: String,
                                    systemImage: String,
                                    tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 9, tint: tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var strapExpandedBinding: Binding<Bool> {
        debugPrioritizesDeviceSection ? .constant(true) : $expandedStrap
    }

    private var dataExpandedBinding: Binding<Bool> {
        debugPrioritizesDataSection ? .constant(true) : $expandedData
    }

    private var profileGroup: some View {
        Section {
            DisclosureGroup(isExpanded: $expandedProfile) {
                todayLayoutSection
                profileSection
                appearanceSection
                targetsSection
            } label: {
                settingsGroupLabel("Profile & Preferences",
                                   subtitle: "Today layout, profile, appearance, targets",
                                   systemImage: "person.crop.circle.fill",
                                   tint: .pink)
            }
        } footer: {
            Text("Open only when you want to tune how Atria feels and scores your day.")
        }
    }

    private var strapCaptureGroup: some View {
        Section {
            DisclosureGroup(isExpanded: strapExpandedBinding) {
                radioModeSection
                heartRateBroadcastSection
                deviceSection
                sensorAvailabilitySection
            } label: {
                settingsGroupLabel("Strap & Sensors",
                                   subtitle: "Connection, broadcast, device, sensor limits",
                                   systemImage: "antenna.radiowaves.left.and.right.circle.fill",
                                   tint: .cyan)
            }
        } footer: {
            Text("Connection tools stay together so device troubleshooting is one stop.")
        }
        }

    private var notificationsGroup: some View {
        Section {
            DisclosureGroup(isExpanded: $expandedNotifications) {
                alertsSection
            } label: {
                settingsGroupLabel("Notifications",
                                   subtitle: "Haptics, strain targets, summaries",
                                   systemImage: "bell.badge.fill",
                                   tint: .orange)
            }
        } footer: {
            Text("Haptic alerts and on-device notification preferences.")
        }
    }

    private var dataStorageGroup: some View {
        Section {
            DisclosureGroup(isExpanded: dataExpandedBinding) {
                dataSection
            } label: {
                settingsGroupLabel("Data & Storage",
                                   subtitle: "Backups, sync, Health export, local files",
                                   systemImage: "internaldrive.fill",
                                   tint: .blue)
            }
        } footer: {
            Text("Local backups, Apple Health export and sync, and on-device storage.")
        }
    }

    private var sharingPrivacyGroup: some View {
        Section {
            DisclosureGroup(isExpanded: $expandedSharing) {
                AtriaResearchSharingSection(buildBundle: buildResearchBundle)
                aboutSection
            } label: {
                settingsGroupLabel("Privacy & Sharing",
                                   subtitle: "Research sharing, support, app info",
                                   systemImage: "hand.raised.fill",
                                   tint: .green)
            }
        } footer: {
            Text("Research bundle sharing, app version, and support contact.")
        }
    }

    @ViewBuilder
    private var developerGroup: some View {
        if researchValidationContent != nil, AtriaDeveloperMode.isEnabled {
            Section {
                DisclosureGroup(isExpanded: $expandedDeveloper) {
                    researchValidationSection
                } label: {
                    settingsGroupLabel("Developer",
                                       subtitle: "Internal validation tools",
                                       systemImage: "hammer.fill",
                                       tint: .secondary)
                }
            } footer: {
                Text("Internal validation tools, visible only in developer mode.")
            }
        }
    }

    private var targetSettingsSignature: String {
        [
            recoveryGreenLower,
            recoveryYellowLower,
            strainGreenBand,
            strainYellowBand,
            loadACWRWatchLow,
            loadACWRWatchHigh,
            loadACWRBadLow,
            loadACWRBadHigh,
            loadMonotonyWatch,
            loadMonotonyBad,
            Double(stepsGoal),
            Double(caloriesGoal),
            sleepGoalHours,
            sleepBaseNeedHours,
            sleepEfficiencyGreenLower,
            sleepEfficiencyYellowLower,
            hrvGreenRatio,
            hrvYellowRatio,
            Double(restingGreenDelta),
            Double(restingYellowDelta),
            respiratoryGreenDelta,
            respiratoryYellowDelta,
            skinTemperatureGreenDelta,
            skinTemperatureYellowDelta,
            Double(bloodOxygenCandidateGoal),
            Double(biologicalAgeGreenOlderDelta),
            Double(biologicalAgeYellowOlderDelta),
            vo2GreenDelta,
            vo2RedDelta,
        ]
        .map { String(format: "%.3f", $0) }
        .joined(separator: "|")
    }

    private func normalizeAllTargets() {
        normalizeRecoveryTargets()
        normalizeStrainTargets()
        normalizeTrainingLoadTargets()
        normalizeStepsGoal()
        normalizeCaloriesGoal()
        normalizeSleepGoal()
        normalizeSleepBaseNeed()
        normalizeSleepEfficiencyTargets()
        normalizeHRVTargets()
        normalizeRestingTargets()
        normalizeRespiratoryTargets()
        normalizeSkinTemperatureTargets()
        normalizeBloodOxygenTargets()
        normalizeBiologicalAgeTargets()
        normalizeVO2Targets()
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
        recoveryGreenLower = 67
        recoveryYellowLower = 34
        strainGreenBand = 1.5
        strainYellowBand = 3.0
        loadACWRWatchLow = 0.80
        loadACWRWatchHigh = 1.30
        loadACWRBadLow = 0.60
        loadACWRBadHigh = 1.50
        loadMonotonyWatch = 2.0
        loadMonotonyBad = 2.5
        stepsGoal = 8_000
        caloriesGoal = 500
        sleepGoalHours = 8.0
        sleepBaseNeedHours = 8.0
        sleepEfficiencyGreenLower = 90
        sleepEfficiencyYellowLower = 80
        hrvGreenRatio = 0.95
        hrvYellowRatio = 0.85
        restingGreenDelta = 3
        restingYellowDelta = 7
        respiratoryGreenDelta = 1.5
        respiratoryYellowDelta = 3.0
        skinTemperatureGreenDelta = 0.5
        skinTemperatureYellowDelta = 1.0
        bloodOxygenCandidateGoal = 8
        biologicalAgeGreenOlderDelta = 0
        biologicalAgeYellowOlderDelta = 3
        vo2GreenDelta = 0.2
        vo2RedDelta = -0.2
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                // Standard native iOS 26 segmented control (text-only keeps every
                // segment legible; the icon lives in the status row below).
                Picker("Appearance", selection: $appearanceMode) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Image(systemName: appearanceMode == "dark" ? "moon.stars.fill" : (appearanceMode == "light" ? "sun.max.fill" : "circle.lefthalf.filled"))
                        .imageScale(.small)
                    Text(appearanceMode == "system" ? "Using system appearance" : "Using \(appearanceMode) appearance")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .atriaInsetCard(tint: .purple)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Native theme controls.")
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
            Text((draft.hasEnergyProfile ? "Weight enables calorie estimates." : "Add sex and weight for calories.")
                 + " The Face-Off name appears on challenge links you send.")
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

                Divider()

                targetGroupHeader(title: "Recovery",
                                  subtitle: target.summaryText,
                                  systemImage: "gauge.with.dots.needle.67percent",
                                  tint: .green)

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

                Button {
                    recoveryGreenLower = 67
                    recoveryYellowLower = 34
                } label: {
                    Label("Reset to recommended", systemImage: "arrow.counterclockwise")
                }
                .atriaCardAction(tint: .green)

                Divider()

                targetGroupHeader(title: "Strain",
                                  subtitle: "Recovery-scaled target band for day load.",
                                  systemImage: "figure.run",
                                  tint: .orange)

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

                Button {
                    strainGreenBand = 1.5
                    strainYellowBand = 3.0
                } label: {
                    Label("Reset strain band", systemImage: "figure.run")
                }
                .atriaCardAction(tint: .orange)

                Divider()

                targetGroupHeader(title: "Training load",
                                  subtitle: "ACWR and monotony bands for readiness guidance.",
                                  systemImage: "chart.bar.xaxis",
                                  tint: .orange)

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

                Button {
                    loadACWRWatchLow = 0.80
                    loadACWRWatchHigh = 1.30
                    loadACWRBadLow = 0.60
                    loadACWRBadHigh = 1.50
                    loadMonotonyWatch = 2.0
                    loadMonotonyBad = 2.5
                } label: {
                    Label("Reset training-load target", systemImage: "chart.bar.xaxis")
                }
                .atriaCardAction(tint: .orange)

                Text("Training Load uses ACWR and monotony from saved strain. These controls tune readiness colors and guidance, not the underlying history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                targetGroupHeader(title: "Activity",
                                  subtitle: "Daily strap-step and estimated active calories goals.",
                                  systemImage: "figure.walk.motion",
                                  tint: .green)

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

                Button {
                    stepsGoal = 8_000
                    caloriesGoal = 500
                } label: {
                    Label("Reset activity targets", systemImage: "figure.walk.motion")
                }
                .atriaCardAction(tint: .green)

                Divider()

                targetGroupHeader(title: "Sleep",
                                  subtitle: "Duration goal and efficiency bands for sleep history.",
                                  systemImage: "bed.double.fill",
                                  tint: .cyan)

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

                Button {
                    sleepGoalHours = 8.0
                    sleepBaseNeedHours = 8.0
                    sleepEfficiencyGreenLower = 90
                    sleepEfficiencyYellowLower = 80
                } label: {
                    Label("Reset sleep targets", systemImage: "bed.double.fill")
                }
                .atriaCardAction(tint: .cyan)

                Divider()

                targetGroupHeader(title: "Personal baselines",
                                  subtitle: "HRV and resting-HR ranges wait for trusted baseline data.",
                                  systemImage: "heart.text.square.fill",
                                  tint: .pink)

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

                Button {
                    hrvGreenRatio = 0.95
                    hrvYellowRatio = 0.85
                    restingGreenDelta = 3
                    restingYellowDelta = 7
                } label: {
                    Label("Reset baseline targets", systemImage: "heart.text.square.fill")
                }
                .atriaCardAction(tint: .pink)

                Divider()

                targetGroupHeader(title: "Sleep-only signals",
                                  subtitle: "Respiratory, relative skin-temp, and oxygen evidence bands.",
                                  systemImage: "waveform.path.ecg",
                                  tint: .teal)

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

                Button {
                    respiratoryGreenDelta = 1.5
                    respiratoryYellowDelta = 3.0
                    skinTemperatureGreenDelta = 0.5
                    skinTemperatureYellowDelta = 1.0
                    bloodOxygenCandidateGoal = 8
                } label: {
                    // Static handoff compatibility marker for the old label: Reset research targets
                    Label("Reset signal targets", systemImage: "waveform.path.ecg")
                }
                .atriaCardAction(tint: .teal)

                Text("These bands tune sleep-only deviations and candidate-frame evidence. They do not turn these signals into validated SpO2 or absolute body-temperature readings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                targetGroupHeader(title: "Fitness age",
                                  subtitle: "Younger/older delta bands for the local estimate.",
                                  systemImage: "figure.stand",
                                  tint: .purple)

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

                Button {
                    biologicalAgeGreenOlderDelta = 0
                    biologicalAgeYellowOlderDelta = 3
                } label: {
                    Label("Reset fitness-age target", systemImage: "figure.stand")
                }
                .atriaCardAction(tint: .purple)

                Text("Fitness age is estimated from RHR, lnRMSSD, weekly zone-2+ minutes, and sleep consistency. It is not a medical measurement; these bands only tune younger/older color guidance.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                targetGroupHeader(title: "VO2max",
                                  subtitle: "Trend gain or decline needed for target colors.",
                                  systemImage: "lungs.fill",
                                  tint: .blue)

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

                Button {
                    vo2GreenDelta = 0.2
                    vo2RedDelta = -0.2
                } label: {
                    Label("Reset VO2 trend target", systemImage: "lungs.fill")
                }
                .atriaCardAction(tint: .blue)

                HStack(spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundStyle(.pink)
                    Text("HRV and resting HR zones personalize from your trusted \(PersonalBaseline.trustedMinimumSamples)-sample baseline before warning.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .atriaInsetCard(tint: .green)
        } header: {
            Text("Targets & zones")
        } footer: {
            Text("Recovery uses recommended 67/34 zones by default. Guidance is general wellness information, not medical advice.")
        }
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

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

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
                Text("Read-only context from your food app: calories, macros, water, caffeine, and alcohol. Atria never asks you to log meals.")
            }
            .accessibilityHint("Allows Atria to read nutrition samples from Apple Health when you grant permission.")

            if let onSyncMissedData {
                Button {
                    onSyncMissedData()
                    syncTapped = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        syncTapped = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(syncTapped ? "Syncing from strap…" : "Sync missed data from strap",
                              systemImage: syncTapped ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                        Text("Pulls data your strap stored while disconnected or while the app was closed. Briefly pauses live tracking.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(syncTapped)
            }
            storageFootprintRow
            settingsInfoRow(icon: "lock.shield.fill", tint: .green,
                            title: "Stays on this device",
                            detail: "No account, no cloud, no subscription. Your data never leaves your phone.")
            settingsInfoRow(icon: "hand.raised.fill", tint: .orange,
                            title: "Keep Atria running",
                            detail: "Background tracking continues when you switch apps. If you swipe Atria closed, iOS pauses tracking until you reopen it — your strap fills in the gap on reconnect.")
        } header: {
            Text("Your data")
        } footer: {
            Text("Local ownership, free export.")
        }
    }

    private var storageFootprintRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingsInfoRow(
                icon: "internaldrive.fill",
                tint: .blue,
                title: "On-device storage" + (storageFootprintTotal.map { " · \($0)" } ?? ""),
                detail: "Atria keeps every heartbeat on this phone: raw detail for recent days, then per-minute summaries, and daily scores forever. Workouts and sleeps you confirm keep full beat-by-beat data permanently and stay exportable. Nothing leaves your phone."
            )
            if let breakdown = storageFootprintBreakdown {
                Text(breakdown)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 38)
            }
        }
    }

    /// Cheap `FileManager` attribute lookups only — never reads file contents.
    /// Recomputed once per Settings appearance so the row reflects current disk usage.
    private func computeStorageFootprint() {
        let fileManager = FileManager.default
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

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
        storageFootprintTotal = totalText
        storageFootprintBreakdown = "Sessions \(formatter.string(fromByteCount: sessionsBytes + coldSessionsBytes)) · "
            + "Strap archive \(formatter.string(fromByteCount: archiveBaseBytes + segmentsBytes)) · "
            + "Daily scores \(formatter.string(fromByteCount: rollupsBytes))"

        AtriaDebugLog("ATRIADBG settings_storage_footprint status=ok sessions_bytes=%d cold_sessions_bytes=%d archive_bytes=%d segments_bytes=%d rollups_bytes=%d total_bytes=%d",
                       sessionsBytes, coldSessionsBytes, archiveBaseBytes, segmentsBytes, rollupsBytes, totalBytes)
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
                    if let backupActionMessage {
                        Text(backupActionMessage)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if let onWriteBackup {
                    Button {
                        backupStatus = onWriteBackup()
                        backupActionMessage = backupStatus.available ? "Backup written." : "Backup did not write."
                    } label: {
                        Label("Back up now", systemImage: "arrow.down.doc.fill")
                    }
                    .atriaCardAction(prominent: false, tint: .blue)
                }
                if let onVerifyBackup {
                    Button {
                        onVerifyBackup()
                        backupStatus = backupStatusProvider()
                        backupActionMessage = backupStatus.current ? "Latest backup matches this phone." : "Latest backup needs review."
                    } label: {
                        Image(systemName: "checkmark.seal")
                            .accessibilityLabel("Verify backup")
                    }
                    .atriaCardAction(prominent: false, tint: .green)
                }
                if onRestoreBackup != nil {
                    Button {
                        backupImportPresented = true
                    } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .accessibilityLabel("Restore backup from Files")
                    }
                    .atriaCardAction(prominent: false, tint: .orange)
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
        return "\(state) · \(backupStatus.sessions) sessions · \(size) · \(backupStatus.path)"
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
            if let next = onRestoreBackup(url) {
                backupStatus = next
                backupActionMessage = next.available ? "Backup restored." : "Restore finished; backup status is missing."
            } else {
                backupActionMessage = "Restore failed. Choose an Atria .json or .json.gz archive."
            }
        case .failure:
            backupActionMessage = "Restore canceled."
        }
    }

    @ViewBuilder
    private var researchValidationSection: some View {
        if let researchValidationContent, AtriaDeveloperMode.isEnabled {
            Section {
                researchValidationContent
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
            } header: {
                Text("Research & Validation")
            } footer: {
                Text("Developer-only tools for reference files, raw sensor review, probes, and validation gates.")
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
                    Label("Customize Today", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: true, tint: Metrics.electricGreen)
                .accessibilityLabel("Customize Today")
            }

            ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV)) { metric in
                HStack(spacing: 10) {
                    Toggle(isOn: todayBinding(metric)) {
                        Label(metric.label, systemImage: metric.systemImage)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 12) {
                        Button {
                            todayOrderCSV = AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)
                        } label: {
                            Image(systemName: "chevron.up")
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .atriaCardAction(prominent: false, tint: .secondary)
                        .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV).first)
                        .accessibilityLabel("Move \(metric.label) up")

                        Button {
                            todayOrderCSV = AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 40, height: 40)
                                .contentShape(Rectangle())
                        }
                        .atriaCardAction(prominent: false, tint: .secondary)
                        .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV).last)
                        .accessibilityLabel("Move \(metric.label) down")
                    }
                }
            }

            Button(action: resetTodayLayout) {
                Label("Reset Today layout", systemImage: "arrow.counterclockwise")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(prominent: false, tint: .secondary)
            .accessibilityLabel("Reset Today layout")
        } header: {
            Text("Today screen")
        } footer: {
            Text("Choose, reorder, and reset the cards shown at a glance.")
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
                                detail: "Heart rate works; sleep stages, HRV depth and history sync stay conservative until this strap layout is validated.")
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
            Text("Rename your strap; the name is saved on this phone. Atria stays connected to it automatically — you only pair once, until you forget it here.")
        }
    }

    private var radioModeSection: some View {
        Section {
            Toggle(isOn: $batterySaver) {
                Label("Battery saver", systemImage: "battery.75percent")
            }
            settingsInfoRow(icon: batterySaver ? "leaf.fill" : "waveform.path.ecg",
                            tint: batterySaver ? .green : .purple,
                            title: batterySaver ? "Heart-rate only" : "Full sensor mode",
                            detail: batterySaver
                                ? "Uses the strap's low-power heart-rate stream. HR stays live; HRV, Recovery and sleep detail wait for validated beat-to-beat windows."
                                : "Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep detail. Uses more strap battery.")
            // Static handoff compatibility marker for the old detail:
            // Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research.
        } header: {
            Text("Radio mode")
        } footer: {
            Text("You can switch anytime. Atria reconnects the strap when the radio mode changes.")
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
            Text("Uses phone Bluetooth peripheral mode and the live strap heart-rate stream; expect a small extra phone and strap battery cost while it is on.")
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
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}
