import SwiftUI

struct AtriaVitalsTabContent: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.PulseLiveStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: WhoopBLEManager
    let horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        pulseCard
                        hrvCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        recoveryStrainCard
                        profileCard
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    pulseCard
                    hrvCard
                    recoveryStrainCard
                    profileCard
                }
            }
        }
    }

    private var pulseCard: some View {
        AtriaVitalsPulseCardHost(pulseStore: pulseStore,
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
                                   store: store,
                                   onUpdateProfile: store.updateProfile)
    }
}

struct AtriaCollectionTabContent: View {
    let coreLiveStore: AtriaHomeModel.CoreLiveStore
    let collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: WhoopBLEManager
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
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    let pulseSparklineStore: AtriaHomeModel.PulseSparklineStore

    var body: some View {
        AtriaPulseCard(live: pulseStore.state,
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
    @ObservedObject var store: SessionStore
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    var body: some View {
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? 60
        AtriaProfileCard(profile: profileStore.profile,
                         observedPeakHeartRateText: pulseStore.state.peakHeartRateText,
                         vo2MaxEstimate: store.vo2MaxEstimateSummary(rest: rest,
                                                                     maxHR: profileStore.profile.maxHR),
                         onUpdateProfile: onUpdateProfile)
            .equatable()
    }
}

private struct AtriaCollectionCaptureCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    let ble: WhoopBLEManager
    @Binding var captureShareURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Capture", subtitle: "Start quickly and keep exports local")

                Spacer(minLength: 0)

                AtriaStatusChip(text: collectionLiveStore.state.recordingState,
                                systemImage: collectionLiveStore.state.isRecording ? "record.circle.fill" : "pause.circle",
                                tint: collectionLiveStore.state.isRecording ? .red : .blue)
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    captureStats
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    captureStats
                }
            }

            Text(collectionLiveStore.state.captureSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GlassEffectContainer(spacing: 10) {
                captureActions
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var captureStats: some View {
        AtriaInlineQuickStat(label: "Samples", value: "\(collectionLiveStore.state.capturedRows)")
        AtriaInlineQuickStat(label: "State", value: collectionLiveStore.state.recordingState)
        AtriaInlineQuickStat(label: "Export", value: collectionLiveStore.state.captureFileLabel)
    }

    @ViewBuilder
    private var captureActions: some View {
        ViewThatFits {
            HStack(spacing: 10) {
                captureActionButtons
            }

            VStack(spacing: 10) {
                captureActionButtons
            }
        }
    }

    @ViewBuilder
    private var captureActionButtons: some View {
        Button(collectionLiveStore.state.isRecording ? "Stop capture" : "Start capture") {
            ble.toggleRecording()
        }
        .buttonStyle(.glassProminent)
        .tint(collectionLiveStore.state.isRecording ? .red : .blue)

        Button("Prepare export") {
            captureShareURL = ble.exportCSV()
        }
        .buttonStyle(.glassProminent)
        .tint(.gray)

        if let captureShareURL {
            ShareLink(item: captureShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
        .tint(.green)
        }
    }
}

private struct AtriaCollectionRRReferenceCardHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    let store: SessionStore
    @Binding var showRRImporter: Bool
    @Binding var rrShareURL: URL?
    let rrImportStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "RR reference", subtitle: "Validate local HRV with an external file")

                Spacer(minLength: 0)

                AtriaStatusChip(text: homeStatsStore.state.rrPackageText,
                                systemImage: "waveform.path.ecg",
                                tint: .pink)
            }

            AtriaCollectionReferenceSummaryCard(
                leadingTitle: "RR package",
                leadingValue: homeStatsStore.state.rrPackageText,
                leadingDetail: homeStatsStore.state.hrvDetail,
                trailingTitle: "Flow",
                trailingValue: "Export or import",
                trailingDetail: "local file handoff"
            )

            if !rrImportStatus.isEmpty {
                Text(rrImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits {
                HStack(spacing: 10) {
                    rrActionButtons
                }

                VStack(spacing: 10) {
                    rrActionButtons
                }
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var rrActionButtons: some View {
        Button("Export RR") {
            rrShareURL = store.exportRRReferencePackageForUI()
        }
        .buttonStyle(.glassProminent)
        .tint(.gray)

        Button("Import RR") {
            showRRImporter = true
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)

        if let rrShareURL {
            ShareLink(item: rrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
        .tint(.green)
        }
    }
}

private struct AtriaCollectionHRReferenceCardHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    @Binding var showHRImporter: Bool
    @Binding var hrShareURL: URL?
    let hrImportStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "HR reference", subtitle: "Validate workout intensity against an external HR source")

                Spacer(minLength: 0)

                AtriaStatusChip(text: snapshotStore.state.referenceText,
                                systemImage: "figure.run",
                                tint: .orange)
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
                Text(hrImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits {
                HStack(spacing: 10) {
                    hrActionButtons
                }

                VStack(spacing: 10) {
                    hrActionButtons
                }
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var hrActionButtons: some View {
        Button("Export HR") {
            hrShareURL = store.exportHRReferencePackageForUI()
        }
        .buttonStyle(.glassProminent)
        .tint(.gray)

        Button("Import HR") {
            showHRImporter = true
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)

        if let hrShareURL {
            ShareLink(item: hrShareURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.glassProminent)
        .tint(.green)
        }
    }
}

private struct AtriaCollectionControlsCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: WhoopBLEManager
    @Binding var hapticSettings: AtriaHapticAlertSettings
    let developerModeEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Collection controls", subtitle: "Tune how Atria collects while you wear the strap")

                Spacer(minLength: 0)

                AtriaStatusChip(text: collectionLiveStore.state.modeLabel,
                                systemImage: "slider.horizontal.3",
                                tint: .blue)
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
                    subtitle: "Bias collection toward longer background runs using your current rest and max HR.",
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
            .buttonStyle(.glassProminent)
        .tint(.gray)
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
                AtriaPanelSectionHeader(title: "Collection status", subtitle: "Show useful state fast")

                Spacer(minLength: 0)

                AtriaStatusChip(text: collectionLiveStore.state.modeLabel,
                                systemImage: "record.circle",
                                tint: .blue)
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    statusTiles
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statusTiles
                }
            }
        }
        .padding(18)
        .atriaCard()
    }

    @ViewBuilder
    private var statusTiles: some View {
        AtriaInlineQuickStat(label: "Logging", value: snapshotStore.state.loggingText)
        AtriaInlineQuickStat(label: "Backup", value: homeStatsStore.state.backupValue)
        AtriaInlineQuickStat(label: "Battery", value: coreLiveStore.state.batteryText)
        AtriaInlineQuickStat(label: "Profile", value: collectionLiveStore.state.modeLabel)
    }
}

