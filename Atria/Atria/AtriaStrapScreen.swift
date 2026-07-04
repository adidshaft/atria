import SwiftUI

struct AtriaStrapScreen: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
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
    @State private var rawExportURL: URL?
    @State private var rawExportInProgress = false
    @State private var rawExportStatus = "Full-resolution zip"

    var body: some View {
        let _ = AtriaBodyEvalProbe.tick("AtriaStrapScreen")
        VStack(alignment: .leading, spacing: 14) {
            header

            VStack(spacing: 8) {
                AtriaStrapStatusRow(title: "Connection",
                                    value: connectionValue,
                                    detail: connectionDetail,
                                    systemImage: connectionSymbol,
                                    tint: connectionTint)
                AtriaStrapStatusRow(title: "Battery",
                                    value: coreLiveStore.state.batteryText,
                                    detail: coreLiveStore.state.batteryChargeCompactText,
                                    systemImage: coreLiveStore.state.batterySymbol,
                                    tint: coreLiveStore.state.batteryShowsPowered ? .green : .cyan)
                AtriaStrapStatusRow(title: "Mode",
                                    value: collectionLiveStore.state.modeLabel,
                                    detail: collectionLiveStore.state.standardHROnlyEnabled ? "Saver cadence" : "Balanced cadence",
                                    systemImage: collectionLiveStore.state.longWearModeEnabled ? "infinity" : "waveform.path.ecg",
                                    tint: Metrics.electricSleep)
                AtriaStrapStatusRow(title: "Session",
                                    value: collectionLiveStore.state.recordingState,
                                    detail: "\(collectionLiveStore.state.capturedRows) rows",
                                    systemImage: collectionLiveStore.state.isRecording ? "record.circle.fill" : "tray.and.arrow.down.fill",
                                    tint: collectionLiveStore.state.isRecording ? .red : Metrics.electricGreen)
                AtriaStrapStatusRow(title: "Ownership",
                                    value: collectionLiveStore.state.coexistenceStatusText,
                                    detail: officialAppInstalled ? "Official app installed" : "Local control",
                                    systemImage: "checkmark.shield.fill",
                                    tint: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .red : Metrics.electricGreen)
                rawExportRow
            }
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task {
            await prepareRawExportFixtureIfNeeded()
        }
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
        Task { @MainActor in
            await Task.yield()
            let url = store.exportRawDataPackage()
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
                Text(coreLiveStore.state.displayDeviceName.isEmpty ? "WHOOP strap" : coreLiveStore.state.displayDeviceName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(primaryState)
                .font(.caption.weight(.bold))
                .foregroundStyle(connectionTint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(connectionTint.opacity(0.12), in: Capsule(style: .continuous))
        }
    }

    private var primaryState: String {
        if displayStatus == .connected {
            return coreLiveStore.state.strapStreamConnectionLabel
        }
        switch displayStatus {
        case .connected:
            return "Live"
        case .connecting, .scanning:
            return "Finding"
        case .disconnected:
            return "Off"
        case .poweredOff:
            return "Bluetooth"
        }
    }

    private var connectionDetail: String {
        if displayStatus == .connected {
            if coreLiveStore.state.strapStreamState == .live,
               pulseLiveStore.state.hasPulseSignal {
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
        return coreLiveStore.state.bluetoothPermissionDenied ? "Permission needed" : "Waiting for HR"
    }

    private var connectionValue: String {
        if displayStatus == .connected {
            return coreLiveStore.state.strapStreamConnectionLabel
        }
        switch displayStatus {
        case .connected:
            return pulseLiveStore.state.hasPulseSignal ? "Live" : "No signal"
        case .connecting:
            return "Connecting"
        case .scanning:
            return "Searching"
        case .disconnected:
            return "Disconnected"
        case .poweredOff:
            return "Bluetooth off"
        }
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
        switch statusStore.state.status {
        case .poweredOff:
            return .poweredOff
        case .connected, .connecting, .scanning, .disconnected:
            return .connected
        }
    }

    private var connectionTint: Color {
        if displayStatus == .connected {
            switch coreLiveStore.state.strapStreamState {
            case .live:
                return Metrics.electricGreen
            case .lowBatteryShutoff, .lowBatteryReducedDetail:
                return .yellow
            case .silentUnknown:
                return .orange
            case .warming, .unknown:
                return .cyan
            }
        }
        switch displayStatus {
        case .connected:
            return Metrics.electricGreen
        case .connecting, .scanning:
            return .cyan
        case .disconnected, .poweredOff:
            return .secondary
        }
    }
}

private struct AtriaStrapStatusRow: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color

    static func == (lhs: AtriaStrapStatusRow, rhs: AtriaStrapStatusRow) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.systemImage == rhs.systemImage
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                Text(detail)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Text(value)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(minHeight: 54)
        .padding(.horizontal, 12)
        .background(Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }
}
