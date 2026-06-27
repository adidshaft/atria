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
    @AppStorage("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AppStorage("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0

    /// Privacy/support destinations are shown as text only. Atria's core stays
    /// local-first with no in-app network/browser clients, so contact details are
    /// surfaced for the user to open themselves rather than launched in-app.
    private let privacyComingSoon = true
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
                    shortcutsSection
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
        .onChange(of: recoveryGreenLower) { _, _ in normalizeRecoveryTargets() }
        .onChange(of: recoveryYellowLower) { _, _ in normalizeRecoveryTargets() }
        .onChange(of: stepsGoal) { _, _ in normalizeStepsGoal() }
        .onChange(of: sleepGoalHours) { _, _ in normalizeSleepGoal() }
    }

    private func normalizeRecoveryTargets() {
        recoveryYellowLower = min(max(recoveryYellowLower, 5), 66)
        recoveryGreenLower = min(max(recoveryGreenLower, recoveryYellowLower + 1), 95)
    }

    private func normalizeStepsGoal() {
        stepsGoal = min(max(stepsGoal, 1_000), 30_000)
    }

    private func normalizeSleepGoal() {
        sleepGoalHours = min(max(sleepGoalHours, 4.0), 12.0)
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
                HStack(spacing: 12) {
                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(width: 38, height: 38)
                        .background(AtriaIconTileBackground(cornerRadius: 12, tint: .green))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recovery")
                            .font(.headline.weight(.semibold))
                        Text(target.summaryText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 0)
                }

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

                Stepper(value: $stepsGoal, in: 1_000...30_000, step: 500) {
                    LabeledContent("Steps goal") {
                        Text("\(stepsGoal)")
                            .monospacedDigit()
                    }
                }

                Stepper(value: $sleepGoalHours, in: 4.0...12.0, step: 0.25) {
                    LabeledContent("Sleep goal") {
                        Text(String(format: "%.2g h", sleepGoalHours))
                            .monospacedDigit()
                    }
                }

                Button {
                    sleepGoalHours = 8.0
                } label: {
                    Label("Reset sleep goal", systemImage: "bed.double.fill")
                }
                .buttonStyle(AtriaCardActionButtonStyle(tint: .cyan))

                HStack(spacing: 10) {
                    Image(systemName: "heart.text.square.fill")
                        .foregroundStyle(.pink)
                    Text("HRV and resting HR zones personalize from your 7-night baseline before warning.")
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

    // MARK: Shortcuts (stub)

    private var shortcutsSection: some View {
        Section {
            settingsInfoRow(icon: "hand.tap.fill", tint: .blue,
                            title: "Strap tap shortcuts",
                            detail: "Single / double / triple-tap actions (music, calls) are coming once tap input from the band is confirmed.")
        } header: {
            Text("Shortcuts")
        }
    }

    // MARK: Device

    // MARK: Today screen layout

    private func todayBinding(_ metric: AtriaTodayMetric) -> Binding<Bool> {
        Binding(
            get: { !AtriaTodayMetric.hidden(from: todayHiddenCSV).contains(metric.rawValue) },
            set: { visible in
                var hidden = AtriaTodayMetric.hidden(from: todayHiddenCSV)
                if visible {
                    hidden.remove(metric.rawValue)
                } else if canHideTodayMetric(metric, hidden: hidden) {
                    hidden.insert(metric.rawValue)
                }
                todayHiddenCSV = AtriaTodayMetric.hiddenStorageValue(for: hidden)
            }
        )
    }

    private func canHideTodayMetric(_ metric: AtriaTodayMetric,
                                    hidden: Set<String>? = nil) -> Bool {
        let activeHidden = hidden ?? AtriaTodayMetric.hidden(from: todayHiddenCSV)
        return AtriaTodayMetric.defaultGlanceOrder.filter { !activeHidden.contains($0.rawValue) }.count > 1
            || activeHidden.contains(metric.rawValue)
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
                    .disabled(todayBinding(metric).wrappedValue && !canHideTodayMetric(metric))

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
                            title: "ECG unavailable",
                            detail: "WHOOP 4.0 has no electrodes.")
            settingsInfoRow(icon: "gauge.with.dots.needle.50percent",
                            tint: .secondary,
                            title: "Blood pressure unavailable",
                            detail: "Requires a cuff-calibrated device.")
            settingsInfoRow(icon: "drop.degreesign",
                            tint: .cyan,
                            title: "Blood oxygen research",
                            detail: "Sleep-only probe; no Health export.")
            settingsInfoRow(icon: "thermometer.variable",
                            tint: .teal,
                            title: "Body temperature research",
                            detail: "Skin-temp deviation only; no absolute degrees C or Health export.")
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
            LabeledContent("Privacy Policy") {
                Text(privacyComingSoon ? "Coming soon" : "").foregroundStyle(.secondary)
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