private struct AtriaCollectionProfilePicker: View, Equatable {
    let selected: WhoopBLEManager.CollectionProfile
    let onSelect: (WhoopBLEManager.CollectionProfile) -> Void

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
                    Text("Collection profile")
                        .font(.subheadline.weight(.semibold))
                    Text(selected.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                ForEach(WhoopBLEManager.CollectionProfile.allCases) { profile in
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
                    .buttonStyle(AtriaSegmentButtonStyle(selected: selected == profile))
                    .accessibilityLabel("Collection profile \(profile.label)")
                }
            }
            .padding(6)
            .atriaRaisedCard(cornerRadius: 18, emphasis: .soft)
        }
        .padding(14)
        .atriaRaisedCard(emphasis: .soft)
    }
}

private struct AtriaPulseCard: View, Equatable {
    let live: AtriaHomeModel.PulseLiveState
    let sparklineStore: AtriaHomeModel.PulseSparklineStore
    let restingHeartRateText: String

    static func == (lhs: AtriaPulseCard, rhs: AtriaPulseCard) -> Bool {
        lhs.live == rhs.live
            && lhs.restingHeartRateText == rhs.restingHeartRateText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Heart rate", subtitle: "Live BPM from the current session")

                Spacer(minLength: 0)

                AtriaStatusChip(text: live.contactText,
                                systemImage: live.hasContact ? "heart.fill" : "heart.slash",
                                tint: live.hasContact ? .red : .orange)
            }

            HStack(alignment: .firstTextBaseline) {
                Text(live.heartRateText)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            AtriaPulseSparklineHost(sparklineStore: sparklineStore)

            ViewThatFits {
                HStack(spacing: 12) {
                    pulseStatTiles
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    pulseStatTiles
                }
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var pulseStatTiles: some View {
        AtriaInlineQuickStat(label: "Average", value: live.averageHeartRateText)
        AtriaInlineQuickStat(label: "Peak", value: live.peakHeartRateText)
        AtriaInlineQuickStat(label: "Resting", value: restingHeartRateText)
    }
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
                AtriaPanelSectionHeader(title: "HRV", subtitle: "Live RR window and confidence")

                Spacer(minLength: 0)

                AtriaStatusChip(text: live.rrContinuityText,
                                systemImage: "waveform.path.ecg",
                                tint: continuityTint)
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    hrvStatTiles
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    hrvStatTiles
                }
            }

