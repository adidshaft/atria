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
        VStack(alignment: .leading, spacing: 12) {
            AtriaHeroHeadlineHost(statusStore: statusStore,
                                  heroStore: heroStore)
            AtriaHeroStatusCardLiveHost(statusStore: statusStore,
                                        liveStore: liveStore,
                                        pulseStore: pulseStore)
            AtriaHeroMetricRowHost(statusStore: statusStore,
                                   heroStore: heroStore)
            AtriaHeroNextActionHost(heroStore: heroStore)
        }
        .padding(16)
        .atriaCard(cornerRadius: 30, emphasis: .soft)
    }
}

private struct AtriaDisconnectedHeroPanel: View, Equatable {
    let status: WhoopBLEManager.Status
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label("Connection", systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .atriaChromeCapsule(tint: tint.opacity(0.82))

                Spacer(minLength: 0)

                AtriaStatusChip(text: status.rawValue,
                                systemImage: systemImage,
                                tint: tint)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(hero.guidance.headline)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hero.guidance.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AtriaHeroStatusTile(title: "Saved data stays ready",
                                detail: "Saved metrics and backup remain on device while Atria waits for the strap again.",
                                systemImage: "internaldrive.fill",
                                tint: tint)

            AtriaHeroMetricRow(liveStatus: status, hero: hero)
                .equatable()

            AtriaHeroNextActionRow(nextAction: hero.nextAction)
                .equatable()
        }
        .padding(18)
        .atriaCard(cornerRadius: 30, emphasis: .soft)
    }
}

private struct AtriaHeroHeadlineBlock: View, Equatable {
    let guidance: Coach.Guidance
    let status: WhoopBLEManager.Status
    let heroStatusTint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaHeroHeadlineBlock, rhs: AtriaHeroHeadlineBlock) -> Bool {
        lhs.guidance == rhs.guidance
            && lhs.status == rhs.status
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Today", systemImage: "sparkles")
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
        AtriaHeroHeadlineBlock(guidance: heroStore.state.guidance,
                               status: statusStore.state.status,
                               heroStatusTint: heroStatusTint)
            .equatable()
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
    let status: WhoopBLEManager.Status
    let deviceName: String
    let heartRateText: String

    static func == (lhs: AtriaHeroStatusCardHost, rhs: AtriaHeroStatusCardHost) -> Bool {
        lhs.status == rhs.status
            && lhs.deviceName == rhs.deviceName
            && lhs.heartRateText == rhs.heartRateText
    }

    var body: some View {
        switch status {
        case .connected:
            AtriaConnectedPulseStatusCard(deviceName: deviceName,
                                          heartRateText: heartRateText)
                .equatable()
        case .connecting, .scanning:
            AtriaHeroStatusTile(title: status == .connecting ? "Joining strap" : "Finding strap",
                                detail: "Starting live data as soon as the strap is nearby.",
                                systemImage: "dot.radiowaves.left.and.right",
                                tint: .orange)
                .equatable()
        case .disconnected:
            AtriaHeroStatusTile(title: "Automatic setup is ready",
                                detail: "Atria keeps scanning with minimal interruption. Use Scan now only if you just disconnected the strap from the WHOOP app.",
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
        AtriaHeroStatusCardHost(status: statusStore.state.status,
                                deviceName: liveStore.state.deviceName,
                                heartRateText: pulseStore.state.heartRateText)
            .equatable()
    }
}

private struct AtriaConnectedPulseStatusCard: View, Equatable {
    let deviceName: String
    let heartRateText: String

    private var displayDeviceName: String {
        let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "WHOOP strap" }

        let uppercased = trimmed.uppercased()
        if uppercased.contains("WHOOP") || uppercased.contains(" WHO") {
            return "WHOOP strap"
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

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 32, height: 32)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: .green))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Live pulse")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(displayDeviceName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(heartRateText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .atriaInsetCard(cornerRadius: 17, tint: .green)
    }
}

private struct AtriaHeroMetricRow: View, Equatable {
    let liveStatus: WhoopBLEManager.Status
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
                .init(title: "Baseline", value: "\(hero.baselineSamples)/7", detail: "samples", tint: .green),
                .init(title: "Backup", value: hero.backupValue, detail: compactBackupDetail, tint: .orange)
            ]
    }

    private var isCompact: Bool {
        true
    }

    private var compactBackupDetail: String {
        let normalized = hero.backupDetail.lowercased()
        if normalized.contains("no backup") {
            return "not yet"
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
                return "stable contact"
            }
            if normalized.contains("rr window") {
                return "RR window"
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
        ViewThatFits {
            HStack(spacing: isCompact ? 10 : 12) {
                metricTiles
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: isCompact ? 10 : 12) {
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
            .atriaInsetCard(cornerRadius: 15, tint: .cyan)
    }
}

private struct AtriaHeroNextActionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaHeroNextActionRow(nextAction: heroStore.state.nextAction)
            .equatable()
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
        .atriaInsetCard(cornerRadius: compact ? 16 : 18, tint: tint)
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
        .atriaInsetCard(cornerRadius: 18, tint: tint.opacity(0.65))
    }
}

