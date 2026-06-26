import SwiftUI
import Charts

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
        AtriaVitalsRecoveryStrainCardHost(heroStore: heroStore,
                                          store: store)
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
                        researchSignalsCard
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
                    researchSignalsCard
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

    private var researchSignalsCard: some View {
        AtriaCollectionResearchSignalsCard(summary: store.imuAuditSummary,
                                           sleepHistory: store.sleepHistorySnapshot)
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
                                      snapshotStore: snapshotStore,
                                      store: store)
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
    @ObservedObject var store: SessionStore

    var body: some View {
        AtriaRecoveryStrainCard(hero: heroStore.state,
                                sleepHistory: store.sleepHistorySnapshot)
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

private struct AtriaCollectionResearchSignalsCard: View, Equatable {
    let summary: IMUAuditSummary
    let sleepHistory: SleepHistorySnapshot

    static func == (lhs: AtriaCollectionResearchSignalsCard, rhs: AtriaCollectionResearchSignalsCard) -> Bool {
        lhs.summary == rhs.summary && lhs.sleepHistory == rhs.sleepHistory
    }

    private var hasEvidence: Bool {
        summary.probeFrameCount > 0
            || summary.strapStepCount > 0
            || latestRespiratoryRate != "--"
    }

    private var latestRespiratoryRate: String {
        sleepHistory.nights.first?.respiratoryRateText ?? "--"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Research signals", subtitle: "")
                Spacer(minLength: 0)
                AtriaStateBadge(state: hasEvidence ? .research : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaMetricTile(label: "Blood oxygen",
                                value: summary.spo2CandidateFrames > 0 ? "\(summary.spo2CandidateFrames)" : "--",
                                state: summary.spo2CandidateFrames > 0 ? .research : .learning,
                                tint: .blue,
                                footnote: "candidate frames; no Health export")
                AtriaMetricTile(label: "Skin temp",
                                value: summary.skinTempCandidateFrames > 0 ? "\(summary.skinTempCandidateFrames)" : "--",
                                state: summary.skinTempCandidateFrames > 0 ? .research : .learning,
                                tint: .orange,
                                footnote: "baseline deviation only")
                AtriaMetricTile(label: "Resp rate",
                                value: latestRespiratoryRate,
                                unit: latestRespiratoryRate == "--" ? nil : "/min",
                                state: latestRespiratoryRate == "--" ? .learning : .research,
                                tint: .teal,
                                footnote: "RR-derived during sleep")
                AtriaMetricTile(label: "Strap steps",
                                value: summary.strapStepText,
                                state: summary.strapStepCount > 0 ? .research : .learning,
                                tint: .green,
                                footnote: summary.agreementText)
            }

            Text("Research only. Atria never shows absolute SpO2 or skin temperature until the sensor layout is validated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
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
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Data status", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .conflict : .local)
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
        .task {
            store.refreshHistoricalArchiveStatus(reason: "data_status_appear")
        }
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
        AtriaMetricTile(label: "Backfill",
                        value: store.historicalArchiveStatus.valueText,
                        state: store.historicalArchiveStatus.metricReady ? .validated : (store.historicalArchiveStatus.hasArchiveRows ? .research : .learning),
                        tint: .cyan,
                        footnote: store.historicalArchiveStatus.detailText)
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
    @State private var showHeartRateExplorer = false

    static func == (lhs: AtriaPulseCard, rhs: AtriaPulseCard) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.live == rhs.live
            && lhs.restingHeartRateText == rhs.restingHeartRateText
    }

    private var hasReadablePulse: Bool {
        live.hasPulseSignal
    }

    private var pulseState: AtriaMetricState {
        hasReadablePulse ? .live : .noContact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart rate", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: pulseState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: 12) {
                AtriaMetricTile(label: "Now",
                                value: live.heartRateText,
                                unit: "bpm",
                                state: pulseState,
                                tint: hasReadablePulse ? .red : .orange,
                                sparklineValues: sparklineStore.state.values)
                pulseStatTiles
            }

            AtriaHeartRateTimelineCard(points: sparklineStore.state.chartPoints,
                                       onOpen: { showHeartRateExplorer = true })
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .fullScreenCover(isPresented: $showHeartRateExplorer) {
            AtriaHeartRateExplorer(points: sparklineStore.state.chartPoints,
                                   currentBPM: live.heartRate,
                                   onDismiss: { showHeartRateExplorer = false })
        }
    }

    @ViewBuilder
    private var pulseStatTiles: some View {
        AtriaMetricTile(label: "Average",
                        value: live.averageHeartRateText,
                        state: hasReadablePulse ? .live : .learning,
                        tint: .pink)
        AtriaMetricTile(label: "Peak",
                        value: live.peakHeartRateText,
                        state: hasReadablePulse ? .live : .learning,
                        tint: .red)
        AtriaMetricTile(label: "Resting",
                        value: restingHeartRateText,
                        state: .personalBaseline,
                        tint: .blue)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 142), spacing: 12)]
}

