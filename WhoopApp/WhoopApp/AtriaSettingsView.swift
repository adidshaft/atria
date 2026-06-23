import SwiftUI

/// Native iOS 26 settings hub. Uses a grouped Form over the Atria backdrop for
/// the Liquid Glass look, and folds in the community-requested differentiators
/// (no subscription, data ownership/export, custom HR-zone & strain alerts).
struct AtriaSettingsView: View {
    let profile: AthleteProfile
    let restingBaseline: Int?
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    let hapticSettings: AtriaHapticAlertSettings
    let onUpdateHaptics: (AtriaHapticAlertSettings) -> Void
    let onExportHealth: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: AthleteProfile
    @State private var haptics: AtriaHapticAlertSettings

    /// Privacy/support destinations are shown as text only. Atria's core stays
    /// local-first with no in-app network/browser clients, so contact details are
    /// surfaced for the user to open themselves rather than launched in-app.
    private let privacyComingSoon = true
    private let supportHandle = "@adidshaft on X"

    init(profile: AthleteProfile,
         restingBaseline: Int?,
         onUpdateProfile: @escaping (@escaping (inout AthleteProfile) -> Void) -> Void,
         hapticSettings: AtriaHapticAlertSettings,
         onUpdateHaptics: @escaping (AtriaHapticAlertSettings) -> Void,
         onExportHealth: (() -> Void)? = nil) {
        self.profile = profile
        self.restingBaseline = restingBaseline
        self.onUpdateProfile = onUpdateProfile
        self.hapticSettings = hapticSettings
        self.onUpdateHaptics = onUpdateHaptics
        self.onExportHealth = onExportHealth
        _draft = State(initialValue: profile)
        _haptics = State(initialValue: hapticSettings)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop().ignoresSafeArea()
                Form {
                    profileSection
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
            Text(draft.maxHRSource == .ageEstimate
                 ? "Estimated from your age. Choose Measured if you know your real max from a hard effort or lab test."
                 : "Using the max you measured — the most accurate option. Strain and effort are scored to this.")
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
            Text("Phone-side haptic and notification alerts. Atria never writes to the strap to deliver these.")
        }
    }

    // MARK: Data & privacy

    private var dataSection: some View {
        Section {
            settingsInfoRow(icon: "lock.shield.fill", tint: .green,
                            title: "Stays on this device",
                            detail: "No account, no cloud, no subscription. Your data never leaves your phone.")
            if let onExportHealth {
                Button {
                    onExportHealth()
                } label: {
                    Label("Export to Apple Health", systemImage: "square.and.arrow.up")
                }
            } else {
                settingsInfoRow(icon: "heart.text.square.fill", tint: .red,
                                title: "Apple Health export",
                                detail: "Your heart rate, workouts and sleep sync to Apple Health from the collection tools.")
            }
        } header: {
            Text("Your data")
        } footer: {
            Text("Atria gives you full ownership of your strap data — export it, back it up, and keep it forever, free.")
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
            Text("Atria is independent and unaffiliated with WHOOP. Not medical software — for personal fitness and research only.")
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
