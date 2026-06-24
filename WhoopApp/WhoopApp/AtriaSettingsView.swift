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
    let onExportHealth: (() -> Void)?
    let onSyncMissedData: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings
    @State private var nameDraft: String
    @State private var exportTapped = false
    @State private var syncTapped = false

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
         onExportHealth: (() -> Void)? = nil,
         onSyncMissedData: (() -> Void)? = nil) {
        self.profile = profile
        self.restingBaseline = restingBaseline
        self.strapName = strapName
        self.strapModel = strapModel
        self.strapFirmware = strapFirmware
        self.onRenameStrap = onRenameStrap
        self.onUpdateProfile = onUpdateProfile
        self.hapticSettings = hapticSettings
        self.onUpdateHaptics = onUpdateHaptics
        self.onExportHealth = onExportHealth
        self.onSyncMissedData = onSyncMissedData
        _draft = State(initialValue: profile)
        _haptics = State(initialValue: hapticSettings)
        _nameDraft = State(initialValue: strapName)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop().ignoresSafeArea()
                Form {
                    profileSection
                    deviceSection
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
            if let restingBaseline {
                LabeledContent("Resting baseline") {
                    Text("\(restingBaseline) bpm").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Profile")
        } footer: {
            Text(draft.maxHRSource == .ageEstimate ? "Age estimate; measured is better." : "Measured max drives strain.")
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        Section {
            Toggle("Heart-rate zone alerts", isOn: $haptics.heartRateZones)
            Toggle("Strain target reached", isOn: $haptics.strainTarget)
            Toggle("Recovery is ready", isOn: $haptics.recoveryReady)
            Toggle("Incoming calls", isOn: $haptics.incomingCalls)
            Toggle("Low strap battery", isOn: $haptics.lowBattery)
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
                Text(strapModel.isEmpty ? "WHOOP strap" : strapModel)
                    .foregroundStyle(.secondary)
            }
            if !strapFirmware.isEmpty {
                LabeledContent("Firmware") {
                    Text(strapFirmware).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        } header: {
            Text("Device")
        } footer: {
            Text("Rename your strap; the name is saved on this phone. Model is detected automatically when available.")
        }
    }

    // MARK: About

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
