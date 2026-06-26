import SwiftUI

struct AtriaVitalsTabContent: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileStore: AtriaHomeModel.ProfileStore
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let store: SessionStore
    let ble: AtriaBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?
    @AppStorage(AtriaVitalsSection.orderStorageKey) private var sectionOrderCSV = ""

    var body: some View {
        let sections = AtriaVitalsSection.ordered(from: sectionOrderCSV)
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        ForEach(sections.enumeratedColumn(0)) { section in
                            sectionCard(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        ForEach(sections.enumeratedColumn(1)) { section in
                            sectionCard(section)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    ForEach(sections) { section in
                        sectionCard(section)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionCard(_ section: AtriaVitalsSection) -> some View {
        Group {
            switch section {
            case .pulse: pulseCard
            case .hrv: hrvCard
            case .recoveryStrain: recoveryStrainCard
            case .profile: profileCard
            }
        }
        .draggable(section.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first,
                  let dragged = AtriaVitalsSection(rawValue: raw) else { return false }
            sectionOrderCSV = AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)
            return true
        }
    }

    private var pulseCard: some View {
        AtriaVitalsPulseCardHost(liveStore: liveStore,
                                 pulseStore: pulseStore,
                                 homeStatsStore: homeStatsStore,
                                 pulseSparklineStore: pulseSparklineStore)
    }

    private var hrvCard: some View {
        AtriaVitalsHRVCardHost(liveStore: liveStore,
                               heroStore: heroStore)
    }

    private var recoveryStrainCard: some View {
        AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore)
    }

    private var profileCard: some View {
        AtriaVitalsProfileCardHost(pulseStore: pulseStore,
                                   profileStore: profileStore,
                                   profileMetricsStore: profileMetricsStore,
                                   onUpdateProfile: store.updateProfile)
    }
}

enum AtriaVitalsSection: String, CaseIterable, Identifiable {
    case pulse, hrv, recoveryStrain, profile

    var id: String { rawValue }

    static let orderStorageKey = "atria.vitals.sectionOrderCSV"

    static func ordered(from csv: String) -> [AtriaVitalsSection] {
        let decoded = csv.split(separator: ",").compactMap { AtriaVitalsSection(rawValue: String($0)) }
        var result: [AtriaVitalsSection] = []
        var seen = Set<AtriaVitalsSection>()
        for section in decoded + allCases {
            guard !seen.contains(section) else { continue }
            result.append(section)
            seen.insert(section)
        }
        return result
    }

    static func moving(_ dragged: AtriaVitalsSection, before target: AtriaVitalsSection, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }
}

private extension Array where Element == AtriaVitalsSection {
    func enumeratedColumn(_ column: Int) -> [AtriaVitalsSection] {
        enumerated().compactMap { index, section in
            index % 2 == column ? section : nil
        }
    }
}

struct AtriaCollectionTabContent: View {
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    let collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let profileStore: AtriaHomeModel.ProfileStore
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
    let developerModeEnabled: Bool

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        captureCard
                        if developerModeEnabled {
                            rrReferenceCard
                            hrReferenceCard
                            imuAuditCard
                            researchManeuverCard
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        collectionControlsCard
                        collectionStatusCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    captureCard
                    if developerModeEnabled {
                        rrReferenceCard
                        hrReferenceCard
                        imuAuditCard
                        researchManeuverCard
                    }
                    collectionControlsCard
                    collectionStatusCard
                }
            }
        }
    }

    private var captureCard: some View {
        AtriaCollectionCaptureCardHost(collectionLiveStore: collectionLiveStore,
                                       ble: ble,
                                       captureShareURL: $captureShareURL)
    }

    private var rrReferenceCard: some View {
        AtriaCollectionRRReferenceCardHost(homeStatsStore: homeStatsStore,
                                           store: store,
                                           showRRImporter: $showRRImporter,
                                           rrShareURL: $rrShareURL,
                                           rrImportStatus: rrImportStatus)
    }

    private var hrReferenceCard: some View {
        AtriaCollectionHRReferenceCardHost(snapshotStore: snapshotStore,
                                           store: store,
                                           showHRImporter: $showHRImporter,
                                           hrShareURL: $hrShareURL,
                                           hrImportStatus: hrImportStatus)
    }

    private var imuAuditCard: some View {
        AtriaCollectionIMUAuditCard(summary: store.imuAuditSummary)
    }

    private var researchManeuverCard: some View {
        AtriaResearchManeuverMarkerCard(markers: store.researchManeuverMarkers,
                                        correlationSummary: store.researchManeuverProbeCorrelationSummary,
                                        onMark: { store.markResearchManeuver($0) })
    }

    private var collectionControlsCard: some View {
        AtriaCollectionControlsCardHost(collectionLiveStore: collectionLiveStore,
                                        homeStatsStore: homeStatsStore,
                                        profileStore: profileStore,
                                        store: store,
                                        ble: ble,
                                        hapticSettings: $hapticSettings,
                                        developerModeEnabled: developerModeEnabled)
    }

    private var collectionStatusCard: some View {
        AtriaCollectionStatusCardHost(coreLiveStore: coreLiveStore,
                                      collectionLiveStore: collectionLiveStore,
                                      homeStatsStore: homeStatsStore,
                                      snapshotStore: snapshotStore)
    }
}

