import SwiftUI

struct AtriaStrapScreen: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    let pulseLiveStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let store: SessionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @Binding var showRRImporter: Bool
    @Binding var showHRImporter: Bool
    @Binding var rrShareURL: URL?
    @Binding var hrShareURL: URL?
    @Binding var captureShareURL: URL?
    @Binding var rrImportStatus: String
    @Binding var hrImportStatus: String
    @Binding var hapticSettings: AtriaHapticAlertSettings
    let officialAppInstalled: Bool
    let developerModeEnabled: Bool
    /// Opens the status-aware connection guide sheet (owned by AtriaHomeView).
    /// Optional so previews/tests without the home context still compile.
    var onShowConnectionGuide: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var rawExportURL: URL?
    @State private var rawExportInProgress = false
    @State private var rawExportStatus = "Full-resolution zip"

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaStrapScreen")
        VStack(alignment: .leading, spacing: 14) {
            header

            AtriaStrapConnectionHero(statusStore: statusStore,
                                     coreLiveStore: coreLiveStore,
                                     pulseLiveStore: pulseLiveStore,
                                     ble: ble,
                                     onShowConnectionGuide: onShowConnectionGuide)

            LazyVGrid(columns: statusColumns, spacing: 8) {
                // Connection row removed (dedup audit 2026-07-07): the
                // state-differentiated hero above renders the identical
                // value + detail strings; the row added nothing.
                AtriaStrapStatusRow(title: "Battery",
                                    // Was an em dash, which made Battery the last
                                    // value line in the app using a different
                                    // glyph for "no reading". The pending check
                                    // accepts both, so nothing was broken -- it
                                    // just looked like a different idea.
                                    value: coreLiveStore.state.batteryLevel >= 0
                                        ? coreLiveStore.state.batteryText
                                        : AtriaCompactMetricPresentation.noValue,
                                    detail: coreLiveStore.state.batteryLevel >= 0
                                        ? coreLiveStore.state.batteryChargeCompactText : "Connect to read",
                                    systemImage: coreLiveStore.state.batterySymbol,
                                    tint: coreLiveStore.state.batteryShowsPowered ? .green : .cyan)
                AtriaStrapStatusRow(title: "Mode",
                                    value: collectionLiveStore.state.modeLabel,
                                    detail: collectionLiveStore.state.standardHROnlyEnabled ? "Saver cadence" : "Balanced cadence",
                                    systemImage: collectionLiveStore.state.longWearModeEnabled ? "infinity" : "waveform.path.ecg",
                                    tint: Metrics.electricSleep)
                AtriaStrapStatusRow(title: "Session",
                                    value: collectionLiveStore.state.recordingState,
                                    detail: capturedSamplesText,
                                    systemImage: collectionLiveStore.state.isRecording ? "record.circle.fill" : "tray.and.arrow.down.fill",
                                    tint: collectionLiveStore.state.isRecording ? .red : Metrics.electricGreen)
                // Plain words (2026-08-04): "Ownership / Strap check / Local
                // control" answered a question nobody could parse. The tile
                // exists to say whether another app is competing for the
                // strap connection.
                AtriaStrapStatusRow(title: "Strap control",
                                    value: collectionLiveStore.state.coexistenceStatusText,
                                    detail: officialAppInstalled ? "WHOOP app also installed" : "Only Atria connects",
                                    // Healthy (.cleared) carries the detail in the
                                    // tile's accessibilityLabel only; unresolved and
                                    // risk states keep it visible (declutter plan
                                    // R21, 2026-08-20).
                                    showsDetail: collectionLiveStore.state.officialAppCoexistenceRisk != .cleared,
                                    systemImage: "checkmark.shield.fill",
                                    tint: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .red : Metrics.electricGreen)
            }

            rawExportRow
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
        .task {
            await prepareRawExportFixtureIfNeeded()
        }
    }

    /// "0 rows" was storage language on an end-user screen — rows of what?
    /// `capturedRows` counts captured heart-rate samples, so it says samples,
    /// and says the zero case in words rather than as a bare count, which is
    /// how every other empty state on this screen reads.
    private var capturedSamplesText: String {
        let captured = collectionLiveStore.state.capturedRows
        guard captured > 0 else { return "No samples yet" }
        return captured == 1 ? "1 sample" : "\(captured) samples"
    }

    private var statusColumns: [GridItem] {
        let column = GridItem(.flexible(minimum: 0), spacing: 8, alignment: .top)
        return dynamicTypeSize.isAccessibilitySize ? [column] : [column, column]
    }

    private var rawExportRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Export everything")
                    .font(.subheadline.weight(.bold))
                Text(rawExportStatus)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 8)

            if rawExportInProgress {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Export in progress")
            } else if let rawExportURL {
                ShareLink(item: rawExportURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Share raw export")
            } else {
                Button {
                    exportRawDataPackageForSharing()
                } label: {
                    Image(systemName: "arrow.down.doc")
                        .font(.headline.weight(.bold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Export everything")
            }
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func exportRawDataPackageForSharing() {
        guard !rawExportInProgress else { return }
        rawExportInProgress = true
        rawExportStatus = "Writing zip..."
        rawExportURL = nil
        Task {
            let url = await store.exportRawDataPackageAsync()
            rawExportInProgress = false
            rawExportURL = url
            if let url {
                rawExportStatus = "\(url.lastPathComponent)"
            } else {
                rawExportStatus = "Export failed"
            }
        }
    }

    @MainActor
    private func prepareRawExportFixtureIfNeeded() async {
        #if DEBUG
        guard rawExportURL == nil,
              !rawExportInProgress,
              Self.debugShowsRawExportReadyFixture(arguments: ProcessInfo.processInfo.arguments) else { return }
        exportRawDataPackageForSharing()
        #endif
    }

    #if DEBUG
    private static func debugShowsRawExportReadyFixture(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "raw-export-ready"
    }
    #endif

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Strap")
                    .font(.title2.weight(.bold))
                Text(identitySubtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Header state capsule removed (dedup audit): primaryState
            // renders as the hero headline one card below.
        }
        .accessibilityHint("Atria reads the strap over Bluetooth and does not send data to WHOOP.")
    }

    /// Enriches the sanitized `displayDeviceName` (which already strips "WHOOP"
    /// to a generic "Strap" for the always-on chrome) with the detected
    /// generation from the strap's own Device Information service, when known.
    /// Falls back to the plain identity — never a guess.
    private var identitySubtitle: String {
        let hasName = !coreLiveStore.state.displayDeviceName.isEmpty
        let identity = hasName ? coreLiveStore.state.displayDeviceName : "Strap"
        let rawName = coreLiveStore.state.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeWhoop = rawName.uppercased().contains("WHOOP") || ble.strapModel != .unknown
        // When the strap isn't identified yet and has no saved name, describe the
        // device instead of echoing the "Strap" title verbatim ("Strap / Strap").
        // Also guard when the SAVED display name is itself the literal title
        // "Strap" (seen in the wild 2026-07-07): a subtitle repeating the
        // title says nothing — describe the device instead.
        guard looksLikeWhoop else {
            return hasName && identity != "Strap" ? identity : "Bluetooth heart-rate strap"
        }

        switch ble.strapModel {
        case .strapMG: return "WHOOP MG · \(identity)"
        case .strap5: return "WHOOP 5.0 · \(identity)"
        case .strap4: return "WHOOP 4.0 · \(identity)"
        case .strap4Class: return "WHOOP-class strap · \(identity)"
        case .strap3: return "WHOOP 3.0 · \(identity)"
        case .unknown: return identity
        }
    }

}

/// Keeps per-pulse connection text updates from rebuilding the export and
/// status sections below it.
private struct AtriaStrapConnectionHero: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    let ble: AtriaBLEManager
    let onShowConnectionGuide: (() -> Void)?

    @ViewBuilder
    var body: some View {
        switch displayStatus {
        case .connected:
            HStack(spacing: 12) {
                statusIcon(systemImage: connectionSymbol, tint: Metrics.electricGreen)
                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryState)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Metrics.electricGreen)
                    Text(connectionDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
            }
            .padding(14)
            .atriaInsetCard(tint: Metrics.electricGreen)
        case .connecting, .scanning:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusStore.state.isBluetoothReady
                         ? "Connecting\u{2026}"
                         : "Bluetooth recovering")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.blue)
                    Text(connectionDetail)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .atriaInsetCard(tint: .blue)
        case .disconnected, .poweredOff:
            VStack(spacing: 10) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, height: 48)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
                Text("Not connected")
                    .font(.headline.weight(.bold))
                // Short state words only (declutter plan R21, 2026-08-20).
                // The full guidance sentences are relocated verbatim to the
                // accessibilityLabel below; the "Connection guide" button
                // underneath opens the status-aware recovery steps.
                Text(disconnectedStateText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(disconnectedGuidanceSentence)
                Button {
                    ble.startScan(reason: "strap_screen_hero")
                } label: {
                    Label("Scan for strap", systemImage: "dot.radiowaves.left.and.right")
                        .font(.subheadline.weight(.bold))
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.glassProminent)
                if let onShowConnectionGuide {
                    Button("Connection guide") {
                        onShowConnectionGuide()
                    }
                    .font(.caption.weight(.bold))
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .atriaInsetCard(tint: .secondary)
        }
    }

    private func statusIcon(systemImage: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.bold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 44)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.chip, style: .continuous))
    }

    private var primaryState: String {
        guard displayStatus == .connected else { return "Finding" }
        // This screen promoted its status to .connected BECAUSE a pulse
        // exists, then read a label that could say "No signal" — one view
        // contradicting itself (owner UI-uniformity pass 2026-08-28). It now
        // applies the same shared override the Home pill does.
        if AtriaLiveSignalTruth.freshPulseOverridesLaggingStream(
            hasPulseSignal: hasPulseSignal,
            streamState: coreLiveStore.state.strapStreamState
        ) {
            return "Live"
        }
        return coreLiveStore.state.strapStreamConnectionLabel
    }

    private var connectionDetail: String {
        if displayStatus == .connected {
            // Must follow `primaryState`: when the shared override resolves the
            // label to "Live", the detail below it cannot read "Connected — no
            // live HR". Both now key off the same rule.
            if pulseLiveStore.state.hasPulseSignal,
               coreLiveStore.state.strapStreamState == .live
                || AtriaLiveSignalTruth.freshPulseOverridesLaggingStream(
                    hasPulseSignal: hasPulseSignal,
                    streamState: coreLiveStore.state.strapStreamState) {
                return "HR \(pulseLiveStore.state.heartRateText) bpm"
            }
            return coreLiveStore.state.strapStreamConnectionDetail
        }
        if pulseLiveStore.state.hasPulseSignal {
            return "HR \(pulseLiveStore.state.heartRateText) bpm"
        }
        if coreLiveStore.state.hasRecentHeartRateSample {
            return "HR \(coreLiveStore.state.lastReadingAgeText)"
        }
        if coreLiveStore.state.bluetoothPermissionDenied {
            return "Permission needed"
        }
        return statusStore.state.isBluetoothReady
            ? "Waiting for HR"
            : "Waiting for Bluetooth"
    }

    /// 3-4-word disconnected states for the hero caption (declutter plan
    /// R21, 2026-08-20). The pre-R21 full sentences survive verbatim in
    /// `disconnectedGuidanceSentence` — relocated, never deleted.
    private var disconnectedStateText: String {
        if displayStatus == .poweredOff { return "Bluetooth is off" }
        if coreLiveStore.state.bluetoothPermissionDenied { return "Bluetooth access needed" }
        if !statusStore.state.isBluetoothReady { return "Bluetooth unavailable \u{2014} retrying" }
        return "Out of range \u{2014} scanning"
    }

    /// The full guidance sentences, verbatim, carried by the shortened
    /// caption's accessibilityLabel so VoiceOver keeps the actionable copy.
    private var disconnectedGuidanceSentence: String {
        if displayStatus == .poweredOff {
            return "Turn on Bluetooth to begin \u{2014} Atria reconnects automatically."
        }
        if coreLiveStore.state.bluetoothPermissionDenied {
            return "Allow Bluetooth access in Settings, then return to Atria."
        }
        if !statusStore.state.isBluetoothReady {
            return "Bluetooth is unavailable right now. Atria will retry automatically."
        }
        return "Bring your strap into range to begin \u{2014} Atria scans automatically."
    }

    private var connectionSymbol: String {
        if displayStatus == .connected {
            return coreLiveStore.state.strapStreamConnectionSymbol
        }
        return "antenna.radiowaves.left.and.right"
    }

    private var hasPulseSignal: Bool {
        pulseLiveStore.state.hasPulseSignal || coreLiveStore.state.hasRecentHeartRateSample
    }

    private var displayStatus: AtriaBLEManager.Status {
        guard hasPulseSignal else { return statusStore.state.status }
        return statusStore.state.status == .poweredOff ? .poweredOff : .connected
    }
}

private struct AtriaStrapStatusRow: View, Equatable {
    let title: String
    let value: String
    let detail: String
    /// When false the detail line is spoken (accessibilityLabel below) but
    /// not drawn — used by the Strap control tile's healthy state
    /// (declutter plan R21, 2026-08-20).
    var showsDetail: Bool = true
    let systemImage: String
    let tint: Color

    static func == (lhs: AtriaStrapStatusRow, rhs: AtriaStrapStatusRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.showsDetail == rhs.showsDetail
            && lhs.systemImage == rhs.systemImage
    }

    // Reads icon, then what this is, then what it says — the order every
    // other status surface in the app uses (AtriaTodayLivePill puts the
    // caption above the value, so do the glance tiles and the Vitals stat
    // header). This tile had the value alone on the top row and the title
    // beneath it, so you read "All-day wear" before learning it was the
    // Mode, and "Idle" before learning it was the Session. The tile's own
    // accessibilityLabel is already "title, value, detail": VoiceOver has
    // been reading it title-first the whole time, and only the visual order
    // disagreed.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 4)
            }

            Text(value)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsDetail {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .padding(10)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}
