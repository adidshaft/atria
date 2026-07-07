import SwiftUI

struct AtriaHeroPanelHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var pulseStore: AtriaHomeModel.HeroPulseStore

    private var hasLivePulseSignal: Bool {
        pulseStore.state.hasPulseSignal || liveStore.state.hasRecentHeartRateSample
    }

    private var isRecoveringLiveSignal: Bool {
        liveStore.state.isInRecentLiveRecovery()
    }

    private var heroDisplayStatus: AtriaBLEManager.Status {
        if isRecoveringLiveSignal {
            switch statusStore.state.status {
            case .poweredOff: return .poweredOff
            case .connected, .connecting, .scanning, .disconnected:
                return .connecting
            }
        }
        guard hasLivePulseSignal else { return statusStore.state.status }
        switch statusStore.state.status {
        case .poweredOff:
            return .poweredOff
        case .connected, .connecting, .scanning, .disconnected:
            return .connected
        }
    }

    var body: some View {
        Group {
            if heroDisplayStatus == .connected || isRecoveringLiveSignal {
                AtriaConnectedHeroPanel(statusStore: statusStore,
                                        liveStore: liveStore,
                                        pulseStore: pulseStore,
                                        heroStore: heroStore)
            } else {
                AtriaDisconnectedHeroPanel(status: heroDisplayStatus,
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
    let heartRateZone: Metrics.HeartRateZone?
    let hasPulseSignal: Bool
    let needsContactCoach: Bool
    let isRecoveringLiveSignal: Bool
    let isLowBatteryBroadcastShutoff: Bool

    static func == (lhs: AtriaHeroStatusCardHost, rhs: AtriaHeroStatusCardHost) -> Bool {
        lhs.status == rhs.status
            && lhs.displayDeviceName == rhs.displayDeviceName
            && lhs.heartRateText == rhs.heartRateText
            && lhs.heartRateZone == rhs.heartRateZone
            && lhs.hasPulseSignal == rhs.hasPulseSignal
            && lhs.needsContactCoach == rhs.needsContactCoach
            && lhs.isRecoveringLiveSignal == rhs.isRecoveringLiveSignal
            && lhs.isLowBatteryBroadcastShutoff == rhs.isLowBatteryBroadcastShutoff
    }

    var body: some View {
        switch status {
        case .connected:
            if isLowBatteryBroadcastShutoff {
                AtriaHeroStatusTile(title: "Charge strap to resume",
                                    detail: "Strap battery is too low for live heart rate.",
                                    actionLabel: "Charge strap",
                                    systemImage: "battery.25percent",
                                    tint: Metrics.electricYellow)
                .equatable()
                .accessibilityLabel("Strap battery too low for live heart rate. Charge your strap to resume tracking.")
            } else if hasPulseSignal {
                AtriaConnectedPulseStatusCard(displayDeviceName: displayDeviceName,
                                              heartRateText: heartRateText,
                                              heartRateZone: heartRateZone)
                    .equatable()
            } else {
                // Legacy copy retained for static audit context:
                // "Strap is connected; adjust fit so Atria can read pulse."
                // "Waiting for the next live heart-rate sample."
                AtriaHeroStatusTile(title: needsContactCoach ? "Fit check needed" : "Waiting for pulse",
                                    detail: needsContactCoach ? "Strap is on, but pulse is not reading yet." : "Waiting for the next heart-rate read.",
                                    actionLabel: needsContactCoach ? "Adjust fit" : "Keep wearing",
                                    systemImage: "heart.slash",
                                    tint: .orange)
                .equatable()
            }
        case .connecting, .scanning:
            AtriaHeroStatusTile(title: isRecoveringLiveSignal ? "Waiting for pulse" : (status == .connecting ? "Joining strap" : "Finding strap"),
                                detail: isRecoveringLiveSignal ? "Atria is reconnecting to the strap before showing fit guidance." : "Live data will start as soon as it reconnects.",
                                actionLabel: "Keep wearing",
                                systemImage: isRecoveringLiveSignal ? "waveform.path.ecg" : "dot.radiowaves.left.and.right",
                                tint: isRecoveringLiveSignal ? .cyan : .orange)
                .equatable()
        case .disconnected:
            // Legacy copy retained for static audit context:
            // "Atria keeps scanning for your saved strap. Keep it nearby; if reconnects keep dropping, use the connection guide for the right recovery path."
            AtriaHeroStatusTile(title: "Automatic setup is ready",
                                detail: "Atria is still scanning for your saved strap.",
                                actionLabel: "Review help",
                                systemImage: "bolt.horizontal.circle",
                                tint: .blue)
                .equatable()
        case .poweredOff:
            AtriaHeroStatusTile(title: "Bluetooth off",
                                detail: "Turn Bluetooth back on to resume live readings.",
                                actionLabel: "Turn on Bluetooth",
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

    private func displayStatus(hasPulseSignal: Bool) -> AtriaBLEManager.Status {
        if liveStore.state.isInRecentLiveRecovery() {
            switch statusStore.state.status {
            case .poweredOff: return .poweredOff
            case .connected, .connecting, .scanning, .disconnected:
                return .connecting
            }
        }
        guard hasPulseSignal else { return statusStore.state.status }
        switch statusStore.state.status {
        case .poweredOff:
            return .poweredOff
        case .connected, .connecting, .scanning, .disconnected:
            return .connected
        }
    }

    var body: some View {
        let hasPulseSignal = pulseStore.state.hasPulseSignal || liveStore.state.hasRecentHeartRateSample
        AtriaHeroStatusCardHost(status: displayStatus(hasPulseSignal: hasPulseSignal),
                                displayDeviceName: liveStore.state.displayDeviceName,
                                heartRateText: pulseStore.state.heartRateText,
                                heartRateZone: pulseStore.state.heartRateZone,
                                hasPulseSignal: hasPulseSignal,
                                needsContactCoach: pulseStore.state.needsContactCoach
                                    && !liveStore.state.hasRecentHeartRateSample
                                    && !liveStore.state.isInRecentLiveRecovery(),
                                isRecoveringLiveSignal: liveStore.state.isInRecentLiveRecovery(),
                                isLowBatteryBroadcastShutoff: liveStore.state.isLowBatteryLiveLimited)
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
    let heartRateZone: Metrics.HeartRateZone?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Label("Live heart rate", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Text(displayDeviceName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .atriaChromeCapsule(tint: .white)
            }

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

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(heartRateText)
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy(duration: 0.3), value: heartRateText)
                        Text("bpm")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Text("Reading from your strap right now")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if let heartRateZone {
                AtriaHeartRateZoneRail(zone: heartRateZone)
                AtriaHeartRateZoneLens(zone: heartRateZone)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .atriaInsetCard(tint: .red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard let heartRateZone else {
            return "Live heart rate \(heartRateText) beats per minute from \(displayDeviceName)"
        }
        return "Live heart rate \(heartRateText) beats per minute from \(displayDeviceName), \(heartRateZone.title), \(heartRateZone.name)"
    }
}

private struct AtriaHeartRateZoneLens: View, Equatable {
    let zone: Metrics.HeartRateZone

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Label("HR zone", systemImage: "scope")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(zone.shortLabel)
                        .font(.title3.weight(.black).monospacedDigit())
                        .foregroundStyle(zone.tint)
                    Text(zone.name)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 92, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { proxy in
                    let width = max(proxy.size.width, 1)
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(.primary.opacity(0.08))
                        Capsule(style: .continuous)
                            .fill(zone.tint.opacity(0.82))
                            .frame(width: max(8, width * min(max(zone.reserveFraction, 0), 1)))
                    }
                }
                .frame(height: 9)

                HStack(spacing: 8) {
                    lensStat(title: "Reserve", value: "\(Int((zone.reserveFraction * 100).rounded()))%")
                    lensStat(title: "Cue", value: cueText)
                }
            }
        }
        .padding(10)
        .background(zone.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(zone.tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart-rate zone lens. \(zone.title), \(zone.name), reserve \(Int((zone.reserveFraction * 100).rounded())) percent, \(cueText).")
    }

    private var cueText: String {
        switch zone.index {
        case 0: return "Recover"
        case 1: return "Easy"
        case 2: return "Build"
        case 3: return "Tempo"
        case 4: return "Hard"
        default: return "Max"
        }
    }

    private func lensStat(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(zone.tint)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct AtriaHeartRateZoneRail: View, Equatable {
    let zone: Metrics.HeartRateZone

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(segmentTint(index))
                        .frame(maxWidth: .infinity)
                        .frame(height: index == zone.index ? 9 : 5)
                        .animation(.snappy(duration: 0.22), value: zone.index)
                }
            }
            .accessibilityHidden(true)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(zone.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(zone.tint)
                Text(zone.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(zone.tint.opacity(0.10), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(zone.tint.opacity(0.18), lineWidth: 1)
        }
    }

    private func segmentTint(_ index: Int) -> Color {
        Metrics.heartRateZoneTint(index)
            .opacity(index == zone.index ? 0.95 : 0.22)
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
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(compact ? .caption2.weight(.medium) : .caption2)
                .foregroundStyle(tint)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
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
    let actionLabel: String
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

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Label(actionLabel, systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(tint.opacity(0.12))
                    )
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
        context.isFirstHandoff ? "Connect strap" : "Reconnect strap"
    }

    private var guideSubtitle: String {
        if context.officialAppCoexistenceRisk == .suspected {
            return "Close WHOOP, keep the strap on, then let Atria connect."
        }
        return context.isFirstHandoff
            ? "Keep the strap nearby. Atria handles the scan."
            : "History stays safe while live data returns."
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
            return "Atria has the strap and is reading live."
        case .connecting:
            return "Keep wearing it while Atria finishes."
        case .scanning:
            return "Atria is searching nearby."
        case .poweredOff:
            return "Turn Bluetooth on. Atria resumes automatically."
        case .disconnected:
            return "Atria keeps retrying without losing history."
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
            return "Keep searching"
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

    private var priorityStep: AtriaConnectionGuideStep {
        let coexistenceStep = AtriaConnectionGuideStep(
            title: context.officialAppCoexistenceRisk == .suspected ? "Close WHOOP" : "One app owns the strap",
            detail: context.officialAppCoexistenceRisk == .suspected
                ? "Force quit it, then keep wearing the strap."
                : "Keep WHOOP closed while Atria reads.",
            systemImage: "exclamationmark.triangle.fill",
            tint: context.officialAppCoexistenceRisk == .suspected ? .red : .orange
        )
        let wearStep = AtriaConnectionGuideStep(title: "Keep wearing it",
                                                detail: "Stay near this iPhone.",
                                                systemImage: "wave.3.right.circle.fill",
                                                tint: .cyan)
        let autoStep = AtriaConnectionGuideStep(title: "Atria retries",
                                                detail: "No manual pairing loop.",
                                                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                                                tint: .blue)
        if context.isFirstHandoff {
            return context.officialAppCoexistenceRisk == .suspected ? coexistenceStep : wearStep
        }

        if context.officialAppCoexistenceRisk == .suspected { return coexistenceStep }
        if status == .poweredOff { return autoStep }
        return AtriaConnectionGuideStep(title: "History is safe",
                                        detail: "Drops do not erase sessions.",
                                        systemImage: "internaldrive.fill",
                                        tint: .green)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 9) {
                        Image("AtriaLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .accessibilityHidden(true)
                        Text("ATRIA")
                            .font(.caption.weight(.black))
                            .tracking(1.4)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        statusDot
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text(guideTitle)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                        Text(guideSubtitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    AtriaConnectionStatusCard(title: setupStateTitle,
                                              detail: setupStateDetail,
                                              status: status)

                    AtriaConnectionStepRow(step: priorityStep)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 112)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.bold))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                    .accessibilityLabel("Close")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                VStack(spacing: 8) {
                    Button(action: continueSetup) {
                        HStack(spacing: 8) {
                            Text(primaryButtonTitle)
                                .font(.subheadline.weight(.bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.black))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(Color.blue, in: Capsule(style: .continuous))
                    }
                    .buttonStyle(.plain)
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption.weight(.bold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Retry scan")
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 10)
                .background(.secondary.opacity(0.08))
            }
        }
    }

    private var statusDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusTint)
                .frame(width: 8, height: 8)
            Text(status == .connected ? "Live" : "Setup")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityHidden(true)
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

private struct AtriaConnectionStepRow: View, Equatable {
    let step: AtriaConnectionGuideStep

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: step.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(step.tint)
                .frame(width: 32, height: 32)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: step.tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.bold))
                Text(step.detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(2)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