private struct AtriaConnectionGuideSheet: View {
    let status: WhoopBLEManager.Status
    let context: AtriaConnectionGuideContext
    let continueSetup: () -> Void
    let retry: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var guideTitle: String {
        context.isFirstHandoff ? "Connect your strap once" : "Reconnecting is automatic"
    }

    private var guideSubtitle: String {
        context.isFirstHandoff
            ? "Disconnect the strap from WHOOP just once. After that, Atria finds it, connects, and keeps logging in the background on its own."
            : "Atria is already connected to your strap, so there's nothing to do here — it's just reconnecting and picking your live data back up."
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
            return "Keep your phone unlocked and the strap nearby while Atria finishes connecting."
        case .scanning:
            return "Atria is already searching and will widen the search on its own if the first pass misses."
        case .poweredOff:
            return "Turn Bluetooth back on, then Atria will resume the scan without extra steps."
        case .disconnected:
            return "If WHOOP still owns the strap, disconnect it there first, then Atria can take over."
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
        if context.isFirstHandoff {
            return [
                AtriaConnectionGuideStep(title: "Free the strap",
                                         detail: "Disconnect it inside the official WHOOP app if WHOOP still owns the connection.",
                                         systemImage: "bolt.horizontal.circle",
                                         tint: .orange),
                AtriaConnectionGuideStep(title: "Fully quit WHOOP",
                                         detail: "Close the WHOOP app so it does not quietly reclaim the strap in the background.",
                                         systemImage: "app.badge.checkmark",
                                         tint: .pink),
                AtriaConnectionGuideStep(title: "Leave Atria open",
                                         detail: "Keep the phone unlocked and wake the strap by wearing it or tapping it once.",
                                         systemImage: "iphone.radiowaves.left.and.right",
                                         tint: .blue)
            ]
        }

        return [
            AtriaConnectionGuideStep(title: "Keep Atria on screen",
                                     detail: "Keep your phone unlocked while it reconnects so your live data comes back cleanly.",
                                     systemImage: "iphone.radiowaves.left.and.right",
                                     tint: .blue),
            AtriaConnectionGuideStep(title: "Give it a moment",
                                     detail: "Atria widens the search on its own before you need to scan again manually.",
                                     systemImage: "arrow.triangle.2.circlepath",
                                     tint: .orange),
            AtriaConnectionGuideStep(title: "Only free WHOOP if needed",
                                     detail: "If the WHOOP app grabbed the strap again, disconnect it there and quit WHOOP once more.",
                                     systemImage: "bolt.horizontal.circle",
                                     tint: .pink)
        ]
    }

    private var automaticItems: [String] {
        if context.isFirstHandoff {
            return [
                "Atria starts scanning automatically as soon as Bluetooth is available.",
                "If the first filtered scan misses, Atria widens the search on its own.",
                "Once you've connected the first time, Atria reconnects and keeps saving your data automatically."
            ]
        }

        return [
            "If the connection drops, Atria starts searching and reconnecting on its own.",
            "After the first time, you usually never need to re-pair or open WHOOP again.",
            "Your data keeps saving in the background once the strap is back with Atria."
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
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 10) {
                    ViewThatFits {
                        HStack(spacing: 10) {
                            Button(primaryButtonTitle, action: continueSetup)
                                .buttonStyle(.glassProminent)
        .tint(.blue)
                                .frame(maxWidth: .infinity)
                            Button("Retry scan now", action: retry)
                                .buttonStyle(.glass)
        .tint(.gray)
                        }

                        VStack(spacing: 10) {
                            Button(primaryButtonTitle, action: continueSetup)
                                .buttonStyle(.glassProminent)
        .tint(.blue)
                            Button("Retry scan now", action: retry)
                                .buttonStyle(.glass)
        .tint(.gray)
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
    let status: WhoopBLEManager.Status
    let attempts: Int
    let statusTint: Color
    let flowLabel: String

    var body: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "Flow", value: flowLabel)
                AtriaInlineQuickStat(label: "State", value: status.rawValue)
                AtriaInlineQuickStat(label: "Attempts", value: "\(attempts)")
                AtriaInlineQuickStat(label: "Mode", value: "Automatic")
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                AtriaInlineQuickStat(label: "Flow", value: flowLabel)
                AtriaInlineQuickStat(label: "State", value: status.rawValue)
                AtriaInlineQuickStat(label: "Attempts", value: "\(attempts)")
                AtriaInlineQuickStat(label: "Mode", value: "Automatic")
            }
        }
        .padding(2)
        .atriaCard(cornerRadius: 22, emphasis: .soft)
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
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
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaConnectionStatusCard: View, Equatable {
    let title: String
    let detail: String
    let status: WhoopBLEManager.Status

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
        .atriaCard(cornerRadius: 24, emphasis: .soft)
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
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}
