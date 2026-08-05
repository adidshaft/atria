import SwiftUI

// 2026-08-06 audit fix (dead-surfaces): the legacy hero connection panel was
// deleted here — AtriaHeroPanelHost, the connected/disconnected hero cards,
// the headline/metric/next-action hosts, and AtriaHeartRateZoneLens/Rail had
// zero references after the showsHero parameter and the sole mount were
// removed from AtriaHomeView (the audit's "feature flag stuck off" finding,
// option A). The live replacements are the top-chrome status chip
// (AtriaHomeTopChrome), the Today live pills incl. the HR-zone pill
// (AtriaTodayLiveStatusStrip), and the workout zone evidence strip
// (AtriaWorkoutZoneEvidenceStrip). Only the still-mounted pieces remain in
// this file: AtriaDeviceDisplayName, AtriaCoexistenceModal, and the
// connection guide sheet family.

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
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
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
            // The guide can prove the BLE link, not a fresh pulse. The
            // top-level live surfaces promote this to "Live" only after
            // accepted heart-rate evidence arrives.
            Text(status == .connected ? "Connected" : "Setup")
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