            Text(hero.hrvNarrative)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(hero.stressNarrative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
    }

    @ViewBuilder
    private var hrvStatTiles: some View {
        AtriaInlineQuickStat(label: "RMSSD", value: hero.hrvValue)
        AtriaInlineQuickStat(label: "Window", value: hero.rrPackageText)
        AtriaInlineQuickStat(label: "Confidence", value: hero.hrvDetail)
        AtriaInlineQuickStat(label: "Stress", value: hero.stressValue, detail: hero.stressDetail)
    }
}

private struct AtriaRecoveryStrainCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "Recovery and strain for today")

            GlassEffectContainer(spacing: 12) {
                metricContent
            }

            Text(hero.headline)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaRaisedCard(emphasis: .soft)
    }

    @ViewBuilder
    private var metricContent: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                recoveryStrainTiles
            }

            VStack(spacing: 12) {
                recoveryStrainTiles
            }
        }
    }

    @ViewBuilder
    private var recoveryStrainTiles: some View {
        AtriaRecoveryMeter(estimate: hero.recoveryEstimate)
        AtriaStrainMeter(strain: hero.strain,
                         detail: hero.strainNarrative,
                         confidence: hero.strainConfidence)
        AtriaTrainingLoadTile(ratio: hero.loadRatioText,
                              target: hero.loadTargetText,
                              confidence: hero.loadConfidence,
                              narrative: hero.loadNarrative)
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
        VStack(alignment: .leading, spacing: 10) {
            Label("Load ratio", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.blue)

            Text(ratio)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            AtriaInlineQuickStat(label: "Target", value: target)

            Text(confidence)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(confidenceTint)

            Text(narrative)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetCard(cornerRadius: 20, tint: .blue)
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
                    .buttonStyle(AtriaSegmentButtonStyle(selected: profile.maxHRSource == source))
                }
            }
            .padding(8)
            .atriaRaisedCard(cornerRadius: 22, emphasis: .soft)

            ViewThatFits {
                HStack(spacing: 12) {
                    profileStepperTiles
                }

                VStack(spacing: 12) {
                    profileStepperTiles
                }
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    AtriaInlineQuickStat(label: "Active HRmax", value: "\(profile.maxHR)")
                    AtriaInlineQuickStat(label: "Observed peak", value: observedPeakHeartRateText)
                    AtriaInlineQuickStat(label: "Source", value: profile.maxHRSource.label)
                    AtriaInlineQuickStat(label: "VO2max", value: vo2MaxEstimate.valueText, detail: vo2MaxEstimate.confidence)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AtriaInlineQuickStat(label: "Active HRmax", value: "\(profile.maxHR)")
                    AtriaInlineQuickStat(label: "Observed peak", value: observedPeakHeartRateText)
                    AtriaInlineQuickStat(label: "Source", value: profile.maxHRSource.label)
                    AtriaInlineQuickStat(label: "VO2max", value: vo2MaxEstimate.valueText, detail: vo2MaxEstimate.confidence)
                }
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
        .atriaRaisedCard(emphasis: .soft)
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
}

private struct AtriaCollectionReferenceSummaryCard: View, Equatable {
    let leadingTitle: String
    let leadingValue: String
    let leadingDetail: String
    let trailingTitle: String
    let trailingValue: String
    let trailingDetail: String

    var body: some View {
        ViewThatFits {
            HStack(spacing: 12) {
                AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                    value: leadingValue,
                                                    detail: leadingDetail)
                AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                    value: trailingValue,
                                                    detail: trailingDetail)
            }

            VStack(spacing: 12) {
                AtriaCollectionReferenceSummaryTile(title: leadingTitle,
                                                    value: leadingValue,
                                                    detail: leadingDetail)
                AtriaCollectionReferenceSummaryTile(title: trailingTitle,
                                                    value: trailingValue,
                                                    detail: trailingDetail)
            }
        }
    }
}

private struct AtriaCollectionReferenceSummaryTile: View, Equatable {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
        .padding(14)
        .atriaInsetCard(cornerRadius: 18, tint: .white)
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(tint)
        }
        .padding(14)
        .atriaInsetCard(cornerRadius: 20, tint: tint)
    }
}