private struct AtriaHeartRateTimelineCard: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let onOpen: () -> Void

    static func == (lhs: AtriaHeartRateTimelineCard, rhs: AtriaHeartRateTimelineCard) -> Bool {
        lhs.points == rhs.points
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Heart-rate timeline")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text("Tap to inspect")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                AtriaHeartRateAxisChart(points: points, selectedTime: .constant(nil))
                    .frame(height: 170)

                HStack {
                    Label("Time", systemImage: "clock")
                    Spacer(minLength: 8)
                    Label("BPM", systemImage: "heart")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .atriaInsetCard(tint: .red)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open heart rate timeline")
    }
}

private struct AtriaHeartRateExplorer: View {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let currentBPM: Int
    let onDismiss: () -> Void
    @State private var selectedTime: Date?
    @State private var zoom: Double = 1

    private var visiblePoints: [AtriaHomeModel.HeartRateChartPoint] {
        guard zoom > 1, points.count > 8 else { return points }
        let keep = max(8, Int(Double(points.count) / zoom))
        return Array(points.suffix(keep))
    }

    private var selectedPoint: AtriaHomeModel.HeartRateChartPoint? {
        guard let selectedTime else { return visiblePoints.last }
        return visiblePoints.min { lhs, rhs in
            abs(lhs.t.timeIntervalSince(selectedTime)) < abs(rhs.t.timeIntervalSince(selectedTime))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(selectedPoint.map { "\($0.bpm)" } ?? (currentBPM > 0 ? "\(currentBPM)" : "--"))
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("bpm")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                if let selectedPoint {
                    Text(selectedPoint.t, format: .dateTime.hour().minute().second())
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Tap or drag on the graph to inspect any sample.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                AtriaHeartRateAxisChart(points: visiblePoints, selectedTime: $selectedTime)
                    .frame(maxHeight: .infinity)
                    .frame(minHeight: 320)

                HStack(spacing: 12) {
                    Image(systemName: "minus.magnifyingglass")
                    Slider(value: $zoom, in: 1...6, step: 1)
                    Image(systemName: "plus.magnifyingglass")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(AtriaBackdropLayer(isDark: false, reduceTransparency: false).ignoresSafeArea())
            .navigationTitle("Heart rate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct AtriaHeartRateAxisChart: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    @Binding var selectedTime: Date?

    static func == (lhs: AtriaHeartRateAxisChart, rhs: AtriaHeartRateAxisChart) -> Bool {
        lhs.points == rhs.points
    }

    private var yDomain: ClosedRange<Int> {
        let values = points.map(\.bpm)
        let low = max((values.min() ?? 60) - 8, 35)
        let high = min((values.max() ?? 120) + 8, 220)
        return low...max(high, low + 20)
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.t), y: .value("BPM", point.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red.opacity(0.12).gradient)
            LineMark(x: .value("Time", point.t), y: .value("BPM", point.bpm))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.red.gradient)
            if let selectedTime {
                RuleMark(x: .value("Selected", selectedTime))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(.init(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let bpm = value.as(Int.self) {
                        Text("\(bpm)")
                    }
                }
            }
        }
        .chartXSelection(value: $selectedTime)
        .chartOverlay { proxy in
            if points.isEmpty {
                Text("Waiting for live heart-rate samples")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
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
    let sleepHistory: SleepHistorySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "")

            metricContent
            AtriaSleepHistoryCard(snapshot: sleepHistory)
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

private struct AtriaSleepHistoryCard: View, Equatable {
    let snapshot: SleepHistorySnapshot

    private var chartNights: [SleepHistorySnapshot.Night] {
        Array(snapshot.nights.prefix(7).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sleep history")
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.stateText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                AtriaStateBadge(state: snapshot.confirmedCount > 0 ? .validated : (snapshot.candidateCount > 0 ? .research : .learning))
            }

            if snapshot.nights.isEmpty {
                AtriaMetricTile(label: "Recent nights",
                                value: "Learning",
                                state: .learning,
                                tint: .cyan,
                                footnote: "Wear the strap overnight. Atria shows duration and RHR once saved evidence exists.")
            } else {
                LazyVGrid(columns: Self.statColumns, spacing: 10) {
                    AtriaMetricTile(label: "Latest",
                                    value: snapshot.latest?.durationText ?? "--",
                                    state: snapshot.latest?.confirmed == true ? .validated : .research,
                                    tint: .cyan,
                                    footnote: snapshot.latest?.confidenceText)
                    AtriaMetricTile(label: "Average",
                                    value: snapshot.averageDurationText,
                                    state: .local,
                                    tint: .blue,
                                    footnote: "\(snapshot.nights.count) nights")
                    AtriaMetricTile(label: "Sleep RHR",
                                    value: snapshot.latest?.restingHRText ?? "--",
                                    unit: snapshot.latest?.restingHR == nil ? nil : "bpm",
                                    state: snapshot.latest?.restingHR == nil ? .learning : .personalBaseline,
                                    tint: .red)
                    AtriaMetricTile(label: "Efficiency",
                                    value: snapshot.latest?.sleepEfficiencyText ?? "--",
                                    state: snapshot.latest?.sleepEfficiency == nil ? .learning : .research,
                                    tint: .cyan,
                                    footnote: "Duration vs sleep span")
                    AtriaMetricTile(label: "Sleep HRV",
                                    value: snapshot.latest?.hrvText ?? "--",
                                    unit: snapshot.latest?.hrv == nil ? nil : "ms",
                                    state: snapshot.latest?.hrv == nil ? .learning : .research,
                                    tint: .purple,
                                    footnote: "RR-derived sleep")
                    AtriaMetricTile(label: "Sleep resp",
                                    value: snapshot.latest?.respiratoryRateText ?? "--",
                                    unit: snapshot.latest?.respiratoryRate == nil ? nil : "/min",
                                    state: snapshot.latest?.respiratoryRate == nil ? .learning : .research,
                                    tint: .teal,
                                    footnote: "RR-derived research")
                }

                if chartNights.count > 1 {
                    Chart(chartNights) { night in
                        BarMark(x: .value("Night", night.day, unit: .day),
                                y: .value("Hours", night.durationHours))
                            .foregroundStyle(night.confirmed ? Color.cyan.gradient : Color.teal.opacity(0.55).gradient)
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let hours = value.as(Double.self) {
                                    Text("\(Int(hours.rounded()))h")
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.weekday(.narrow))
                        }
                    }
                    .frame(height: 140)
                    .padding(12)
                    .atriaInsetCard(tint: .cyan)
                }

                ForEach(snapshot.nights.prefix(3)) { night in
                    AtriaSleepNightRow(night: night)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
    }

    private static let statColumns = [GridItem(.adaptive(minimum: 132), spacing: 10)]
}

private struct AtriaSleepNightRow: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: night.confirmed ? "checkmark.seal.fill" : "bed.double.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(night.confirmed ? .green : .teal)
                .frame(width: 24, height: 24)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: night.confirmed ? .green : .teal))

            VStack(alignment: .leading, spacing: 2) {
                Text(night.day, format: .dateTime.weekday(.abbreviated).month().day())
                    .font(.caption.weight(.semibold))
                Text("\(night.durationText) · Eff \(night.sleepEfficiencyText) · RHR \(night.restingHRText) · HRV \(night.hrvText) · Resp \(night.respiratoryRateText) · \(night.confidenceText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .atriaInsetCard(tint: night.confirmed ? .green : .teal)
    }
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
                AtriaMetricTile(label: "VO2 trend",
                                value: vo2MaxEstimate.trendText,
                                state: vo2MaxEstimate.value == nil || vo2MaxEstimate.trendText == "Learning" ? .learning : .estimate,
                                tint: .orange,
                                footnote: vo2MaxEstimate.trendDetail)
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
