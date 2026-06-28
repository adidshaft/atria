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
    @State private var isEditingVitalsLayout = false

    var body: some View {
        let sections = AtriaVitalsSection.ordered(from: sectionOrderCSV)
        VStack(spacing: 18) {
            if isEditingVitalsLayout {
                HStack(spacing: 8) {
                    Label("Editing Vitals", systemImage: "rectangle.3.group")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            isEditingVitalsLayout = false
                        }
                    } label: {
                        Text("Done")
                            .font(.caption.weight(.bold))
                    }
                    .buttonStyle(AtriaCardActionButtonStyle(prominent: false, tint: .secondary))
                }
                .padding(.horizontal, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

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

            if hasCustomVitalsLayout {
                Button(action: resetVitalsLayout) {
                    Label("Reset Vitals layout", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
                .accessibilityLabel("Reset Vitals layout")
                .accessibilityHint("Restores Pulse, HRV, Recovery and strain, and Profile to the default order.")
            }
        }
        .sensoryFeedback(.selection, trigger: sectionOrderCSV)
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
        .overlay(alignment: .topTrailing) {
            if isEditingVitalsLayout {
                vitalsSectionEditControls(for: section)
                    .padding(10)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.card, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.45) {
            withAnimation(.snappy(duration: 0.2)) {
                isEditingVitalsLayout = true
            }
        }
        .modifier(AtriaConditionalVitalsStringDraggable(isEnabled: isEditingVitalsLayout,
                                                        payload: section.dragPayload))
        .dropDestination(for: String.self) { items, _ in
            guard isEditingVitalsLayout else { return false }
            guard let raw = items.first,
                  let dragged = AtriaVitalsSection.draggedSection(from: raw) else { return false }
            sectionOrderCSV = AtriaVitalsSection.moving(dragged, before: section, in: sectionOrderCSV)
            return true
        }
        .accessibilityAction(named: Text("Move \(section.label) up")) {
            moveSection(section, direction: -1)
        }
        .accessibilityAction(named: Text("Move \(section.label) down")) {
            moveSection(section, direction: 1)
        }
        .accessibilityHint("Long press to edit, then drag to reorder this Vitals section or use the visible move controls.")
    }

    private func vitalsSectionEditControls(for section: AtriaVitalsSection) -> some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    moveSection(section, direction: -1)
                }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.black))
            }
            .atriaGlassIconAction(tint: .secondary, size: 44)
            .accessibilityLabel("Move \(section.label) up")

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    moveSection(section, direction: 1)
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.black))
            }
            .atriaGlassIconAction(tint: .secondary, size: 44)
            .accessibilityLabel("Move \(section.label) down")
        }
        .fixedSize()
        .accessibilityElement(children: .contain)
    }

    private func moveSection(_ section: AtriaVitalsSection, direction: Int) {
        sectionOrderCSV = AtriaVitalsSection.moving(section, direction: direction, in: sectionOrderCSV)
    }

    private var hasCustomVitalsLayout: Bool {
        AtriaVitalsSection.ordered(from: sectionOrderCSV) != Array(AtriaVitalsSection.allCases)
    }

    private func resetVitalsLayout() {
        sectionOrderCSV = AtriaVitalsSection.allCases.map(\.rawValue).joined(separator: ",")
        isEditingVitalsLayout = false
    }

    private var pulseCard: some View {
        AtriaVitalsPulseCardHost(liveStore: liveStore,
                                 pulseStore: pulseStore,
                                 homeStatsStore: homeStatsStore,
                                 store: store,
                                 pulseSparklineStore: pulseSparklineStore)
    }

    private var hrvCard: some View {
        AtriaVitalsHRVCardHost(liveStore: liveStore,
                               heroStore: heroStore,
                               store: store)
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

    var label: String {
        switch self {
        case .pulse: return "Pulse"
        case .hrv: return "HRV"
        case .recoveryStrain: return "Recovery and strain"
        case .profile: return "Profile"
        }
    }

    static let orderStorageKey = "atria.vitals.sectionOrderCSV"
    private static let dragPayloadPrefix = "atria.vitals.section:"

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

    fileprivate var dragPayload: String {
        Self.dragPayloadPrefix + rawValue
    }

    static func draggedSection(from payload: String) -> AtriaVitalsSection? {
        guard payload.hasPrefix(dragPayloadPrefix) else { return nil }
        let raw = String(payload.dropFirst(dragPayloadPrefix.count))
        return AtriaVitalsSection(rawValue: raw)
    }

    static func moving(_ dragged: AtriaVitalsSection, before target: AtriaVitalsSection, in csv: String) -> String {
        guard dragged != target else { return ordered(from: csv).map(\.rawValue).joined(separator: ",") }
        var order = ordered(from: csv).filter { $0 != dragged }
        let insertIndex = order.firstIndex(of: target) ?? order.endIndex
        order.insert(dragged, at: insertIndex)
        return order.map(\.rawValue).joined(separator: ",")
    }

    static func moving(_ section: AtriaVitalsSection, direction: Int, in csv: String) -> String {
        var order = ordered(from: csv)
        guard let index = order.firstIndex(of: section) else { return order.map(\.rawValue).joined(separator: ",") }
        let next = max(0, min(order.count - 1, index + direction))
        guard next != index else { return order.map(\.rawValue).joined(separator: ",") }
        order.swapAt(index, next)
        return order.map(\.rawValue).joined(separator: ",")
    }
}

private struct AtriaConditionalVitalsStringDraggable: ViewModifier {
    let isEnabled: Bool
    let payload: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.draggable(payload)
        } else {
            content
        }
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
    let profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
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

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        captureCard
                        researchSignalsCard
                        biologicalAgeCard
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
                    biologicalAgeCard
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

    private var biologicalAgeCard: some View {
        AtriaCollectionBiologicalAgeCardHost(profileMetricsStore: profileMetricsStore)
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
                                      store: store,
                                      officialAppInstalled: officialAppInstalled)
    }
}

private struct AtriaVitalsPulseCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var store: SessionStore
    @AppStorage("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AppStorage("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore

    var body: some View {
        AtriaPulseCard(isConnected: liveStore.state.status == .connected,
                       live: pulseStore.state,
                       sparklineStore: pulseSparklineStore,
                       restingHeartRate: homeStatsStore.state.restingHeartRate,
                       restingHeartRateText: homeStatsStore.state.restingHeartRateText,
                       restingBaseline: store.baseline.restingInt,
                       restingBaselineSamples: store.baseline.freshRestingSampleCount(),
                       restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline(),
                       baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                       restingGreenDelta: restingGreenDelta,
                       restingYellowDelta: restingYellowDelta)
            .equatable()
    }
}

private struct AtriaVitalsHRVCardHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var store: SessionStore
    @AppStorage("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AppStorage("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85

    var body: some View {
        AtriaHRVCard(live: liveStore.state,
                     hero: heroStore.state,
                     hrvBaseline: store.baseline.hrvInt,
                     hrvBaselineSamples: store.baseline.freshHRVSampleCount(),
                     hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline(),
                     baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                     hrvGreenRatio: hrvGreenRatio,
                     hrvYellowRatio: hrvYellowRatio)
            .equatable()
    }
}

private struct AtriaVitalsRecoveryStrainCardHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var store: SessionStore
    @AppStorage("atria.target.recovery.greenLower") private var recoveryGreenLower: Double = 67
    @AppStorage("atria.target.recovery.yellowLower") private var recoveryYellowLower: Double = 34
    @AppStorage("atria.target.strain.greenBand") private var strainGreenBand: Double = 1.5
    @AppStorage("atria.target.strain.yellowBand") private var strainYellowBand: Double = 3.0
    @AppStorage("atria.target.sleep.goalHours") private var sleepGoalHours: Double = 8.0
    @AppStorage("atria.target.sleepEfficiency.greenLower") private var sleepEfficiencyGreenLower: Double = 90
    @AppStorage("atria.target.sleepEfficiency.yellowLower") private var sleepEfficiencyYellowLower: Double = 80
    @AppStorage("atria.target.hrv.greenRatio") private var hrvGreenRatio: Double = 0.95
    @AppStorage("atria.target.hrv.yellowRatio") private var hrvYellowRatio: Double = 0.85
    @AppStorage("atria.target.rhr.greenDelta") private var restingGreenDelta: Int = 3
    @AppStorage("atria.target.rhr.yellowDelta") private var restingYellowDelta: Int = 7
    @AppStorage("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AppStorage("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0

    var body: some View {
        AtriaRecoveryStrainCard(hero: heroStore.state,
                                sleepHistory: store.sleepHistorySnapshot,
                                recoveryTarget: AtriaMetricTarget.recovery(greenLower: recoveryGreenLower,
                                                                           yellowLower: recoveryYellowLower),
                                strainGreenBand: strainGreenBand,
                                strainYellowBand: strainYellowBand,
                                hrvBaseline: store.baseline.hrvInt,
                                hrvBaselineSamples: store.baseline.freshHRVSampleCount(),
                                hrvBaselineTrusted: store.baseline.hasTrustedHRVBaseline(),
                                baselineTarget: AtriaBaselineTargetSnapshot(store.baseline),
                                hrvGreenRatio: hrvGreenRatio,
                                hrvYellowRatio: hrvYellowRatio,
                                restingBaseline: store.baseline.restingInt,
                                restingBaselineSamples: store.baseline.freshRestingSampleCount(),
                                restingBaselineTrusted: store.baseline.hasTrustedRestingBaseline(),
                                restingGreenDelta: restingGreenDelta,
                                restingYellowDelta: restingYellowDelta,
                                respiratoryGreenDelta: respiratoryGreenDelta,
                                respiratoryYellowDelta: respiratoryYellowDelta,
                                sleepGoalHours: sleepGoalHours,
                                sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                onAddManualSleep: addManualSleep)
            .equatable()
    }

    private func addManualSleep(start: Date, end: Date, isNap: Bool) {
        _ = store.addManualSleep(start: start,
                                 end: end,
                                 isNap: isNap,
                                 rest: store.baseline.restingInt ?? 60)
    }
}

