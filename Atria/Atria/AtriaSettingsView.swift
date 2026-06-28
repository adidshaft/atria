import SwiftUI

/// Native iOS 26 settings hub. Uses a grouped Form over the Atria backdrop for
/// the Liquid Glass look, and folds in the community-requested differentiators
/// (no subscription, data ownership/export, custom HR-zone & strain alerts).
struct AtriaSettingsView: View {
    let profile: AthleteProfile
    let restingBaseline: Int?
    let strapName: String
    let strapModel: String
    let strapFirmware: String
    let onRenameStrap: (String) -> Void
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    let hapticSettings: AtriaHapticAlertSettings
    let onUpdateHaptics: (AtriaHapticAlertSettings) -> Void
    let batterySaverEnabled: Bool
    let onUpdateBatterySaver: (Bool) -> Void
    let onExportHealth: (() -> Void)?
    let onSyncMissedData: (() -> Void)?
    let onForgetStrap: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showForgetConfirm = false
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings
    @State private var nameDraft: String
    @State private var batterySaver: Bool
    @State private var exportTapped = false
    @State private var syncTapped = false
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
    @AppStorage(AtriaTodayMetric.storageKey) private var todayHiddenCSV = ""
    @AppStorage(AtriaTodayMetric.orderStorageKey) private var todayOrderCSV = ""
    @AppStorage(AtriaTodayMetric.sizeStorageKey) private var todaySizeCSV = ""
    @AppStorage("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AppStorage("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AppStorage("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AppStorage("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AppStorage("atria.target.load.acwr.watchLow") private var loadACWRWatchLow: Double = 0.80
    @AppStorage("atria.target.load.acwr.watchHigh") private var loadACWRWatchHigh: Double = 1.30
    @AppStorage("atria.target.load.acwr.badLow") private var loadACWRBadLow: Double = 0.60
    @AppStorage("atria.target.load.acwr.badHigh") private var loadACWRBadHigh: Double = 1.50
    @AppStorage("atria.target.load.monotony.watch") private var loadMonotonyWatch: Double = 2.0
    @AppStorage("atria.target.load.monotony.bad") private var loadMonotonyBad: Double = 2.5
    @AppStorage("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AppStorage("atria.target.calories.goal") private var caloriesGoal: Int = 500
    @AppStorage("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AppStorage("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AppStorage("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AppStorage("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AppStorage("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AppStorage("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AppStorage("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AppStorage("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AppStorage("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AppStorage("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AppStorage("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AppStorage("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @AppStorage("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AppStorage("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AppStorage("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AppStorage("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2

    /// Support destinations are shown as text only. Atria's core stays local-first
    /// with no in-app network/browser clients, so contact details are surfaced for
    /// the user to open themselves rather than launched in-app.
    private let supportHandle = "@adidshaft on X"

    init(profile: AthleteProfile,
         restingBaseline: Int?,
         strapName: String = "",
         strapModel: String = "",
         strapFirmware: String = "",
         onRenameStrap: @escaping (String) -> Void = { _ in },
         onUpdateProfile: @escaping (@escaping (inout AthleteProfile) -> Void) -> Void,
         hapticSettings: AtriaHapticAlertSettings,
         onUpdateHaptics: @escaping (AtriaHapticAlertSettings) -> Void,
         batterySaverEnabled: Bool,
         onUpdateBatterySaver: @escaping (Bool) -> Void,
         onExportHealth: (() -> Void)? = nil,
         onSyncMissedData: (() -> Void)? = nil,
         onForgetStrap: (() -> Void)? = nil) {
        self.profile = profile
        self.restingBaseline = restingBaseline
        self.strapName = strapName
        self.strapModel = strapModel
        self.strapFirmware = strapFirmware
        self.onRenameStrap = onRenameStrap
        self.onUpdateProfile = onUpdateProfile
        self.hapticSettings = hapticSettings
        self.onUpdateHaptics = onUpdateHaptics
        self.batterySaverEnabled = batterySaverEnabled
        self.onUpdateBatterySaver = onUpdateBatterySaver
        self.onExportHealth = onExportHealth
        self.onSyncMissedData = onSyncMissedData
        self.onForgetStrap = onForgetStrap
        _draft = State(initialValue: profile)
        _haptics = State(initialValue: hapticSettings)
        _nameDraft = State(initialValue: strapName)
        _batterySaver = State(initialValue: batterySaverEnabled)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop().ignoresSafeArea()
                Form {
                    profileSection
                    appearanceSection
                    todayLayoutSection
                    targetsSection
                    deviceSection
                    radioModeSection
                    sensorAvailabilitySection
                    alertsSection
                    dataSection
                    aboutSection
                }
                .scrollContentBackground(.hidden)
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
        .onChange(of: draft) { _, value in onUpdateProfile { $0 = value } }
        .onChange(of: haptics) { _, value in onUpdateHaptics(value) }
        .onChange(of: batterySaver) { _, value in onUpdateBatterySaver(value) }
        .onChange(of: targetSettingsSignature) { _, _ in normalizeAllTargets() }
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
                HStack(spacing: 8) {
                    appearanceButton("System", mode: "system", icon: "circle.lefthalf.filled")
                    appearanceButton("Light", mode: "light", icon: "sun.max.fill")
                    appearanceButton("Dark", mode: "dark", icon: "moon.fill")
                }

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

    private func appearanceButton(_ title: String, mode: String, icon: String) -> some View {
        Button {
            appearanceMode = mode
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(AtriaSegmentButtonStyle(selected: isAppearanceModeSelected(mode), tint: .purple))
        .accessibilityAddTraits(isAppearanceModeSelected(mode) ? .isSelected : [])
    }

    private func isAppearanceModeSelected(_ mode: String) -> Bool {
        appearanceMode == mode
    }

    // MARK: Profile

    private var profileSection: some View {
        Section {
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
                }
            }
            Stepper(value: $draft.heightCm, in: 0...230, step: 1) {
                LabeledContent("Height") {
                    Text(draft.heightCm > 0 ? "\(Int(draft.heightCm.rounded())) cm" : "Optional")
                        .monospacedDigit()
                }
            }
            if let restingBaseline {
                LabeledContent("Resting baseline") {
                    Text("\(restingBaseline) bpm").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text(draft.hasEnergyProfile ? "Weight enables calorie estimates." : "Add sex and weight for calories.")
        }
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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .green))

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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .green))

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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .orange))

                Divider()

                targetGroupHeader(title: "Training load",
                                  subtitle: "ACWR and monotony bands for readiness guidance.",
                                  systemImage: "chart.bar.xaxis",
                                  tint: .orange)

                Stepper(value: $loadACWRWatchLow, in: 0.50...1.00, step: 0.05) {
                    LabeledContent("ACWR low watch") {
                        Text(String(format: "%.2f", loadACWRWatchLow))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRWatchHigh, in: 1.00...1.60, step: 0.05) {
                    LabeledContent("ACWR high watch") {
                        Text(String(format: "%.2f", loadACWRWatchHigh))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRBadLow, in: 0.30...0.95, step: 0.05) {
                    LabeledContent("ACWR low red") {
                        Text(String(format: "%.2f", loadACWRBadLow))
                            .monospacedDigit()
                    }
                }

                Stepper(value: $loadACWRBadHigh, in: 1.10...2.20, step: 0.05) {
                    LabeledContent("ACWR high red") {
                        Text(String(format: "%.2f", loadACWRBadHigh))
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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .orange))

                Text("Training Load uses ACWR and monotony from saved strain. These controls tune readiness colors and guidance, not the underlying history.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                targetGroupHeader(title: "Activity",
                                  subtitle: "Daily steps and estimated active calories goals.",
                                  systemImage: "figure.walk.motion",
                                  tint: .green)

                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Steps goal") {
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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .green))

                Divider()

                targetGroupHeader(title: "Sleep",
                                  subtitle: "Duration goal and efficiency bands for sleep history.",
                                  systemImage: "bed.double.fill",
                                  tint: .cyan)

                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(String(format: "%.2g h", sleepGoalHours))
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
                    sleepEfficiencyGreenLower = 90
                    sleepEfficiencyYellowLower = 80
                } label: {
                    Label("Reset sleep targets", systemImage: "bed.double.fill")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .cyan))

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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .pink))

                Divider()

                targetGroupHeader(title: "Research vitals",
                                  subtitle: "Sleep-only respiratory, relative skin-temp, and oxygen evidence bands.",
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
                    Label("Reset research targets", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .teal))

                Text("Research targets tune sleep-only deviations and candidate-frame evidence. They do not turn these signals into validated SpO2 or absolute body-temperature readings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                targetGroupHeader(title: "Body age",
                                  subtitle: "Younger/older delta bands for the local estimate.",
                                  systemImage: "figure.stand",
                                  tint: .purple)

                Stepper(value: $biologicalAgeGreenOlderDelta, in: -10...10, step: 1) {
                    LabeledContent("Body age green") {
                        Text("\(biologicalAgeGreenOlderDelta > 0 ? "+" : "")\(biologicalAgeGreenOlderDelta)y")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $biologicalAgeYellowOlderDelta, in: -9...20, step: 1) {
                    LabeledContent("Body age yellow") {
                        Text("\(biologicalAgeYellowOlderDelta > 0 ? "+" : "")\(biologicalAgeYellowOlderDelta)y")
                            .monospacedDigit()
                    }
                }

                Button {
                    biologicalAgeGreenOlderDelta = 0
                    biologicalAgeYellowOlderDelta = 3
                } label: {
                    Label("Reset body-age target", systemImage: "figure.stand")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .purple))

                Text("Body age is a local fitness estimate from VO2max, RHR, HRV, sleep, activity, and BMI -- not a medical assessment. These bands only tune younger/older color guidance.")
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
                .buttonStyle(AtriaCardActionButtonStyle(tint: .blue))

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
        } header: {
            Text("Alerts")
        } footer: {
            Text("Phone-side alerts only.")
        }
    }

    // MARK: Data & privacy

    private var dataSection: some View {
        Section {
            settingsInfoRow(icon: "lock.shield.fill", tint: .green,
                            title: "Stays on this device",
                            detail: "No account, no cloud, no subscription. Your data never leaves your phone.")
            settingsInfoRow(icon: "hand.raised.fill", tint: .orange,
                            title: "Keep Atria running",
                            detail: "Background tracking continues when you switch apps. If you swipe Atria closed, iOS pauses tracking until you reopen it — your strap fills in the gap on reconnect.")
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
        } header: {
            Text("Your data")
        } footer: {
            Text("Local ownership, free export.")
        }
    }

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
            ForEach(AtriaTodayMetric.ordered(from: todayOrderCSV)) { metric in
                HStack(spacing: 10) {
                    Toggle(isOn: todayBinding(metric)) {
                        Label(metric.label, systemImage: metric.systemImage)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Button {
                            todayOrderCSV = AtriaTodayMetric.moving(metric, direction: -1, in: todayOrderCSV)
                        } label: {
                            Image(systemName: "chevron.up")
                                .frame(width: 28, height: 28)
                        }
                        .atriaCardAction(prominent: false, tint: .secondary)
                        .disabled(metric == AtriaTodayMetric.ordered(from: todayOrderCSV).first)
                        .accessibilityLabel("Move \(metric.label) up")

                        Button {
                            todayOrderCSV = AtriaTodayMetric.moving(metric, direction: 1, in: todayOrderCSV)
                        } label: {
                            Image(systemName: "chevron.down")
                                .frame(width: 28, height: 28)
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
                                : "Keeps richer strap streams available for beat-to-beat, HRV, Recovery and sleep research. Uses more strap battery.")
        } header: {
            Text("Radio mode")
        } footer: {
            Text("You can switch anytime. Atria reconnects the strap when the radio mode changes.")
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
                            title: "Blood oxygen research",
                            detail: "Sleep-only evidence; no SpO2 percentage or Health export yet.")
            settingsInfoRow(icon: "thermometer.variable",
                            tint: .teal,
                            title: "Body temperature research",
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
