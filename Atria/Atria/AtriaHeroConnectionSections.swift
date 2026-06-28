import SwiftUI

struct AtriaHeroPanelHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let pulseStore: AtriaHomeModel.HeroPulseStore

    var body: some View {
        Group {
            if statusStore.state.status == .connected {
                AtriaConnectedHeroPanel(statusStore: statusStore,
                                        liveStore: liveStore,
                                        pulseStore: pulseStore,
                                        heroStore: heroStore)
            } else {
                AtriaDisconnectedHeroPanel(status: statusStore.state.status,
                                           hero: heroStore.state)
            }
        }
    }
}

private struct AtriaConnectedHeroPanel: View {
    let statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        // Live pulse only. Recovery / Strain / HRV scores live once, in the
        // "Today at a glance" card below — the hero no longer repeats them.
        AtriaHeroStatusCardLiveHost(statusStore: statusStore,
                                    liveStore: liveStore,
                                    pulseStore: pulseStore)
    }
}

private struct AtriaDisconnectedHeroPanel: View, Equatable {
    let status: AtriaBLEManager.Status
    let hero: AtriaHomeModel.HeroSnapshot

    private var tint: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .scanning:
            return .orange
        case .disconnected:
            return .blue
        case .poweredOff:
            return .red
        }
    }

    private var systemImage: String {
        switch status {
        case .connected:
            return "bolt.heart.fill"
        case .connecting, .scanning:
            return "dot.radiowaves.left.and.right"
        case .disconnected:
            return "bolt.horizontal.circle"
        case .poweredOff:
            return "bolt.slash.circle"
        }
    }

    private var visibleSavedDataNote: String {
        "Saved backup stays local."
    }

    private var auditSavedDataNote: String {
        "Saved metrics and backup remain on device while Atria waits for the strap again."
    }

    var body: some View {
        // Calm reassurance only — connection state is shown by the top status
        // pill, never repeated here.
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            Text(visibleSavedDataNote)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(auditSavedDataNote)
    }
}

private struct AtriaHeroHeadlineBlock: View, Equatable {
    let guidance: Coach.Guidance
    let status: AtriaBLEManager.Status
    let heroStatusTint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaHeroHeadlineBlock, rhs: AtriaHeroHeadlineBlock) -> Bool {
        lhs.guidance == rhs.guidance
            && lhs.status == rhs.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Today", systemImage: "house.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .atriaChromeCapsule(tint: .white)
                Spacer(minLength: 0)
                if status != .connected {
                    AtriaStatusChip(text: status.rawValue,
                                    systemImage: "dot.radiowaves.left.and.right",
                                    tint: heroStatusTint)
                }
            }

            Text(guidance.headline)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.98) : Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)

            Text(guidance.detail)
                .font(.caption)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.68) : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AtriaHeroHeadlineHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaHeroHeadlineBlock(guidance: displayGuidance,
                               status: statusStore.state.status,
                               heroStatusTint: heroStatusTint)
            .equatable()
    }

    private var displayGuidance: Coach.Guidance {
        let guidance = heroStore.state.guidance
        guard statusStore.state.status == .connected,
              needsConnectedDisplayGuidance(guidance) else {
            return guidance
        }

        return Coach.Guidance(headline: "Connected and reading live",
                              detail: "Atria is using the strap as your primary signal while your personal baseline finishes.",
                              color: .green,
                              target: guidance.target,
                              state: guidance.state,
                              reason: "connected_display_reconciled")
    }

    private func needsConnectedDisplayGuidance(_ guidance: Coach.Guidance) -> Bool {
        let combinedText = "\(guidance.headline) \(guidance.detail)".lowercased()
        return combinedText.contains("looking for your strap")
            || combinedText.contains("searches for your strap")
            || combinedText.contains("reconnect")
            || combinedText.contains("bluetooth")
            || combinedText.contains("guidance learning")
            || combinedText.contains("learning:")
            || combinedText.contains("need baseline")
    }

    private var heroStatusTint: Color {
        switch statusStore.state.status {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        case .disconnected: return .blue
        case .poweredOff: return .orange
        }
    }
}