private struct AtriaVitalsPulseCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore

    var body: some View {
        AtriaPulseCard(isConnected: liveStore.state.status == .connected,
                       live: pulseStore.state,
                       sparklineStore: pulseSparklineStore,
                       restingHeartRateText: homeStatsStore.state.restingHeartRateText)
            .equatable()
    }
}

private struct AtriaVitalsHRVCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaHRVCard(live: liveStore.state,
                     hero: heroStore.state)
            .equatable()
    }
}

private struct AtriaVitalsRecoveryStrainCardHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaRecoveryStrainCard(hero: heroStore.state)
            .equatable()
    }
}

private struct AtriaVitalsProfileCardHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    var body: some View {
        AtriaProfileCard(profile: profileStore.profile,
                         observedPeakHeartRateText: pulseStore.state.peakHeartRateText,
                         vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                         onUpdateProfile: onUpdateProfile)
            .equatable()
    }
}

private struct AtriaCollectionCaptureCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let ble: AtriaBLEManager
    @Binding var captureShareURL: URL?
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Saved readings", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.isRecording ? .live : .local)
            }

            captureActions

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                captureStats
            }

            DisclosureGroup(isExpanded: $showDetails) {
                Text(collectionLiveStore.state.captureSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } label: {
                Label("Details", systemImage: "info.circle")
                    .font(.caption.weight(.semibold))
            }
            .tint(.secondary)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var captureStats: some View {
        AtriaMetricTile(label: "Readings",
                        value: "\(collectionLiveStore.state.capturedRows)",
                        state: collectionLiveStore.state.isRecording ? .live : .local,
                        tint: .blue)
        AtriaMetricTile(label: "Backup",
                        value: collectionLiveStore.state.recordingState,
                        state: collectionLiveStore.state.isRecording ? .live : .local,
                        tint: collectionLiveStore.state.isRecording ? .red : .blue)
        AtriaMetricTile(label: "Export",
                        value: collectionLiveStore.state.captureFileLabel,
                        state: .local,
                        tint: .green)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]

    @ViewBuilder
    private var captureActions: some View {
        VStack(spacing: 10) {
            captureActionButtons
        }
    }

    @ViewBuilder
    private var captureActionButtons: some View {
        Button {
            ble.toggleRecording()
        } label: {
            Text(collectionLiveStore.state.isRecording ? "Stop backup" : "Start backup")
                .frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: collectionLiveStore.state.isRecording ? .red : .blue)

        Button {
            captureShareURL = ble.exportCSV()
        } label: {
            Text("Prepare export").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        if let captureShareURL {
            ShareLink(item: captureShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionRRReferenceCardHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    let store: SessionStore
    @Binding var showRRImporter: Bool
    @Binding var rrShareURL: URL?
    let rrImportStatus: String
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "RR reference", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: homeStatsStore.state.rrPackageText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                rrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "RR window",
                leadingValue: homeStatsStore.state.rrPackageText,
                leadingDetail: homeStatsStore.state.hrvDetail,
                trailingTitle: "Flow",
                trailingValue: "Export or import",
                trailingDetail: "local file flow"
            )

            if !rrImportStatus.isEmpty || !homeStatsStore.state.hrvDetail.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !rrImportStatus.isEmpty {
                            Text(rrImportStatus)
                        }
                        Text(homeStatsStore.state.hrvDetail)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var rrActionButtons: some View {
        Button {
            rrShareURL = store.exportRRReferencePackageForUI()
        } label: {
            Text("Export RR").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showRRImporter = true
        } label: {
            Text("Import RR").frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .blue)

        if let rrShareURL {
            ShareLink(item: rrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionHRReferenceCardHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @Binding var showHRImporter: Bool
    @Binding var hrShareURL: URL?
    let hrImportStatus: String
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "HR reference", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: snapshotStore.state.referenceText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                hrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "HR status",
                leadingValue: snapshotStore.state.referenceText,
                leadingDetail: "external workout check",
                trailingTitle: "Workout",
                trailingValue: snapshotStore.state.workoutText,
                trailingDetail: "current classifier"
            )

            if !hrImportStatus.isEmpty {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(hrImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 6)
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(.caption.weight(.semibold))
                }
                .tint(.secondary)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var hrActionButtons: some View {
        Button {
            hrShareURL = store.exportHRReferencePackageForUI()
        } label: {
            Text("Export HR").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showHRImporter = true
        } label: {
            Text("Import HR").frame(maxWidth: .infinity)
        }
        .atriaCardAction(tint: .blue)

        if let hrShareURL {
            ShareLink(item: hrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .atriaCardAction(tint: .green)
        }
    }
}

private struct AtriaCollectionIMUAuditCard: View, Equatable {
    let summary: IMUAuditSummary

    static func == (lhs: AtriaCollectionIMUAuditCard, rhs: AtriaCollectionIMUAuditCard) -> Bool {
        lhs.summary == rhs.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "IMU audit", subtitle: "")
                Spacer(minLength: 0)
                AtriaStateBadge(state: summary.validatedFrames > 0 ? .validated : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaMetricTile(label: "Frames",
                                value: summary.frameText,
                                state: summary.frameCount > 0 ? .research : .learning,
                                tint: .indigo)
                AtriaMetricTile(label: "Rate",
                                value: summary.sampleRateText,
                                unit: summary.sampleRateHz == nil ? nil : "Hz",
                                state: summary.sampleRateHz == nil ? .learning : .research,
                                tint: .blue)
                AtriaMetricTile(label: "Layout",
                                value: summary.layoutText,
                                state: summary.layoutText == "--" ? .learning : .research,
                                tint: .purple)
                AtriaMetricTile(label: "Gravity",
                                value: summary.gravityText,
                                state: summary.validatedFrames > 0 ? .validated : .learning,
                                tint: summary.validatedFrames > 0 ? .green : .orange)
                AtriaMetricTile(label: "Strap steps",
                                value: summary.strapStepText,
                                state: summary.strapStepCount > 0 ? .research : .learning,
                                tint: .orange,
                                footnote: summary.agreementText)
                AtriaMetricTile(label: "Sleep/wake",
                                value: summary.sleepWakeText,
                                state: summary.sleepWakeText == "--" ? .learning : .research,
                                tint: .cyan,
                                footnote: summary.sleepWakeReason)
                AtriaMetricTile(label: "Probes",
                                value: summary.probeText,
                                state: summary.probeFrameCount > 0 ? .research : .learning,
                                tint: .teal,
                                footnote: summary.probeDetail)
            }

            Text("Research only; compare with phone motion before steps or sleep.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 128), spacing: 12)]
}

private struct AtriaResearchManeuverMarkerCard: View, Equatable {
    let markers: [ResearchManeuverMarker]
    let correlationSummary: ResearchManeuverProbeCorrelationSummary
    let onMark: (ResearchManeuverMarker.Kind) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaResearchManeuverMarkerCard, rhs: AtriaResearchManeuverMarkerCard) -> Bool {
        lhs.markers == rhs.markers && lhs.correlationSummary == rhs.correlationSummary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Probe markers", subtitle: "")
                Spacer(minLength: 0)
                AtriaStatusChip(text: "\(markers.count)",
                                systemImage: "scope",
                                tint: markers.isEmpty ? .gray : .teal)
            }

            LazyVGrid(columns: Self.buttonColumns, spacing: 10) {
                ForEach(ResearchManeuverMarker.Kind.allCases) { kind in
                    Button {
                        if reduceMotion {
                            onMark(kind)
                        } else {
                            withAnimation(.snappy(duration: 0.18)) {
                                onMark(kind)
                            }
                        }
                    } label: {
                        Label(kind.shortLabel, systemImage: kind.systemImage)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }
                    .atriaCardAction(prominent: false, tint: .teal)
                }
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaMetricTile(label: "Markers",
                                value: "\(markers.count)",
                                state: markers.isEmpty ? .learning : .research,
                                tint: .teal)
                AtriaMetricTile(label: "Probe match",
                                value: correlationSummary.matchText,
                                state: correlationSummary.matchedMarkers > 0 ? .research : .learning,
                                tint: .green,
                                footnote: correlationSummary.candidateText)
                AtriaMetricTile(label: "Latest",
                                value: latestMarkerText,
                                state: markers.isEmpty ? .learning : .research,
                                tint: .cyan,
                                footnote: latestMarkerDetail)
            }

            Text("Research only; timestamps stay on device for probe correlation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var latestMarkerText: String {
        markers.first?.kind.shortLabel ?? "--"
    }

    private var latestMarkerDetail: String? {
        guard let marker = markers.first else { return nil }
        return RelativeDateTimeFormatter().localizedString(for: marker.timestamp, relativeTo: Date())
    }

    private static let buttonColumns = [GridItem(.flexible()), GridItem(.flexible())]
    private static let statColumns = [GridItem(.adaptive(minimum: 128), spacing: 12)]
}

private struct AtriaCollectionControlsCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: AtriaBLEManager
    @Binding var hapticSettings: AtriaHapticAlertSettings
    let developerModeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Data settings", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.longWearModeEnabled ? .live : .local)
            }

            VStack(spacing: 12) {
                if developerModeEnabled {
                    AtriaCollectionToggleCard(
                        title: "Standard HR radio",
                        subtitle: "Advanced compatibility mode for heart-rate-only collection.",
                        systemImage: "dot.radiowaves.left.and.right",
                        tint: .blue,
                        isOn: Binding(
                            get: { collectionLiveStore.state.standardHROnlyEnabled },
                            set: { enabled in
                                ble.setStandardHROnlyEnabled(enabled)
                            })
                    )
                }

                AtriaCollectionToggleCard(
                    title: "Long wear",
                    subtitle: "Keep local backup running longer using your current rest and max HR.",
                    systemImage: "record.circle",
                    tint: .green,
                    isOn: Binding(
                        get: { collectionLiveStore.state.longWearModeEnabled },
                        set: { enabled in
                            ble.setLongWearModeEnabled(enabled,
                                                       rest: homeStatsStore.state.restingHeartRate,
                                                       maxHR: profileStore.profile.maxHR)
                        })
                )

                AtriaCollectionProfilePicker(
                    selected: collectionLiveStore.state.collectionProfile,
                    onSelect: { profile in
                        ble.setCollectionProfile(profile,
                                                 rest: homeStatsStore.state.restingHeartRate,
                                                 maxHR: profileStore.profile.maxHR)
                    }
                )

                AtriaHapticAlertSettingsCard(settings: hapticSettings) { settings in
                    hapticSettings = settings
                }
            }

            NavigationLink {
                HistoryView(store: store)
            } label: {
                Label("Open saved sessions", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .atriaCardAction(prominent: false, tint: .gray)
        }
        .padding(18)
        .atriaCard()
    }
}

private struct AtriaCollectionStatusCardHost: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Data status", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .noContact : .local)
            }

            if collectionLiveStore.state.officialAppCoexistenceRisk != .cleared {
                AtriaCollectionCoexistenceWarning(risk: collectionLiveStore.state.officialAppCoexistenceRisk)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                statusTiles
            }
        }
        .padding(18)
        .atriaCard()
    }

    @ViewBuilder
    private var statusTiles: some View {
        AtriaMetricTile(label: "Logging",
                        value: snapshotStore.state.loggingText,
                        state: snapshotStore.state.loggingText.localizedCaseInsensitiveContains("sample") ? .live : .learning,
                        tint: .green)
        AtriaMetricTile(label: "Backup",
                        value: homeStatsStore.state.backupValue,
                        state: .local,
                        tint: .blue)
        AtriaMetricTile(label: "Battery",
                        value: coreLiveStore.state.batteryText,
                        state: coreLiveStore.state.batteryLevel >= 0 ? .live : .learning,
                        tint: .green)
        AtriaMetricTile(label: "Mode",
                        value: collectionLiveStore.state.modeLabel,
                        state: collectionLiveStore.state.longWearModeEnabled ? .live : .local,
                        tint: .purple)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

private struct AtriaCollectionCoexistenceWarning: View, Equatable {
    let risk: AtriaBLEManager.OfficialAppCoexistenceRisk

    private var title: String {
        risk == .suspected ? "App conflict" : "Strap check"
    }

    private var detail: String {
        risk == .suspected
            ? "Remove the official strap app, then reconnect."
            : "Remove the official strap app if drops return."
    }

    private var tint: Color {
        risk == .suspected ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: tint)
    }
}

private struct AtriaCollectionProfilePicker: View, Equatable {
    let selected: AtriaBLEManager.CollectionProfile
    let onSelect: (AtriaBLEManager.CollectionProfile) -> Void

    static func == (lhs: AtriaCollectionProfilePicker, rhs: AtriaCollectionProfilePicker) -> Bool {
        lhs.selected == rhs.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "speedometer")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.purple)
                    .frame(width: 24, height: 24)
                    .background(AtriaIconTileBackground(cornerRadius: 8, tint: .purple))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Saving mode")
                        .font(.subheadline.weight(.semibold))
                    Text(selected.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(AtriaBLEManager.CollectionProfile.allCases) { profile in
                    Button {
                        onSelect(profile)
                    } label: {
                        Text(profile.label)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .atriaGlassSelectable(selected: selected == profile)
                    .accessibilityLabel("Saving mode \(profile.label)")
                }
            }
            .padding(6)
            .atriaInsetCard(tint: .purple)
        }
        .padding(14)
        .atriaInsetCard(tint: .purple)
    }
}