private struct AtriaVitalsProfileCardHost: View {
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @AppStorage("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AppStorage("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3
    @AppStorage("atria.target.vo2.greenDelta") private var vo2GreenDelta: Double = 0.2
    @AppStorage("atria.target.vo2.redDelta") private var vo2RedDelta: Double = -0.2
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    var body: some View {
        AtriaProfileCard(profile: profileStore.profile,
                         observedPeakHeartRateText: pulseStore.state.peakHeartRateText,
                         vo2MaxEstimate: profileMetricsStore.state.vo2MaxEstimate,
                         biologicalAgeSummary: profileMetricsStore.state.biologicalAgeSummary,
                         biologicalAgeGreenOlderDelta: biologicalAgeGreenOlderDelta,
                         biologicalAgeYellowOlderDelta: biologicalAgeYellowOlderDelta,
                         vo2GreenDelta: vo2GreenDelta,
                         vo2RedDelta: vo2RedDelta,
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

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
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

    private static let statColumns = AtriaMetricTile.gridColumns

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
                AtriaPanelSectionHeader(title: "Beat-to-beat reference", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: homeStatsStore.state.rrPackageText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                rrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Beat-to-beat window",
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
            Text("Export beats").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showRRImporter = true
        } label: {
            Text("Import beats").frame(maxWidth: .infinity)
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
                AtriaPanelSectionHeader(title: "Heart-rate check", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: snapshotStore.state.referenceText.localizedCaseInsensitiveContains("ready") ? .validated : .learning)
            }

            VStack(spacing: 10) {
                hrActionButtons
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "Heart-rate status",
                leadingValue: snapshotStore.state.referenceText,
                leadingDetail: "comparison workout",
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
            Text("Export heart rate").frame(maxWidth: .infinity)
        }
        .atriaCardAction(prominent: false, tint: .gray)

        Button {
            showHRImporter = true
        } label: {
            Text("Import heart rate").frame(maxWidth: .infinity)
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
    @AppStorage("atria.target.respiratory.greenDelta") private var respiratoryGreenDelta: Double = 1.5
    @AppStorage("atria.target.respiratory.yellowDelta") private var respiratoryYellowDelta: Double = 3.0
    @AppStorage("atria.target.steps.goal") private var stepsGoal: Int = 8_000
    @AppStorage("atria.target.skinTemp.greenDelta") private var skinTemperatureGreenDelta: Double = 0.5
    @AppStorage("atria.target.skinTemp.yellowDelta") private var skinTemperatureYellowDelta: Double = 1.0
    @AppStorage("atria.target.bloodOxygen.candidateFrames") private var bloodOxygenCandidateGoal: Int = 8
    @State private var showResearchInfo = false

    static func == (lhs: AtriaCollectionResearchSignalsCard, rhs: AtriaCollectionResearchSignalsCard) -> Bool {
        lhs.summary == rhs.summary
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.bloodOxygenCandidateGoal == rhs.bloodOxygenCandidateGoal
    }

    private var hasEvidence: Bool {
        summary.probeFrameCount > 0
            || summary.strapStepCount > 0
            || latestRespiratoryRate != "--"
    }

    private var latestRespiratoryRate: String {
        sleepHistory.nights.first?.respiratoryRateText ?? "--"
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(sleepHistory.latest?.respiratoryRate,
                                           baseline: sleepHistory.respiratoryBaselineMean,
                                           baselineSamples: sleepHistory.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
    }

    private var skinTemperatureDeviationZone: AtriaMetricZone? {
        Metrics.skinTemperatureDeviationZone(summary.skinTemperatureDeviation,
                                             greenDelta: skinTemperatureGreenDelta,
                                             yellowDelta: skinTemperatureYellowDelta)
    }

    private var bloodOxygenResearchZone: AtriaMetricZone? {
        Metrics.bloodOxygenResearchZone(candidateFrames: summary.spo2CandidateFrames,
                                        goalFrames: bloodOxygenCandidateGoal)
    }

    private var strapStepsZone: AtriaMetricZone? {
        Metrics.stepsZone(summary.strapStepCount > 0 ? summary.strapStepCount : nil,
                          goal: stepsGoal).map {
            AtriaMetricZone(level: $0.level,
                            title: "Strap step research goal",
                            current: $0.current,
                            targetSummary: $0.targetSummary,
                            recommendation: "\($0.recommendation) Strap steps remain research-tier until motion agreement is validated.",
                            disclaimer: "Research strap-step estimate. \(AtriaMetricZone.nonMedicalDisclaimer)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Sensor signals", subtitle: "")
                Spacer(minLength: 0)
                Button {
                    showResearchInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                }
                .atriaCardAction(prominent: false, tint: .blue)
                .accessibilityLabel("Sensor research info")
                AtriaStateBadge(state: hasEvidence ? .research : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Blood oxygen",
                                value: summary.spo2CandidateFrames > 0 ? "Research" : "--",
                                unit: nil,
                                state: summary.spo2CandidateFrames > 0 ? .research : .learning,
                                tint: bloodOxygenResearchZone?.tint ?? .blue,
                                footnote: summary.spo2CandidateFrames > 0 ? "\(summary.spo2CandidateFrames) candidate frames; not a SpO2 value." : "Early signal; not a SpO2 value.",
                                zone: bloodOxygenResearchZone)
                AtriaMetricTile(label: "Body temp",
                                value: summary.skinTemperatureDeviation.valueText,
                                unit: summary.skinTemperatureDeviation.isReady ? "delta C" : nil,
                                state: summary.skinTemperatureDeviation.isReady ? .research : .learning,
                                tint: skinTemperatureDeviationZone?.tint ?? (summary.skinTemperatureDeviation.isReady ? .teal : .orange),
                                footnote: summary.skinTemperatureDeviation.footnoteText,
                                zone: skinTemperatureDeviationZone)
                AtriaMetricTile(label: "Resp rate",
                                value: latestRespiratoryRate,
                                unit: latestRespiratoryRate == "--" ? nil : "/min",
                                state: latestRespiratoryRate == "--" ? .learning : .research,
                                tint: respiratoryRateZone?.tint ?? .teal,
                                footnote: "Sleep-only estimate; needs comparison data.",
                                zone: respiratoryRateZone)
                AtriaMetricTile(label: "Strap steps",
                                value: summary.strapStepText,
                                state: summary.strapStepCount > 0 ? .research : .learning,
                                tint: strapStepsZone?.tint ?? .green,
                                footnote: summary.agreementText,
                                zone: strapStepsZone)
            }

            Text("Early sensor rows show evidence counts, not measurements. Atria shows skin temperature only as a sleep-baseline deviation, never as an absolute body-temperature value.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .sheet(isPresented: $showResearchInfo) {
            AtriaResearchSignalInfoSheet(spo2CandidateFrames: summary.spo2CandidateFrames,
                                         skinTemperatureSummary: summary.skinTemperatureDeviation)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaResearchSignalInfoSheet: View {
    let spo2CandidateFrames: Int
    let skinTemperatureSummary: IMUAuditSummary.SkinTemperatureDeviationSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                researchInfoRow(systemImage: "drop.degreesign",
                                tint: .blue,
                                title: "Blood oxygen research",
                                detail: spo2CandidateFrames > 0
                                    ? "\(spo2CandidateFrames) candidate frames found. Atria does not show an SpO2 percentage until this protocol is validated."
                                    : "No candidate frames yet. Atria does not estimate or display an SpO2 percentage from unvalidated bytes.")

                researchInfoRow(systemImage: "thermometer.variable",
                                tint: .teal,
                                title: "Body temperature research",
                                detail: skinTemperatureSummary.isReady
                                    ? "\(skinTemperatureSummary.valueText) delta C versus your local sleep baseline. This is not an absolute body-temperature reading."
                                    : "Atria is building a sleep baseline. It will only show relative deviation, never absolute body temperature.")

                Text("Research signals are local, sleep-gated, and not medical advice. Atria does not write SpO2 or body-temperature values to HealthKit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Sensor research")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
    }

    private func researchInfoRow(systemImage: String,
                                 tint: Color,
                                 title: String,
                                 detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .atriaInsetCard(tint: tint)
    }
}

private struct AtriaCollectionBiologicalAgeCardHost: View {
    @ObservedObject var profileMetricsStore: AtriaHomeModel.ProfileMetricsStore
    @AppStorage("atria.target.bioAge.greenOlderDelta") private var biologicalAgeGreenOlderDelta: Int = 0
    @AppStorage("atria.target.bioAge.yellowOlderDelta") private var biologicalAgeYellowOlderDelta: Int = 3

    var body: some View {
        AtriaCollectionBiologicalAgeCard(summary: profileMetricsStore.state.biologicalAgeSummary,
                                         greenOlderDelta: biologicalAgeGreenOlderDelta,
                                         yellowOlderDelta: biologicalAgeYellowOlderDelta)
            .equatable()
    }
}

private struct AtriaCollectionBiologicalAgeCard: View, Equatable {
    let summary: BiologicalAgeSummary
    let greenOlderDelta: Int
    let yellowOlderDelta: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Biological Age", subtitle: summary.narrative)
                Spacer(minLength: 0)
                AtriaStateBadge(state: summary.isReady ? .estimate : .learning)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaMetricTile(label: "Body age",
                                value: summary.valueText,
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (summary.isReady ? .purple : .orange),
                                footnote: summary.isReady ? summary.detailText : "Building baseline",
                                zone: biologicalAgeZone)
                AtriaMetricTile(label: "Delta",
                                value: summary.ageDelta.map { "\($0 > 0 ? "+" : "")\($0)" } ?? "--",
                                unit: summary.ageDelta == nil ? nil : "yr",
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? deltaTint,
                                footnote: summary.isReady ? summary.detailText : "Needs baseline",
                                zone: biologicalAgeZone)
                AtriaMetricTile(label: "Pace",
                                value: summary.agingPaceText,
                                state: summary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? deltaTint,
                                footnote: summary.agingPaceDetail)
            }

            if summary.factors.isEmpty {
                Text(summary.blockerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(summary.factors) { factor in
                        AtriaBioAgeFactorRow(factor: factor)
                    }
                }
            }

            Text(summary.footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var deltaTint: Color {
        guard let ageDelta = summary.ageDelta else { return .orange }
        if ageDelta == 0 { return .blue }
        return ageDelta < 0 ? .green : .orange
    }

    private var biologicalAgeZone: AtriaMetricZone? {
        Metrics.biologicalAgeZone(summary,
                                  greenOlderDelta: greenOlderDelta,
                                  yellowOlderDelta: yellowOlderDelta)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaBioAgeFactorRow: View, Equatable {
    let factor: BioAgeFactor

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: tint))

            VStack(alignment: .leading, spacing: 2) {
                Text(factor.label)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(factor.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            Text(factor.deltaText)
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(10)
        .atriaInsetCard(tint: tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(factor.label), \(factor.deltaText), \(factor.detail)")
    }

    private var tint: Color {
        switch factor.direction {
        case .younger: return .green
        case .older: return .orange
        case .neutral: return .blue
        }
    }

    private var icon: String {
        switch factor.direction {
        case .younger: return "arrow.down.forward.circle.fill"
        case .older: return "arrow.up.forward.circle.fill"
        case .neutral: return "equal.circle.fill"
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

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
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

            Text("Early motion signals stay separate until they match phone motion reliably.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaResearchManeuverMarkerCard: View, Equatable {
    private static let relativeMarkerFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

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

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
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

            Text("Markers stay on device and help compare probe timing.")
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
        return Self.relativeMarkerFormatter.localizedString(for: marker.timestamp, relativeTo: Date())
    }

    private static let buttonColumns = [GridItem(.flexible()), GridItem(.flexible())]
    private static let statColumns = AtriaMetricTile.gridColumns
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
                        title: "Battery saver",
                        subtitle: collectionLiveStore.state.standardHROnlyEnabled
                            ? "Heart-rate only. HR stays live; HRV, Recovery and sleep detail wait for validated beat-to-beat windows."
                            : "Full sensor mode. Beat-to-beat, HRV, Recovery and sleep research stay available.",
                        systemImage: collectionLiveStore.state.standardHROnlyEnabled ? "battery.75percent" : "waveform.path.ecg",
                        tint: collectionLiveStore.state.standardHROnlyEnabled ? .green : .purple,
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
    let officialAppInstalled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Data status", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: collectionLiveStore.state.officialAppCoexistenceRisk == .suspected ? .conflict : .local)
            }

            if collectionLiveStore.state.officialAppCoexistenceRisk != .cleared {
                AtriaCollectionCoexistenceWarning(risk: collectionLiveStore.state.officialAppCoexistenceRisk,
                                                  officialAppInstalled: officialAppInstalled)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
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
                        value: coreLiveStore.state.batteryStatusSummaryText,
                        state: coreLiveStore.state.batteryLevel >= 0 ? .live : .learning,
                        tint: coreLiveStore.state.batteryShowsPowered ? .green : .blue,
                        footnote: coreLiveStore.state.batteryDetailText)
        AtriaMetricTile(label: "Mode",
                        value: collectionLiveStore.state.modeLabel,
                        state: collectionLiveStore.state.longWearModeEnabled ? .live : .local,
                        tint: .purple)
        AtriaMetricTile(label: "App",
                        value: coexistenceValue,
                        state: coexistenceState,
                        tint: coexistenceTint,
                        footnote: coexistenceFootnote)
        AtriaMetricTile(label: "Backfill",
                        value: store.historicalArchiveStatus.valueText,
                        state: backfillState,
                        tint: .cyan,
                        footnote: store.historicalArchiveStatus.userFootnoteText)
    }

    private var backfillState: AtriaMetricState {
        if !store.historicalArchiveStatus.parseOK { return .conflict }
        if store.historicalArchiveStatus.metricReady { return .validated }
        if store.historicalArchiveStatus.hasArchiveRows { return .local }
        return .learning
    }

    private var coexistenceValue: String {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return "Clear"
        case .advisory:
            return "Monitor"
        case .suspected:
            return "Conflict"
        }
    }

    private var coexistenceState: AtriaMetricState {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .local
        case .advisory:
            return .local
        case .suspected:
            return .conflict
        }
    }

    private var coexistenceTint: Color {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return .green
        case .advisory:
            return .orange
        case .suspected:
            return .red
        }
    }

    private var coexistenceFootnote: String {
        switch collectionLiveStore.state.officialAppCoexistenceRisk {
        case .cleared:
            return "Atria has the strap."
        case .advisory:
            return "Close the official app if drops return."
        case .suspected:
            return "Uninstall or disable the official app before relying on Atria."
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionCoexistenceWarning: View, Equatable {
    let risk: AtriaBLEManager.OfficialAppCoexistenceRisk
    let officialAppInstalled: Bool

    private var title: String {
        if risk == .suspected {
            return officialAppInstalled ? "App conflict" : "Connection keeps dropping"
        }
        return "Strap check"
    }

    private var detail: String {
        switch risk {
        case .suspected where officialAppInstalled:
            return "Remove the official strap app, then reconnect."
        case .suspected:
            return "Forget the strap in Bluetooth, then reconnect."
        case .advisory:
            return "Remove the official strap app if drops return."
        case .cleared:
            return "Atria has the strap."
        }
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
    let restingHeartRate: Int
    let restingHeartRateText: String
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    @State private var showHeartRateExplorer = false

    static func == (lhs: AtriaPulseCard, rhs: AtriaPulseCard) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.live == rhs.live
            && lhs.restingHeartRate == rhs.restingHeartRate
            && lhs.restingHeartRateText == rhs.restingHeartRateText
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.restingGreenDelta == rhs.restingGreenDelta
            && lhs.restingYellowDelta == rhs.restingYellowDelta
    }

    private var hasReadablePulse: Bool {
        live.hasPulseSignal
    }

    private var pulseState: AtriaMetricState {
        hasReadablePulse ? .live : .noContact
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(restingHeartRate,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart rate", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: pulseState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
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
                        tint: restingHeartRateZone?.tint ?? .blue,
                        zone: restingHeartRateZone)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
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

                AtriaHeartRateAxisChart(points: points,
                                        yDomain: AtriaHeartRateChartSeries.yDomain(for: points),
                                        selectedTime: .constant(nil))
                    .padding(.top, 2)
                    .padding(.trailing, 2)
                    .frame(maxWidth: .infinity)
                    .frame(height: 170)
                    .background(Color(.systemBackground).opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .clipped()

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
            .clipShape(RoundedRectangle(cornerRadius: AtriaDesignTokens.Radius.inset, style: .continuous))
            .clipped()
            .compositingGroup()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open heart rate timeline")
    }
}

private struct AtriaHeartRateChartSeries: Equatable {
    let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>

    static func make(points: [AtriaHomeModel.HeartRateChartPoint], zoom: Double) -> AtriaHeartRateChartSeries {
        let visiblePoints: [AtriaHomeModel.HeartRateChartPoint]
        if zoom > 1, points.count > 8 {
            let keep = max(8, Int(Double(points.count) / zoom))
            visiblePoints = Array(points.suffix(keep))
        } else {
            visiblePoints = points
        }
        return AtriaHeartRateChartSeries(visiblePoints: visiblePoints,
                                         yDomain: yDomain(for: visiblePoints))
    }

    static func yDomain(for points: [AtriaHomeModel.HeartRateChartPoint]) -> ClosedRange<Int> {
        var minimumBPM: Int?
        var maximumBPM: Int?
        for point in points {
            minimumBPM = min(minimumBPM ?? point.bpm, point.bpm)
            maximumBPM = max(maximumBPM ?? point.bpm, point.bpm)
        }
        let low = max((minimumBPM ?? 60) - 8, 35)
        let high = min((maximumBPM ?? 120) + 8, 220)
        return low...max(high, low + 20)
    }

    func nearestPoint(to selectedTime: Date?) -> AtriaHomeModel.HeartRateChartPoint? {
        guard let selectedTime else { return visiblePoints.last }
        guard !visiblePoints.isEmpty else { return nil }
        var low = 0
        var high = visiblePoints.count
        while low < high {
            let mid = (low + high) / 2
            if visiblePoints[mid].t < selectedTime {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return visiblePoints[0] }
        if low >= visiblePoints.count { return visiblePoints[visiblePoints.count - 1] }
        let before = visiblePoints[low - 1]
        let after = visiblePoints[low]
        return abs(before.t.timeIntervalSince(selectedTime)) <= abs(after.t.timeIntervalSince(selectedTime))
            ? before
            : after
    }
}

private struct AtriaHeartRateExplorer: View {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let currentBPM: Int
    let onDismiss: () -> Void
    @State private var selectedTime: Date?
    @State private var zoom: Double = 1
    @State private var series: AtriaHeartRateChartSeries
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(points: [AtriaHomeModel.HeartRateChartPoint],
         currentBPM: Int,
         onDismiss: @escaping () -> Void) {
        self.points = points
        self.currentBPM = currentBPM
        self.onDismiss = onDismiss
        _series = State(initialValue: AtriaHeartRateChartSeries.make(points: points, zoom: 1))
    }

    private var selectedPoint: AtriaHomeModel.HeartRateChartPoint? {
        series.nearestPoint(to: selectedTime)
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

                AtriaHeartRateAxisChart(points: series.visiblePoints,
                                        yDomain: series.yDomain,
                                        selectedTime: $selectedTime)
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
            .background(AtriaBackdropLayer(isDark: colorScheme == .dark,
                                           reduceTransparency: reduceTransparency).ignoresSafeArea())
            .navigationTitle("Heart rate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onDismiss) {
                        Label("Done", systemImage: "xmark")
                    }
                    .labelStyle(.iconOnly)
                    .atriaCardAction(prominent: false, tint: .secondary)
                    .accessibilityLabel("Done")
                }
            }
            .onChange(of: zoom) { _, newValue in
                series = AtriaHeartRateChartSeries.make(points: points, zoom: newValue)
            }
            .onChange(of: points) { _, newValue in
                series = AtriaHeartRateChartSeries.make(points: newValue, zoom: zoom)
            }
        }
    }
}

private struct AtriaHeartRateAxisChart: View, Equatable {
    let points: [AtriaHomeModel.HeartRateChartPoint]
    let yDomain: ClosedRange<Int>
    @Binding var selectedTime: Date?

    static func == (lhs: AtriaHeartRateAxisChart, rhs: AtriaHeartRateAxisChart) -> Bool {
        lhs.points == rhs.points && lhs.yDomain == rhs.yDomain
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.t),
                     yStart: .value("Visible floor", yDomain.lowerBound),
                     yEnd: .value("BPM", point.bpm))
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
        .chartPlotStyle { plotArea in
            plotArea
                .contentShape(Rectangle())
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipped()
        }
        .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipped()
    }
}

private struct AtriaHRVCard: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let hero: AtriaHomeModel.HeroSnapshot
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let hrvGreenRatio: Double
    let hrvYellowRatio: Double

    static func == (lhs: AtriaHRVCard, rhs: AtriaHRVCard) -> Bool {
        lhs.live == rhs.live
            && lhs.hero == rhs.hero
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.hrvGreenRatio == rhs.hrvGreenRatio
            && lhs.hrvYellowRatio == rhs.hrvYellowRatio
    }

    private var continuityTint: Color {
        live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .orange : .pink
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(Self.parseInt(hero.hrvValue),
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "HRV", subtitle: "")

                Spacer(minLength: 0)

                AtriaStateBadge(state: hrvState)
            }

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                hrvStatTiles
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    private var hrvState: AtriaMetricState {
        let detail = hero.hrvDetail.lowercased()
        if detail.contains("validated") { return .validated }
        if detail.contains("personal baseline") || detail.contains("% kept") { return .personalBaseline }
        return .learning
    }

    private var isConnected: Bool {
        live.status == .connected
    }

    @ViewBuilder
    private var hrvStatTiles: some View {
        AtriaMetricTile(label: "RMSSD",
                        value: hero.hrvValue,
                        state: hrvState,
                        tint: hrvZone?.tint ?? .pink,
                        footnote: hero.hrvDetail,
                        zone: hrvZone)
        AtriaMetricTile(label: "Window",
                        value: hero.rrPackageText,
                        state: isConnected && !live.rrContinuityText.localizedCaseInsensitiveContains("waiting") ? .live : .learning,
                        tint: continuityTint)
        AtriaMetricTile(label: "SDNN",
                        value: live.hrvSDNNText,
                        unit: live.hrvSDNN == nil ? nil : "ms",
                        state: live.hrvSDNN == nil ? .learning : hrvState,
                        tint: .indigo,
                        footnote: "Secondary HRV metric from the same steady beat-to-beat window.")
        AtriaMetricTile(label: "pNN50",
                        value: live.hrvPNN50Text,
                        state: live.hrvPNN50 == nil ? .learning : hrvState,
                        tint: .purple,
                        footnote: "Share of adjacent beat intervals differing by more than 50 ms.")
        AtriaMetricTile(label: "Stress",
                        value: hero.stressValue,
                        state: .local,
                        tint: .purple)
    }

    private static let statColumns = AtriaMetricTile.gridColumns

    private static func parseInt(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }
}

private struct AtriaRecoveryStrainCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let sleepHistory: SleepHistorySnapshot
    let recoveryTarget: AtriaMetricTarget
    let strainGreenBand: Double
    let strainYellowBand: Double
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let hrvGreenRatio: Double
    let hrvYellowRatio: Double
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    let respiratoryGreenDelta: Double
    let respiratoryYellowDelta: Double
    let sleepGoalHours: Double
    let sleepEfficiencyGreenLower: Double
    let sleepEfficiencyYellowLower: Double
    let onAddManualSleep: (Date, Date, Bool) -> Void

    static func == (lhs: AtriaRecoveryStrainCard, rhs: AtriaRecoveryStrainCard) -> Bool {
        lhs.hero == rhs.hero
            && lhs.sleepHistory == rhs.sleepHistory
            && lhs.recoveryTarget == rhs.recoveryTarget
            && lhs.strainGreenBand == rhs.strainGreenBand
            && lhs.strainYellowBand == rhs.strainYellowBand
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.hrvGreenRatio == rhs.hrvGreenRatio
            && lhs.hrvYellowRatio == rhs.hrvYellowRatio
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
            && lhs.restingGreenDelta == rhs.restingGreenDelta
            && lhs.restingYellowDelta == rhs.restingYellowDelta
            && lhs.respiratoryGreenDelta == rhs.respiratoryGreenDelta
            && lhs.respiratoryYellowDelta == rhs.respiratoryYellowDelta
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.sleepEfficiencyGreenLower == rhs.sleepEfficiencyGreenLower
            && lhs.sleepEfficiencyYellowLower == rhs.sleepEfficiencyYellowLower
    }

    private var recoveryState: AtriaMetricState {
        switch hero.recoveryEstimate.confidence {
        case .validated:
            return .validated
        case .personalBaseline:
            return .personalBaseline
        case .unverified:
            return .research
        case .learning:
            return .learning
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "")

            recoveryStrainVisuals
            metricContent
            AtriaSleepHistoryCard(snapshot: sleepHistory,
                                  hrvBaseline: hrvBaseline,
                                  hrvBaselineSamples: hrvBaselineSamples,
                                  hrvBaselineTrusted: hrvBaselineTrusted,
                                  baselineTarget: baselineTarget,
                                  hrvGreenRatio: hrvGreenRatio,
                                  hrvYellowRatio: hrvYellowRatio,
                                  restingBaseline: restingBaseline,
                                  restingBaselineSamples: restingBaselineSamples,
                                  restingBaselineTrusted: restingBaselineTrusted,
                                  restingGreenDelta: restingGreenDelta,
                                  restingYellowDelta: restingYellowDelta,
                                  respiratoryGreenDelta: respiratoryGreenDelta,
                                  respiratoryYellowDelta: respiratoryYellowDelta,
                                  sleepGoalHours: sleepGoalHours,
                                  sleepEfficiencyGreenLower: sleepEfficiencyGreenLower,
                                  sleepEfficiencyYellowLower: sleepEfficiencyYellowLower,
                                  onAddManualSleep: onAddManualSleep)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var metricContent: some View {
        LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
            recoveryStrainTiles
        }
    }

    private var recoveryStrainVisuals: some View {
        HStack(spacing: 14) {
            AtriaMetricRing(label: "Recovery",
                            value: hero.recoveryEstimate.percent.map { "\($0)%" } ?? "--",
                            fraction: recoveryFraction,
                            tint: recoveryZone?.tint ?? hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange,
                            size: 112)
            AtriaMetricRing(label: "Strain",
                            value: String(format: "%.1f", hero.strain),
                            fraction: strainFraction,
                            tint: strainZone?.tint ?? Metrics.strainColor(hero.strain),
                            size: 112)

            VStack(alignment: .leading, spacing: 8) {
                Text(hero.guidance.headline)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(hero.loadSignalSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .atriaInsetCard(tint: recoveryZone?.tint ?? .green)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recovery \(hero.recoveryEstimate.percent.map { "\($0) percent" } ?? "learning"), strain \(String(format: "%.1f", hero.strain)). \(hero.loadSignalSummaryText)")
    }

    @ViewBuilder
    private var recoveryStrainTiles: some View {
        AtriaMetricTile(label: "Recovery",
                        value: hero.recoveryEstimate.percent.map { "\($0)" } ?? "--",
                        unit: hero.recoveryEstimate.percent == nil ? nil : "%",
                        state: recoveryState,
                        tint: recoveryZone?.tint ?? hero.recoveryEstimate.percent.map(Metrics.recoveryColor) ?? .orange,
                        footnote: hero.recoveryEstimate.confidence.rawValue,
                        zone: recoveryZone)
        AtriaMetricTile(label: "Strain",
                        value: String(format: "%.1f", hero.strain),
                        state: .local,
                        tint: strainZone?.tint ?? Metrics.strainColor(hero.strain),
                        zone: strainZone)
        AtriaTrainingLoadTile(ratio: hero.loadRatioText,
                              target: hero.loadTargetText,
                              confidence: hero.loadConfidence,
                              readiness: hero.loadReadinessText,
                              acwrSignal: hero.loadACWRSignalText,
                              monotony: hero.loadMonotonyText,
                              monotonySignal: hero.loadMonotonySignalText,
                              acwrDetail: hero.loadACWRDetailText,
                              monotonyDetail: hero.loadMonotonyDetailText,
                              signalSummary: hero.loadSignalSummaryText,
                              narrative: hero.loadNarrative)
    }

    private static let statColumns = AtriaMetricTile.gridColumns

    private var recoveryZone: AtriaMetricZone? {
        Metrics.recoveryZone(hero.recoveryEstimate.percent, target: recoveryTarget)
    }

    private var strainZone: AtriaMetricZone? {
        Metrics.strainZone(strain: hero.strain,
                           target: hero.guidance.target,
                           greenBand: strainGreenBand,
                           yellowBand: strainYellowBand)
    }

    private var recoveryFraction: Double? {
        hero.recoveryEstimate.percent.map { min(max(Double($0) / 100, 0), 1) }
    }

    private var strainFraction: Double? {
        min(max(hero.strain / 21, 0), 1)
    }
}

private struct AtriaSleepHistoryCard: View, Equatable {
    let snapshot: SleepHistorySnapshot
    let hrvBaseline: Int?
    let hrvBaselineSamples: Int
    let hrvBaselineTrusted: Bool
    let baselineTarget: AtriaBaselineTargetSnapshot
    let hrvGreenRatio: Double
    let hrvYellowRatio: Double
    let restingBaseline: Int?
    let restingBaselineSamples: Int
    let restingBaselineTrusted: Bool
    let restingGreenDelta: Int
    let restingYellowDelta: Int
    let respiratoryGreenDelta: Double
    let respiratoryYellowDelta: Double
    let sleepGoalHours: Double
    let sleepEfficiencyGreenLower: Double
    let sleepEfficiencyYellowLower: Double
    let onAddManualSleep: (Date, Date, Bool) -> Void
    @State private var showManualSleepSheet = false

    static func == (lhs: AtriaSleepHistoryCard, rhs: AtriaSleepHistoryCard) -> Bool {
        lhs.snapshot == rhs.snapshot
            && lhs.hrvBaseline == rhs.hrvBaseline
            && lhs.hrvBaselineSamples == rhs.hrvBaselineSamples
            && lhs.hrvBaselineTrusted == rhs.hrvBaselineTrusted
            && lhs.baselineTarget == rhs.baselineTarget
            && lhs.hrvGreenRatio == rhs.hrvGreenRatio
            && lhs.hrvYellowRatio == rhs.hrvYellowRatio
            && lhs.restingBaseline == rhs.restingBaseline
            && lhs.restingBaselineSamples == rhs.restingBaselineSamples
            && lhs.restingBaselineTrusted == rhs.restingBaselineTrusted
            && lhs.restingGreenDelta == rhs.restingGreenDelta
            && lhs.restingYellowDelta == rhs.restingYellowDelta
            && lhs.respiratoryGreenDelta == rhs.respiratoryGreenDelta
            && lhs.respiratoryYellowDelta == rhs.respiratoryYellowDelta
            && lhs.sleepGoalHours == rhs.sleepGoalHours
            && lhs.sleepEfficiencyGreenLower == rhs.sleepEfficiencyGreenLower
            && lhs.sleepEfficiencyYellowLower == rhs.sleepEfficiencyYellowLower
    }

    private var chartNights: [SleepHistorySnapshot.Night] {
        Array(snapshot.nights.prefix(7).reversed())
    }

    private var heatStripNights: [SleepHistorySnapshot.Night] {
        Array(snapshot.nights.prefix(84).reversed())
    }

    private var emptyEvidenceState: AtriaMetricState {
        if snapshot.confirmedCount > 0 { return .validated }
        if snapshot.candidateCount > 0 { return .research }
        return .learning
    }

    private var latestEvidenceFootnote: String {
        guard let latest = snapshot.latest else { return "No saved sleep yet." }
        return latest.confirmed
            ? "\(latest.confidenceText) · \(latest.confirmationText)"
            : "\(latest.confidenceText) · \(latest.confirmationText.lowercased())"
    }

    private var restingHeartRateZone: AtriaMetricZone? {
        Metrics.restingHeartRateZone(snapshot.latest?.restingHR,
                                     baseline: restingBaseline,
                                     baselineSamples: restingBaselineSamples,
                                     baselineTrusted: restingBaselineTrusted,
                                     baselineTarget: baselineTarget,
                                     greenDelta: restingGreenDelta,
                                     yellowDelta: restingYellowDelta)
    }

    private var sleepDurationZone: AtriaMetricZone? {
        Metrics.sleepDurationZone(snapshot.latest?.durationHours, goalHours: sleepGoalHours)
    }

    private var sleepEfficiencyZone: AtriaMetricZone? {
        Metrics.sleepEfficiencyZone(snapshot.latest?.sleepEfficiency,
                                    greenLower: sleepEfficiencyGreenLower,
                                    yellowLower: sleepEfficiencyYellowLower)
    }

    private var hrvZone: AtriaMetricZone? {
        Metrics.hrvZone(snapshot.latest?.hrv,
                        baseline: hrvBaseline,
                        baselineSamples: hrvBaselineSamples,
                        baselineTrusted: hrvBaselineTrusted,
                        baselineTarget: baselineTarget,
                        greenRatio: hrvGreenRatio,
                        yellowRatio: hrvYellowRatio)
    }

    private var respiratoryRateZone: AtriaMetricZone? {
        return Metrics.respiratoryRateZone(snapshot.latest?.respiratoryRate,
                                           baseline: snapshot.respiratoryBaselineMean,
                                           baselineSamples: snapshot.respiratoryBaselineCount,
                                           greenDelta: respiratoryGreenDelta,
                                           yellowDelta: respiratoryYellowDelta)
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
                Button {
                    showManualSleepSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 18, height: 18)
                }
                .atriaCardAction(prominent: false, tint: .cyan)
                .accessibilityLabel("Add sleep manually")
                AtriaStateBadge(state: snapshot.confirmedCount > 0 ? .validated : (snapshot.candidateCount > 0 ? .research : .learning))
            }

            if snapshot.nights.isEmpty {
                AtriaMetricTile(label: snapshot.emptyEvidenceLabel,
                                value: snapshot.emptyEvidenceValue,
                                state: emptyEvidenceState,
                                tint: .cyan,
                                footnote: snapshot.emptyEvidenceFootnote)
            } else {
                LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                    AtriaMetricTile(label: snapshot.latest?.evidenceLabel ?? "Latest",
                                    value: snapshot.latest?.durationText ?? "--",
                                    state: snapshot.latest?.confirmed == true ? .validated : .research,
                                    tint: sleepDurationZone?.tint ?? .cyan,
                                    footnote: latestEvidenceFootnote,
                                    zone: sleepDurationZone)
                    AtriaMetricTile(label: "Average",
                                    value: snapshot.averageDurationText,
                                    state: .local,
                                    tint: .blue,
                                    footnote: snapshot.averageFootnoteText)
                    AtriaMetricTile(label: "Consistency",
                                    value: snapshot.sleepConsistencyText,
                                    state: snapshot.sleepConsistencyText == "--" ? .learning : .local,
                                    tint: .mint,
                                    footnote: snapshot.sleepConsistencyFootnote)
                    AtriaMetricTile(label: "Debt",
                                    value: snapshot.sleepDebtText(goalHours: sleepGoalHours),
                                    state: snapshot.sleepDebtText(goalHours: sleepGoalHours) == "--" ? .learning : .local,
                                    tint: .indigo,
                                    footnote: snapshot.sleepDebtFootnote(goalHours: sleepGoalHours))
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") RHR",
                                    value: snapshot.latest?.restingHRText ?? "--",
                                    unit: snapshot.latest?.restingHR == nil ? nil : "bpm",
                                    state: snapshot.latest?.restingHR == nil ? .learning : .personalBaseline,
                                    tint: restingHeartRateZone?.tint ?? .red,
                                    zone: restingHeartRateZone)
                    AtriaMetricTile(label: "Efficiency",
                                    value: snapshot.latest?.sleepEfficiencyText ?? "--",
                                    state: snapshot.latest?.sleepEfficiency == nil ? .learning : .research,
                                    tint: sleepEfficiencyZone?.tint ?? .cyan,
                                    footnote: "Duration-based estimate",
                                    zone: sleepEfficiencyZone)
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") HRV",
                                    value: snapshot.latest?.hrvText ?? "--",
                                    unit: snapshot.latest?.hrv == nil ? nil : "ms",
                                    state: snapshot.latest?.hrv == nil ? .learning : .research,
                                    tint: hrvZone?.tint ?? .purple,
                                    footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: hrvZone)
                    AtriaMetricTile(label: "\(snapshot.latest?.evidenceLabel ?? "Sleep") resp",
                                    value: snapshot.latest?.respiratoryRateText ?? "--",
                                    unit: snapshot.latest?.respiratoryRate == nil ? nil : "/min",
                                    state: snapshot.latest?.respiratoryRate == nil ? .learning : .research,
                                    tint: respiratoryRateZone?.tint ?? .teal,
                                    footnote: snapshot.latest?.evidenceOnlyFootnote ?? "Sleep-only estimate",
                                    zone: respiratoryRateZone)
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

                if heatStripNights.count > 7 {
                    AtriaSleepYearHeatStrip(nights: heatStripNights,
                                            goalHours: sleepGoalHours)
                }

                if let latest = snapshot.latest, !latest.displayStageSegments.isEmpty {
                    AtriaSleepStageSummary(night: latest)
                }

                ForEach(snapshot.nights.prefix(3)) { night in
                    AtriaSleepNightRow(night: night)
                }
            }
        }
        .padding(14)
        .atriaInsetCard(tint: .cyan)
        .sheet(isPresented: $showManualSleepSheet) {
            AtriaManualSleepSheet { start, end, isNap in
                onAddManualSleep(start, end, isNap)
                showManualSleepSheet = false
            }
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaSleepYearHeatStrip: View, Equatable {
    let nights: [SleepHistorySnapshot.Night]
    let goalHours: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sleep heat strip")
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text("\(nights.count) nights")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Canvas { context, size in
                drawCells(in: &context, size: size)
            }
            .frame(height: 76)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .accessibilityHidden(true)
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private func drawCells(in context: inout GraphicsContext, size: CGSize) {
        guard !nights.isEmpty else { return }
        let rows = 7
        let gap: CGFloat = 3
        let columns = max(1, Int(ceil(Double(nights.count) / Double(rows))))
        let cell = max(3, min((size.width - gap * CGFloat(columns - 1)) / CGFloat(columns),
                              (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)))
        let totalWidth = CGFloat(columns) * cell + CGFloat(columns - 1) * gap
        let xOffset = max(0, size.width - totalWidth)

        for (index, night) in nights.enumerated() {
            let column = index / rows
            let row = index % rows
            let rect = CGRect(x: xOffset + CGFloat(column) * (cell + gap),
                              y: CGFloat(row) * (cell + gap),
                              width: cell,
                              height: cell)
            context.fill(Path(roundedRect: rect, cornerRadius: min(3, cell / 3)),
                         with: .color(color(for: night)))
        }
    }

    private func color(for night: SleepHistorySnapshot.Night) -> Color {
        let ratio = min(max(night.durationHours / max(goalHours, 0.1), 0), 1)
        let opacity = 0.18 + 0.72 * ratio
        let base: Color = night.confirmed ? .cyan : .teal
        return base.opacity(opacity)
    }

    private var accessibilityText: String {
        guard let latest = nights.last else { return "Sleep heat strip empty." }
        return "Sleep heat strip, \(nights.count) nights, latest \(latest.durationText), \(latest.confirmationText)."
    }
}

private struct AtriaSleepStageSummary: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(night.stageEvidence.label)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                Text(night.evidenceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            AtriaSleepStageHypnogram(segments: night.displayStageSegments,
                                     duration: night.duration)
                .frame(height: 36)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
                ForEach(SleepStageKind.allCases) { stage in
                    HStack(spacing: 7) {
                        Image(systemName: Self.symbol(for: stage))
                            .font(.caption2.weight(.bold))
                            .frame(width: 16, height: 16)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stage.label.uppercased())
                                .font(.caption2.weight(.bold))
                            Text(night.stageText(stage))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(color(for: stage).opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .foregroundStyle(color(for: stage))
                }
            }
        }
        .padding(10)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(night.evidenceLabel) \(night.stageEvidence.label). Awake \(night.stageText(.awake)), Light \(night.stageText(.light)), REM \(night.stageText(.rem)), SWS \(night.stageText(.sws)), Deep \(night.stageText(.deep)).")
    }

    static func symbol(for stage: SleepStageKind) -> String {
        switch stage {
        case .awake: return "sun.max.fill"
        case .light: return "moon.fill"
        case .rem: return "sparkles"
        case .sws: return "waveform.path"
        case .deep: return "moon.stars.fill"
        }
    }

    private func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }
}

private struct AtriaSleepStageHypnogram: View, Equatable {
    let segments: [SleepStageSegment]
    let duration: TimeInterval

    var body: some View {
        Canvas { context, size in
            drawGuides(in: &context, size: size)
            drawSegments(in: &context, size: size)
        }
        .background(Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    private func drawGuides(in context: inout GraphicsContext, size: CGSize) {
        for stage in SleepStageKind.allCases {
            let y = stageY(stage, height: size.height)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
        }
    }

    private func drawSegments(in context: inout GraphicsContext, size: CGSize) {
        guard duration > 0, !segments.isEmpty else { return }
        let laneHeight = max(5, min(8, size.height / 5))
        var elapsed: TimeInterval = 0
        for segment in segments {
            let width = max(1, size.width * segment.duration / duration)
            let x = size.width * elapsed / duration
            let y = stageY(segment.stage, height: size.height) - laneHeight / 2
            let rect = CGRect(x: x,
                              y: y,
                              width: min(width, max(0, size.width - x)),
                              height: laneHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: laneHeight / 2),
                         with: .color(color(for: segment.stage)))
            elapsed += segment.duration
        }
    }

    private func stageY(_ stage: SleepStageKind, height: CGFloat) -> CGFloat {
        switch stage {
        case .awake: return height * 0.14
        case .light: return height * 0.34
        case .rem: return height * 0.52
        case .sws: return height * 0.70
        case .deep: return height * 0.88
        }
    }

    private func color(for stage: SleepStageKind) -> Color {
        switch stage {
        case .awake: return .orange
        case .light: return .cyan
        case .rem: return .indigo
        case .sws: return .blue
        case .deep: return .purple
        }
    }
}

private struct AtriaSleepNightRow: View, Equatable {
    let night: SleepHistorySnapshot.Night

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: night.confirmed ? "checkmark.seal.fill" : (night.isNapEvidence ? "moon.zzz.fill" : "bed.double.fill"))
                .font(.caption.weight(.bold))
                .foregroundStyle(night.confirmed ? .green : .teal)
                .frame(width: 24, height: 24)
                .background(AtriaIconTileBackground(cornerRadius: 8, tint: night.confirmed ? .green : .teal))

            VStack(alignment: .leading, spacing: 2) {
                Text(night.day, format: .dateTime.weekday(.abbreviated).month().day())
                    .font(.caption.weight(.semibold))
                Text("\(night.confirmationText) · \(night.durationText) · Eff \(night.sleepEfficiencyText) · RHR \(night.restingHRText) · HRV \(night.hrvText) · Resp \(night.respiratoryRateText) · \(night.confidenceText)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                if !night.displayStageSegments.isEmpty {
                    Text("\(night.stageEvidence.label) · Awake \(night.stageText(.awake)) · Light \(night.stageText(.light)) · REM \(night.stageText(.rem)) · SWS \(night.stageText(.sws)) · Deep \(night.stageText(.deep))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.cyan)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
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
    let readiness: String
    let acwrSignal: String
    let monotony: String
    let monotonySignal: String
    let acwrDetail: String
    let monotonyDetail: String
    let signalSummary: String
    let narrative: String

    private var confidenceTint: Color {
        switch readiness.lowercased() {
        case "balanced", "primed": return .green
        case "strained": return .orange
        case "rundown": return .red
        default: return confidence == "local" ? .green : .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Text("Readiness")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AtriaStateBadge(state: confidence == "local" ? .local : .learning)
            }

            Text(readiness)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)

            HStack(spacing: 6) {
                AtriaTrainingSignalChip(title: "ACWR", value: ratio, signal: acwrSignal)
                AtriaTrainingSignalChip(title: "Monotony", value: monotony, signal: monotonySignal)
            }

            VStack(alignment: .leading, spacing: 3) {
                Label(acwrDetail, systemImage: "gauge.with.dots.needle.50percent")
                Label(monotonyDetail, systemImage: "waveform.path")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .minimumScaleFactor(0.76)

            Text("Target \(target)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .frame(maxWidth: .infinity,
               minHeight: 164,
               maxHeight: 164,
               alignment: .leading)
        .padding(13)
        .atriaInsetCard(tint: confidenceTint)
            .accessibilityLabel("Readiness \(readiness). \(signalSummary). \(acwrDetail) \(monotonyDetail) \(narrative)")
    }
}

private struct AtriaTrainingSignalChip: View, Equatable {
    let title: String
    let value: String
    let signal: String

    private var tint: Color {
        switch signal.lowercased() {
        case "good": return .green
        case "neutral": return .blue
        case "watch": return .orange
        case "bad": return .red
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
            Text(value)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .minimumScaleFactor(0.72)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
        .foregroundStyle(tint)
    }
}

private struct AtriaProfileCard: View, Equatable {
    let profile: AthleteProfile
    let observedPeakHeartRateText: String
    let vo2MaxEstimate: VO2MaxEstimateSummary
    let biologicalAgeSummary: BiologicalAgeSummary
    let biologicalAgeGreenOlderDelta: Int
    let biologicalAgeYellowOlderDelta: Int
    let vo2GreenDelta: Double
    let vo2RedDelta: Double
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func == (lhs: AtriaProfileCard, rhs: AtriaProfileCard) -> Bool {
        lhs.profile == rhs.profile
            && lhs.observedPeakHeartRateText == rhs.observedPeakHeartRateText
            && lhs.vo2MaxEstimate == rhs.vo2MaxEstimate
            && lhs.biologicalAgeSummary == rhs.biologicalAgeSummary
            && lhs.biologicalAgeGreenOlderDelta == rhs.biologicalAgeGreenOlderDelta
            && lhs.biologicalAgeYellowOlderDelta == rhs.biologicalAgeYellowOlderDelta
            && lhs.vo2GreenDelta == rhs.vo2GreenDelta
            && lhs.vo2RedDelta == rhs.vo2RedDelta
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

            LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
                AtriaInlineQuickStat(label: "Active HRmax", value: "\(profile.maxHR)")
                AtriaInlineQuickStat(label: "Observed peak", value: observedPeakHeartRateText)
                AtriaInlineQuickStat(label: "Source", value: profile.maxHRSource.label)
                AtriaMetricTile(label: "VO2max",
                                value: vo2MaxEstimate.valueText,
                                state: vo2MaxEstimate.value == nil ? .learning : .estimate,
                                tint: vo2TrendZone?.tint ?? .orange,
                                footnote: vo2MaxEstimate.confidence,
                                zone: vo2TrendZone)
                AtriaMetricTile(label: "VO2 trend",
                                value: vo2MaxEstimate.trendText,
                                state: vo2MaxEstimate.value == nil || vo2MaxEstimate.trendText == "Learning" ? .learning : .estimate,
                                tint: vo2TrendZone?.tint ?? .orange,
                                footnote: vo2MaxEstimate.trendDetail,
                                zone: vo2TrendZone)
                AtriaMetricTile(label: "Body age",
                                value: biologicalAgeSummary.valueText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.isReady ? biologicalAgeSummary.detailText : "Building your body-age baseline",
                                zone: biologicalAgeZone)
                AtriaMetricTile(label: "Aging pace",
                                value: biologicalAgeSummary.agingPaceText,
                                state: biologicalAgeSummary.isReady ? .estimate : .learning,
                                tint: biologicalAgeZone?.tint ?? (biologicalAgeSummary.isReady ? .purple : .orange),
                                footnote: biologicalAgeSummary.agingPaceDetail)
            }

            Text(vo2MaxEstimate.narrative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                AtriaPanelSectionHeader(title: "Biological Age", subtitle: biologicalAgeSummary.narrative)
                if biologicalAgeSummary.factors.isEmpty {
                    Text(biologicalAgeSummary.blockerText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(biologicalAgeSummary.factors) { factor in
                        AtriaBioAgeFactorRow(factor: factor)
                    }
                }
                Text(biologicalAgeSummary.footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .atriaInsetCard(tint: .purple)

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

    private var vo2TrendZone: AtriaMetricZone? {
        Metrics.vo2TrendZone(vo2MaxEstimate,
                             greenDelta: vo2GreenDelta,
                             redDelta: vo2RedDelta)
    }

    private var biologicalAgeZone: AtriaMetricZone? {
        Metrics.biologicalAgeZone(biologicalAgeSummary,
                                  greenOlderDelta: biologicalAgeGreenOlderDelta,
                                  yellowOlderDelta: biologicalAgeYellowOlderDelta)
    }

    private static let statColumns = AtriaMetricTile.gridColumns
}

private struct AtriaCollectionReferenceSummaryCard: View, Equatable {
    let leadingTitle: String
    let leadingValue: String
    let leadingDetail: String
    let trailingTitle: String
    let trailingValue: String
    let trailingDetail: String

    var body: some View {
        LazyVGrid(columns: Self.statColumns, spacing: AtriaMetricTile.gridSpacing) {
            AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                value: leadingValue,
                                                detail: leadingDetail)
            AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                value: trailingValue,
                                                detail: trailingDetail)
        }
    }

    private static let statColumns = AtriaMetricTile.gridColumns
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