private struct AtriaHeroStatusCardHost: View, Equatable {
    let status: AtriaBLEManager.Status
    let displayDeviceName: String
    let heartRateText: String
    let hasPulseSignal: Bool
    let needsContactCoach: Bool

    static func == (lhs: AtriaHeroStatusCardHost, rhs: AtriaHeroStatusCardHost) -> Bool {
        lhs.status == rhs.status
            && lhs.displayDeviceName == rhs.displayDeviceName
            && lhs.heartRateText == rhs.heartRateText
            && lhs.hasPulseSignal == rhs.hasPulseSignal
            && lhs.needsContactCoach == rhs.needsContactCoach
    }

    var body: some View {
        switch status {
        case .connected:
            if hasPulseSignal {
                AtriaConnectedPulseStatusCard(displayDeviceName: displayDeviceName,
                                              heartRateText: heartRateText)
                    .equatable()
            } else {
                AtriaHeroStatusTile(title: needsContactCoach ? "Fit check needed" : "Waiting for pulse",
                                    detail: needsContactCoach ? "Strap is connected; adjust fit so Atria can read pulse." : "Waiting for the next live heart-rate sample.",
                                    systemImage: "heart.slash",
                                    tint: .orange)
                .equatable()
            }
        case .connecting, .scanning:
            AtriaHeroStatusTile(title: status == .connecting ? "Joining strap" : "Finding strap",
                                detail: "Starting live data as soon as the strap is nearby.",
                                systemImage: "dot.radiowaves.left.and.right",
                                tint: .orange)
                .equatable()
        case .disconnected:
            AtriaHeroStatusTile(title: "Automatic setup is ready",
                                detail: "Atria keeps scanning. If the official strap app or its widget is still running, close it first so it cannot reclaim the strap.",
                                systemImage: "bolt.horizontal.circle",
                                tint: .blue)
                .equatable()
        case .poweredOff:
            AtriaHeroStatusTile(title: "Bluetooth off",
                                detail: "Turn Bluetooth back on to resume the live dashboard.",
                                systemImage: "bolt.slash.circle",
                                tint: .orange)
                .equatable()
        }
    }
}

private struct AtriaHeroStatusCardLiveHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore

    var body: some View {
        let hasPulseSignal = pulseStore.state.hasPulseSignal || liveStore.state.hasRecentHeartRateSample
        AtriaHeroStatusCardHost(status: statusStore.state.status,
                                displayDeviceName: liveStore.state.displayDeviceName,
                                heartRateText: pulseStore.state.heartRateText,
                                hasPulseSignal: hasPulseSignal,
                                needsContactCoach: pulseStore.state.needsContactCoach && !liveStore.state.hasRecentHeartRateSample)
            .equatable()
    }
}

enum AtriaDeviceDisplayName {
    static func shortName(for deviceName: String) -> String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Strap" }

        let uppercased = trimmed.uppercased()
        if uppercased.contains("WHOOP") || uppercased.contains(" WHO") {
            return "Strap"
        }

        if let apostropheIndex = trimmed.firstIndex(of: "'") {
            let ownerPrefix = trimmed[..<apostropheIndex]
            if ownerPrefix.count >= 3 {
                return String(ownerPrefix)
            }
        }

        if let firstToken = trimmed.split(separator: " ").first, firstToken.count >= 4 {
            return String(firstToken)
        }

        return String(trimmed.prefix(12))
    }
}

private struct AtriaConnectedPulseStatusCard: View, Equatable {
    let displayDeviceName: String
    let heartRateText: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "heart.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.red)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: .red))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            Spacer(minLength: 0)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(heartRateText)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .atriaInsetCard(tint: .red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live heart rate \(heartRateText) beats per minute from \(displayDeviceName)")
    }
}

private struct AtriaHeroMetricRow: View, Equatable {
    let liveStatus: AtriaBLEManager.Status
    let hero: AtriaHomeModel.HeroSnapshot