private struct AtriaPulseCard: View, Equatable {
    let isConnected: Bool
    let live: AtriaHomeModel.PulseLiveState
    let sparklineStore: AtriaHomeModel.PulseSparklineStore
    let restingHeartRateText: String

    static func == (lhs: AtriaPulseCard, rhs: AtriaPulseCard) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.live == rhs.live
            && lhs.restingHeartRateText == rhs.restingHeartRateText
    }

    private var hasLiveContact: Bool {
        isConnected && live.hasPulseSignal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart rate", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: hasLiveContact ? .live : .noContact)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaMetricTile(label: "Now",
                                value: live.heartRateText,
                                unit: "bpm",
                                state: hasLiveContact ? .live : .noContact,
                                tint: hasLiveContact ? .red : .orange,
                                sparklineValues: sparklineStore.state.values)
                pulseStatTiles
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var pulseStatTiles: some View {
        AtriaMetricTile(label: "Average",
                        value: live.averageHeartRateText,
                        state: hasLiveContact ? .live : .learning,
                        tint: .pink)
        AtriaMetricTile(label: "Peak",
                        value: live.peakHeartRateText,
                        state: hasLiveContact ? .live : .learning,
                        tint: .red)
        AtriaMetricTile(label: "Resting",
                        value: restingHeartRateText,
                        state: .personalBaseline,
                        tint: .blue)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

private struct AtriaPulseSparklineHost: View {
    @ObservedObject var sparklineStore: AtriaHomeModel.PulseSparklineStore

    var body: some View {
        Sparkline(values: sparklineStore.state.values)
            .frame(height: 68)
    }
}

private struct AtriaHRVCard: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let hero: AtriaHomeModel.HeroSnapshot

    private var continuityTint: Color {
        live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .orange : .pink
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "HRV", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: hrvState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                hrvStatTiles
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var hrvState: AtriaMetricState {
        hero.hrvDetail.localizedCaseInsensitiveContains("validated") ? .validated : .learning
    }

    private var isConnected: Bool {
        live.status == .connected
    }

    @ViewBuilder
    private var hrvStatTiles: some View {
        AtriaMetricTile(label: "RMSSD",
                        value: hero.hrvValue,
                        state: hrvState,
                        tint: .pink)
        AtriaMetricTile(label: "Window",
                        value: hero.rrPackageText,
                        state: isConnected && !live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .live : .learning,
                        tint: continuityTint)
        AtriaMetricTile(label: "Stress",
                        value: hero.stressValue,
                        state: .local,
                        tint: .purple)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

private struct AtriaRecoveryStrainCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "")

            metricContent
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var metricContent: some View {
        LazyVGrid(columns: Self.statColumns, spacing: 12) {
            recoveryStrainTiles
        }
    }

    @ViewBuilder
    private var recoveryStrainTiles: some View {
        AtriaMetricTile(label: "Recovery",
                        value: hero.recoveryEstimate.percent.map { "\($0)" } ?? "--",
                        unit: hero.recoveryEstimate.percent == nil ? nil : "%",
                        state: hero.recoveryEstimate.percent == nil ? .learning : .validated,
                        tint: hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange)
        AtriaMetricTile(label: "Strain",
                        value: String(format: "%.1f", hero.strain),
                        state: .local,
                        tint: Metrics.strainColor(hero.strain))
        AtriaTrainingLoadTile(ratio: hero.loadRatioText,
                              target: hero.loadTargetText,
                              confidence: hero.loadConfidence,
                              narrative: hero.loadNarrative)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

private struct AtriaTrainingLoadTile: View, Equatable {
    let ratio: String
    let target: String
    let confidence: String
    let narrative: String

    private var confidenceTint: Color {
        confidence == "local" ? .green : .orange
    }

    var body: some View {
        AtriaMetricTile(label: "Load",
                        value: ratio,
                        state: confidence == "local" ? .local : .learning,
                        tint: confidenceTint,
                        footnote: target)
    }
}

private struct AtriaProfileCard: View, Equatable {
    let profile: AthleteProfile
    let observedPeakHeartRateText: String
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaProfileCard, rhs: AtriaProfileCard) -> Bool {
        lhs.profile == rhs.profile
            && lhs.observedPeakHeartRateText == rhs.observedPeakHeartRateText
            && lhs.vo2MaxEstimate == rhs.vo2MaxEstimate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Profile", subtitle: "HRmax and age used for scoring")

            HStack(spacing: 8) {
                ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                    Button {
                        if reduceMotion {
                            onUpdateProfile { $0.maxHRSource = source }
                        } else {
                            withAnimation(.snappy(duration: 0.22)) {
                                onUpdateProfile { $0.maxHRSource = source }
                            }
                        }
                    } label: {
                        Text(source.label)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .atriaGlassSelectable(selected: profile.maxHRSource == source)
                }
            }
            .padding(8)
            .atriaInsetCard(tint: .purple)

            VStack(spacing: 12) {
                profileStepperTiles
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaInlineQuickStat(label: "Active HRmax", value: "\(profile.maxHR)")
                AtriaInlineQuickStat(label: "Observed peak", value: observedPeakHeartRateText)
                AtriaInlineQuickStat(label: "Source", value: profile.maxHRSource.label)
                AtriaMetricTile(label: "VO2max",
                                value: vo2MaxEstimate.valueText,
                                state: vo2MaxEstimate.value == nil ? .learning : .estimate,
                                tint: .orange,
                                footnote: vo2MaxEstimate.confidence)
            }

            Text(vo2MaxEstimate.narrative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Atria uses the active HRmax right away for strain and workout interpretation.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var profileStepperTiles: some View {
        AtriaProfileStepperTile(title: "Age", value: "\(profile.age)") {
            onUpdateProfile { $0.age = max(13, $0.age - 1) }
        } increment: {
            onUpdateProfile { $0.age = min(100, $0.age + 1) }
        }

        AtriaProfileStepperTile(title: "Measured max", value: "\(profile.measuredMaxHR)") {
            onUpdateProfile { $0.measuredMaxHR = max(120, $0.measuredMaxHR - 1) }
        } increment: {
            onUpdateProfile { $0.measuredMaxHR = min(220, $0.measuredMaxHR + 1) }
        }
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 104), spacing: 12)]
}

private struct AtriaCollectionReferenceSummaryCard: View, Equatable {
    let leadingTitle: String
    let leadingValue: String
    let leadingDetail: String
    let trailingTitle: String
    let trailingValue: String
    let trailingDetail: String

    var body: some View {
        LazyVGrid(columns: Self.statColumns, spacing: 12) {
            AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                value: leadingValue,
                                                detail: leadingDetail)
            AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                value: trailingValue,
                                                detail: trailingDetail)
        }
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 160), spacing: 12)]
}

private struct AtriaCollectionReferenceSummaryTile: View, Equatable {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        AtriaMetricTile(label: title,
                        value: value,
                        state: value.localizedCaseInsensitiveContains("ready") ? .validated : .learning,
                        tint: .blue,
                        footnote: compactDetail)
    }

    private var compactDetail: String {
        let words = detail.split(separator: " ")
        guard words.count > 4 else { return detail }
        return words.prefix(4).joined(separator: " ")
    }
}

private struct AtriaCollectionToggleCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }
}