    private var metricItems: [AtriaHeroMetricItem] {
        if liveStatus == .connected {
            return [
                .init(title: "Recovery", value: hero.recoveryValue, detail: compactConnectedDetail(title: "Recovery", detail: hero.recoveryDetail), tint: .green),
                .init(title: "Strain", value: hero.strainValue, detail: compactConnectedDetail(title: "Strain", detail: hero.strainDetail), tint: .orange),
                .init(title: "HRV", value: hero.hrvValue, detail: compactConnectedDetail(title: "HRV", detail: hero.hrvDetail), tint: .pink)
            ]
        }
            return [
                .init(title: "Sessions", value: "\(hero.sessionsCount)", detail: "on device", tint: .cyan),
                .init(title: "Baseline", value: "\(hero.baselineSamples)/\(PersonalBaseline.trustedMinimumSamples)", detail: "samples", tint: .green),
                .init(title: "Backup", value: hero.backupValue, detail: compactBackupDetail, tint: .orange)
            ]
    }

    private var isCompact: Bool {
        true
    }

    private var compactBackupDetail: String {
        let normalized = hero.backupDetail.lowercased()
        if normalized.contains("no backup") {
            return "pending"
        }
        if normalized.contains("saved") {
            return "saved"
        }
        return hero.backupDetail
    }

    private func compactConnectedDetail(title: String, detail: String) -> String {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch title {
        case "Recovery":
            if normalized.contains("learning") {
                return "learning"
            }
        case "Strain":
            if normalized.contains("learning") {
                return "learning"
            }
            if normalized.contains("local") {
                return "local"
            }
        case "HRV":
            if normalized.contains("stable contact") {
                return "Beat-to-beat settling"
            }
            if normalized.contains("rr window") {
                return "Beat-to-beat window"
            }
            if normalized.contains("learning") {
                return "learning"
            }
        default:
            break
        }

        return detail
    }

    var body: some View {
        if isCompact {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: isCompact ? 10 : 12) {
                metricTiles
            }
        } else {
            HStack(spacing: 12) {
                metricTiles
            }
        }
    }

    @ViewBuilder
    private var metricTiles: some View {
        ForEach(metricItems) { item in
            AtriaHeroMetricTile(title: item.title,
                                value: item.value,
                                detail: item.detail,
                                tint: item.tint,
                                compact: isCompact)
        }
    }
}

private struct AtriaHeroMetricItem: Identifiable, Equatable {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var id: String { title }
}

private struct AtriaHeroMetricRowHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaHeroMetricRow(liveStatus: statusStore.state.status,
                           hero: heroStore.state)
            .equatable()
    }
}

private struct AtriaHeroNextActionRow: View, Equatable {
    let nextAction: String

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaHeroNextActionRow, rhs: AtriaHeroNextActionRow) -> Bool {
        lhs.nextAction == rhs.nextAction
    }

    var body: some View {
        Label(nextAction, systemImage: "arrow.forward.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.72) : .secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atriaInsetCard(tint: .cyan)
    }
}

private struct AtriaHeroNextActionHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaHeroNextActionRow(nextAction: displayNextAction)
            .equatable()
    }

    private var displayNextAction: String {
        let nextAction = heroStore.state.nextAction
        guard statusStore.state.status == .connected,
              nextAction.localizedCaseInsensitiveContains("reconnect") else {
            return nextAction
        }
        return "Keep wearing while Atria finishes your personal baseline."
    }
}

private struct AtriaHeroMetricTile: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let compact: Bool

    static func == (lhs: AtriaHeroMetricTile, rhs: AtriaHeroMetricTile) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.compact == rhs.compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: compact ? 6 : 7, height: compact ? 6 : 7)
                Text(title)
                    .font((compact ? Font.caption2 : Font.caption2).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Text(value)
                .font((compact ? Font.subheadline : Font.headline).weight(.semibold).monospacedDigit())
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(compact ? .caption2.weight(.medium) : .caption2)
                .foregroundStyle(tint)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 10 : 12)
        .atriaInsetCard(tint: tint)
    }
}

private struct AtriaHeroStatusTile: View, Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .atriaInsetCard(tint: tint.opacity(0.65))
    }
}

/// Modal card surfaced only when interference from the official strap app is suspected, instead of a
/// permanent inline card. Explains the iOS limitation and the exact fix.
struct AtriaCoexistenceModal: View {
    let context: AtriaConnectionGuideContext
    let onAcknowledge: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var coexistenceSteps: [AtriaConnectionGuideStep] {
        if context.officialAppInstalled {
            return [
                AtriaConnectionGuideStep(title: "Delete the official strap app",
                                         detail: "Press and hold the official strap app's icon → Remove App → Delete App. (recommended)",
                                         systemImage: "trash",
                                         tint: .red),
                AtriaConnectionGuideStep(title: "Or fully disable it",
                                         detail: "Log out of the official strap app, then turn off its Bluetooth and Background App Refresh in iPhone Settings.",
                                         systemImage: "powersleep",
                                         tint: .orange),
            ]
        }
        return [
            AtriaConnectionGuideStep(title: "Forget the strap in Bluetooth",
                                     detail: "Settings → Bluetooth → tap the (i) next to your strap → Forget This Device. Clears the stale pairing, then reopen Atria.",
                                     systemImage: "minus.circle",
                                     tint: .red),
            AtriaConnectionGuideStep(title: "Charge the strap",
                                     detail: "A low battery drops the link. Top it up before a workout or overnight wear.",
                                     systemImage: "battery.25",
                                     tint: .orange),
            AtriaConnectionGuideStep(title: "Restart Bluetooth",
                                     detail: "Toggle Bluetooth off and on in Settings (or Airplane Mode briefly). Restart the phone if it persists.",
                                     systemImage: "antenna.radiowaves.left.and.right",
                                     tint: .blue),
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaBackdropLayer(isDark: true, reduceTransparency: reduceTransparency)
                    .ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 38, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text(context.coexistenceTitle)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text(context.coexistenceDetail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 14) {
                            Text(context.coexistencePickLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(coexistenceSteps) { step in
                                AtriaConnectionStepTile(step: step)
                            }
                        }
                        .padding(18)
                        .atriaCard(emphasis: .soft)
                    }
                    .padding(20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                Button(action: onAcknowledge) {
                    Text("I’ll handle it")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .orange)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

private struct AtriaConnectionGuideSheet: View {
    let status: AtriaBLEManager.Status
    let context: AtriaConnectionGuideContext
    let continueSetup: () -> Void
    let retry: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var guideTitle: String {
        context.isFirstHandoff ? "Connect your strap once" : "Reconnecting is automatic"
    }

    private var guideSubtitle: String {
        if context.officialAppCoexistenceRisk == .suspected {
            return "Atria cannot kill the official strap app from inside iOS. Remove or disable the official strap app first, then reconnect here for reliable readings."
        }
        return context.isFirstHandoff
            ? "Atria scans for the strap, connects when iOS makes it available, and keeps saving data without requiring the display to stay awake."
            : "Atria keeps saved data intact while it reconnects and picks live readings back up."
    }

    private var setupStateTitle: String {
        switch status {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting to your strap"
        case .scanning:
            return "Searching nearby"
        case .poweredOff:
            return "Bluetooth needs to be on"
        case .disconnected:
            return "Ready to start setup"
        }
    }

    private var setupStateDetail: String {
        switch status {
        case .connected:
            return "Atria has the strap and will keep reconnecting and logging automatically."
        case .connecting:
            return "Keep the strap nearby while Atria finishes connecting."
        case .scanning:
            return "Atria is already searching and will widen the search on its own if the first pass misses."
        case .poweredOff:
            return "Turn Bluetooth back on, then Atria will resume the scan without extra steps."
        case .disconnected:
            return "Atria keeps retrying automatically and uses saved sessions while the live link returns."
        }
    }

    private var primaryButtonTitle: String {
        switch status {
        case .scanning, .connecting:
            return "Keep searching"
        case .poweredOff:
            return "I turned Bluetooth on"
        case .connected:
            return "Continue"
        case .disconnected:
            return "Keep searching automatically"
        }
    }

    private var statusTint: Color {
        switch status {
        case .connected:
            return .green
        case .connecting, .scanning:
            return .orange
        case .poweredOff:
            return .red
        case .disconnected:
            return .blue
        }
    }

    private var manualSteps: [AtriaConnectionGuideStep] {
        let coexistenceStep = AtriaConnectionGuideStep(
            title: context.officialAppCoexistenceRisk == .suspected ? "Remove the official strap app first" : "Check app coexistence",
            detail: context.coexistenceDetail,
            systemImage: "exclamationmark.triangle.fill",
            tint: context.officialAppCoexistenceRisk == .suspected ? .red : .orange
        )
        if context.isFirstHandoff {
            return [
                coexistenceStep,
                AtriaConnectionGuideStep(title: "Keep the strap nearby",
                                         detail: "Wear the charged strap near this iPhone so iOS can hand Atria the live stream.",
                                         systemImage: "bolt.horizontal.circle",
                                         tint: .orange),
                AtriaConnectionGuideStep(title: "Let Atria retry",
                                         detail: "Atria scans, reconnects, and recovers saved sessions without needing the screen awake.",
                                         systemImage: "app.badge.checkmark",
                                         tint: .pink),
                AtriaConnectionGuideStep(title: "Saved data stays local",
                                         detail: "Interrupted live runs are checkpointed so later syncs do not discard the session.",
                                         systemImage: "iphone.radiowaves.left.and.right",
                                         tint: .blue)
            ]
        }

        return [
            coexistenceStep,
            AtriaConnectionGuideStep(title: "Keep the strap nearby",
                                     detail: "Atria reconnects in the background as the strap and iPhone become available.",
                                     systemImage: "iphone.radiowaves.left.and.right",
                                     tint: .blue),
            AtriaConnectionGuideStep(title: "Give it a moment",
                                     detail: "Atria widens the search on its own before you need to scan again manually.",
                                     systemImage: "arrow.triangle.2.circlepath",
                                     tint: .orange),
            AtriaConnectionGuideStep(title: "Saved sessions remain",
                                     detail: "Drops do not erase already captured local sessions.",
                                     systemImage: "bolt.horizontal.circle",
                                     tint: .pink)
        ]
    }

    private var automaticItems: [String] {
        if context.officialAppCoexistenceRisk == .suspected {
            return [
                "Atria keeps saved data intact while the live BLE owner changes.",
                "Atria warns instead of pretending collection is reliable when another app may reclaim the strap.",
                "After the official strap app is removed or disabled, Atria reconnects and resumes normal collection."
            ]
        }
        if context.isFirstHandoff {
            return [
                "Atria starts scanning automatically as soon as Bluetooth is available.",
                "If the first filtered scan misses, Atria widens the search on its own.",
                "Once connected, Atria checkpoints and reconnects without requiring an unlocked screen."
            ]
        }

        return [
            "If the connection drops, Atria starts searching and reconnecting on its own.",
            "Saved sessions remain on the phone during interruptions.",
            "Your data keeps saving once the strap is back with Atria."
        ]
    }

    private var progressItems: [String] {
        [
            context.progressDetail,
            "Connection state: \(context.userStatusLabel)",
            context.actionSummary
        ]
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(guideTitle)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text(guideSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 760, alignment: .leading)

                    AtriaConnectionProgressStrip(status: status,
                                                attempts: max(context.attempts, 1),
                                                statusTint: statusTint,
                                                flowLabel: context.flowLabel)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)],
                              spacing: 12) {
                        ForEach(manualSteps) { step in
                            AtriaConnectionStepTile(step: step)
                        }
                    }

                    AtriaConnectionStatusCard(title: setupStateTitle,
                                              detail: setupStateDetail,
                                              status: status)

                    AtriaConnectionChecklistCard(
                        title: "What Atria handles automatically",
                        items: automaticItems,
                        tint: .orange
                    )

                    AtriaConnectionChecklistCard(
                        title: context.progressLabel,
                        items: progressItems,
                        tint: .green
                    )
                }
                .padding(20)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(AtriaBackdropLayer(isDark: true, reduceTransparency: reduceTransparency).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    if horizontalSizeClass == .compact {
                        VStack(spacing: 10) {
                            Button(action: continueSetup) {
                                Text(primaryButtonTitle)
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(tint: .blue)
                            Button(action: retry) {
                                Text("Retry scan now")
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(prominent: false, tint: .gray)
                        }
                    } else {
                        HStack(spacing: 10) {
                            Button(action: continueSetup) {
                                Text(primaryButtonTitle)
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(tint: .blue)
                            Button(action: retry) {
                                Text("Retry scan now")
                                    .frame(maxWidth: .infinity)
                            }
                            .atriaCardAction(prominent: false, tint: .gray)
                        }
                    }

                    Text("Setup is quick, and after the first connection Atria reconnects to your strap automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
    }
}

private struct AtriaConnectionGuideStep: Identifiable, Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var id: String { title }
}

struct AtriaConnectionGuideSheetHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let context: AtriaConnectionGuideContext
    let continueSetup: () -> Void
    let retry: () -> Void

    var body: some View {
        AtriaConnectionGuideSheet(status: statusStore.state.status,
                                  context: context,
                                  continueSetup: continueSetup,
                                  retry: retry)
    }
}

private struct AtriaConnectionProgressStrip: View, Equatable {
    let status: AtriaBLEManager.Status
    let attempts: Int
    let statusTint: Color
    let flowLabel: String
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    static func == (lhs: AtriaConnectionProgressStrip, rhs: AtriaConnectionProgressStrip) -> Bool {
        lhs.status == rhs.status
            && lhs.attempts == rhs.attempts
            && lhs.statusTint == rhs.statusTint
            && lhs.flowLabel == rhs.flowLabel
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AtriaInlineQuickStat(label: "Flow", value: flowLabel)
                    AtriaInlineQuickStat(label: "State", value: status.rawValue)
                    AtriaInlineQuickStat(label: "Try", value: "\(attempts)")
                    AtriaInlineQuickStat(label: "Mode", value: "Auto")
                }
            } else {
                HStack(spacing: 12) {
                    AtriaInlineQuickStat(label: "Flow", value: flowLabel)
                    AtriaInlineQuickStat(label: "State", value: status.rawValue)
                    AtriaInlineQuickStat(label: "Try", value: "\(attempts)")
                    AtriaInlineQuickStat(label: "Mode", value: "Auto")
                }
            }
        }
        .padding(2)
        .atriaCard(emphasis: .soft)
        .overlay {
            RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.card, style: .continuous)
                .stroke(statusTint.opacity(0.14), lineWidth: 1)
        }
    }
}

private struct AtriaConnectionStepTile: View, Equatable {
    let step: AtriaConnectionGuideStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: step.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(step.tint)
                .frame(width: 36, height: 36)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: step.tint))

            Text(step.title)
                .font(.headline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(step.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
        .padding(16)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaConnectionStatusCard: View, Equatable {
    let title: String
    let detail: String
    let status: AtriaBLEManager.Status

    private var tint: Color {
        switch status {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .scanning:
            return .cyan
        case .poweredOff:
            return .red
        case .disconnected:
            return .blue
        }
    }

    private var systemImage: String {
        switch status {
        case .connected:
            return "bolt.heart.fill"
        case .connecting:
            return "bolt.horizontal.fill"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .poweredOff:
            return "bolt.slash"
        case .disconnected:
            return "bolt.horizontal.circle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(AtriaIconTileBackground(cornerRadius: 14, tint: tint))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }
}

private struct AtriaConnectionChecklistCard: View, Equatable {
    let title: String
    let items: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.headline.weight(.semibold))
            }

            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 20, height: 20)
                        .background(AtriaChecklistBadgeBackground(tint: tint))
                        .overlay {
                            Circle()
                                .stroke(tint.opacity(0.22), lineWidth: 1)
                        }
                    Text(item)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }
}
