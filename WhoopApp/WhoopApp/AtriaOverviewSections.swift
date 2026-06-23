import SwiftUI

struct AtriaOverviewTabContent: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let horizontalSizeClass: UserInterfaceSizeClass?
    let connectionContext: AtriaConnectionGuideContext
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        Group {
            if statusStore.state.status != .connected {
                if hasUnlockedSecondarySections {
                    AtriaDisconnectedOverviewHost(statusStore: statusStore,
                                                 homeStatsStore: homeStatsStore,
                                                 snapshotStore: snapshotStore,
                                                 context: connectionContext,
                                                 onShowConnectionGuide: onShowConnectionGuide,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection)
                }
            } else if !hasUnlockedSecondarySections {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             hasUnlockedSecondarySections: false,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection)
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Trends, backup, and data summaries join after the first live dashboard settles.")
                }
            } else if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        AtriaOverviewLeadingHost(liveStore: liveStore,
                                                 heroStore: heroStore,
                                                 homeStatsStore: homeStatsStore,
                                                 snapshotStore: snapshotStore,
                                                 store: store,
                                                 hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                 aiCoachSettings: aiCoachSettings,
                                                 aiCoachHasAPIKey: aiCoachHasAPIKey,
                                                 onAICoachSettingsChange: onAICoachSettingsChange,
                                                 onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                                 onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                                 onOpenVitals: onOpenVitals,
                                                 onOpenCollection: onOpenCollection)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        AtriaOverviewTrailingHost(liveStore: liveStore,
                                                  homeStatsStore: homeStatsStore,
                                                  snapshotStore: snapshotStore,
                                                  hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                                  onOpenCollection: onOpenCollection)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(liveStore: liveStore,
                                             heroStore: heroStore,
                                             homeStatsStore: homeStatsStore,
                                             snapshotStore: snapshotStore,
                                             store: store,
                                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                             aiCoachSettings: aiCoachSettings,
                                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                                             onAICoachSettingsChange: onAICoachSettingsChange,
                                             onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection)
                    AtriaOverviewTrailingHost(liveStore: liveStore,
                                              homeStatsStore: homeStatsStore,
                                              snapshotStore: snapshotStore,
                                              hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                              onOpenCollection: onOpenCollection)
                }
            }
        }
    }
}

private struct AtriaDisconnectedOverviewHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaDisconnectedOverviewPanel(status: statusStore.state.status,
                                       stats: homeStatsStore.state,
                                       snapshot: snapshotStore.state,
                                       context: context,
                                       onShowConnectionGuide: onShowConnectionGuide,
                                       onOpenVitals: onOpenVitals,
                                       onOpenCollection: onOpenCollection)
            .equatable()
    }
}

private struct AtriaDisconnectedOverviewPanel: View, Equatable {
    let status: WhoopBLEManager.Status
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaDisconnectedOverviewPanel, rhs: AtriaDisconnectedOverviewPanel) -> Bool {
        lhs.status == rhs.status
            && lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
            && lhs.context == rhs.context
    }

    private var tint: Color {
        switch status {
        case .connecting, .scanning:
            return .orange
        case .poweredOff:
            return .red
        case .disconnected:
            return .blue
        case .connected:
            return .green
        }
    }

    private var systemImage: String {
        switch status {
        case .connecting:
            return "bolt.horizontal.fill"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .poweredOff:
            return "bolt.slash.fill"
        case .disconnected:
            return "bolt.horizontal.circle"
        case .connected:
            return "bolt.heart.fill"
        }
    }

    private var title: String {
        switch status {
        case .connecting:
            return "Connecting to your strap"
        case .scanning:
            return "Looking for your strap"
        case .poweredOff:
            return "Bluetooth is off"
        case .disconnected:
            return "Waiting for your strap"
        case .connected:
            return "Live data is flowing"
        }
    }

    private var detail: String {
        switch status {
        case .connecting:
            return "Almost there — Atria is linking up with your strap. The first connection takes a moment."
        case .scanning:
            return "Atria is searching for your strap in the background. The rest of your dashboard stays ready while it looks."
        case .poweredOff:
            return "Turn Bluetooth back on and Atria will start looking for your strap again automatically."
        case .disconnected:
            return "Atria is waiting for your strap. Keep it nearby, and make sure it isn't still connected in the WHOOP app."
        case .connected:
            return "Saved insights prepare after the live connection settles."
        }
    }

    private var setupDetail: String {
        if context.officialWhoopCoexistenceRisk == .suspected {
            return "Atria cannot kill another iOS app. Remove or disable the official WHOOP app/widget, then reconnect here."
        }
        switch status {
        case .connecting:
            return "Keep your phone unlocked and nearby while Atria finishes connecting."
        case .scanning:
            return "Atria is already searching automatically. Tap Scan now only if you just freed the strap from WHOOP."
        case .poweredOff:
            return "Turn Bluetooth on first. Atria then starts looking for your strap on its own."
        case .disconnected:
            return "If the strap is still connected in the WHOOP app, disconnect it there first, then leave Atria open."
        case .connected:
            return "From now on, Atria reconnects to your strap automatically."
        }
    }

    private var setupItems: [String] {
        var items = [
            "If the official WHOOP app is installed, uninstall it or disable its widget/background access before relying on Atria.",
            "Atria cannot terminate WHOOP from inside iOS; it can only detect risky connection behavior and warn clearly.",
            "Keep this phone unlocked and the strap nearby until Atria completes the first setup."
        ]
        if context.officialWhoopCoexistenceRisk == .suspected {
            items[2] = "After removing WHOOP, reopen Atria and let the automatic scan reconnect the strap."
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Overview", subtitle: title)

                Spacer(minLength: 0)

                AtriaStatusChip(text: status.rawValue,
                                systemImage: systemImage,
                                tint: tint)
            }

            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if context.officialWhoopCoexistenceRisk != .cleared {
                AtriaDisconnectedOverviewCoexistenceCard(context: context)
            }

            AtriaOverviewActionStrip(title: "Quick actions",
                                     primaryTitle: "Vitals",
                                     primarySystemImage: "heart.text.square",
                                     primaryAction: onOpenVitals,
                                     secondaryTitle: "Data",
                                     secondarySystemImage: "waveform.badge.magnifyingglass",
                                     secondaryAction: onOpenCollection)

            ViewThatFits {
                HStack(spacing: 12) {
                    AtriaInlineQuickStat(label: "Personal baseline", value: snapshot.referenceText)
                    AtriaInlineQuickStat(label: "Saved days", value: "\(stats.baselineSamples)/7")
                    AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AtriaInlineQuickStat(label: "Personal baseline", value: snapshot.referenceText)
                    AtriaInlineQuickStat(label: "Saved days", value: "\(stats.baselineSamples)/7")
                    AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                AtriaDisconnectedOverviewAutomaticCard(status: status,
                                                       tint: tint,
                                                       setupDetail: setupDetail,
                                                       context: context,
                                                       onShowConnectionGuide: onShowConnectionGuide)

                AtriaDisconnectedOverviewChecklistCard(title: context.isFirstHandoff ? "Do once before Atria takes over" : "Only if WHOOP grabs the strap again",
                                                       items: setupItems,
                                                       tint: .orange)

                AtriaDisconnectedOverviewSavedStateCard(stats: stats,
                                                        snapshot: snapshot,
                                                        tint: tint)
            }
        }
        .padding(18)
        .atriaCard(cornerRadius: 30, emphasis: .soft)
    }
}

private struct AtriaOverviewLeadingHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewLeadingSection(liveStore: liveStore,
                                   heroStore: heroStore,
                                   homeStatsStore: homeStatsStore,
                                   snapshotStore: snapshotStore,
                                   store: store,
                                   hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                   aiCoachSettings: aiCoachSettings,
                                   aiCoachHasAPIKey: aiCoachHasAPIKey,
                                   onAICoachSettingsChange: onAICoachSettingsChange,
                                   onSaveAICoachAPIKey: onSaveAICoachAPIKey,
                                   onDeleteAICoachAPIKey: onDeleteAICoachAPIKey,
                                   onOpenVitals: onOpenVitals,
                                   onOpenCollection: onOpenCollection)
    }
}

private struct AtriaOverviewTrailingHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewTrailingSection(liveStore: liveStore,
                                     homeStatsStore: homeStatsStore,
                                     snapshotStore: snapshotStore,
                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                     onOpenCollection: onOpenCollection)
    }
}

struct AtriaOverviewLeadingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let store: SessionStore
    let hasUnlockedSecondarySections: Bool
    let aiCoachSettings: AtriaAICoachSettings
    let aiCoachHasAPIKey: Bool
    let onAICoachSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAICoachAPIKey: (String) -> Void
    let onDeleteAICoachAPIKey: () -> Void
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            AtriaOverviewReadinessSectionHost(heroStore: heroStore,
                                             snapshotStore: snapshotStore)

            AtriaOverviewLaunchChecklistHost(liveStore: liveStore,
                                             homeStatsStore: homeStatsStore,
                                             snapshotStore: snapshotStore,
                                             onOpenVitals: onOpenVitals,
                                             onOpenCollection: onOpenCollection)

            AtriaOverviewGuidanceSectionHost(heroStore: heroStore,
                                             settings: aiCoachSettings,
                                             hasAPIKey: aiCoachHasAPIKey,
                                             onSettingsChange: onAICoachSettingsChange,
                                             onSaveAPIKey: onSaveAICoachAPIKey,
                                             onDeleteAPIKey: onDeleteAICoachAPIKey)

            if hasUnlockedSecondarySections {
                AtriaOverviewBehaviorJournalSection(store: store)

                if snapshotStore.diagnosticsReady {
                    AtriaOverviewTrendSectionHost(snapshotStore: snapshotStore)
                } else {
                    AtriaLoadingPanel(title: "Preparing trends",
                                      subtitle: "Saved trends stay off the launch path and load after the first screen is stable.")
                }
            }
        }
    }
}

struct AtriaOverviewReadinessSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                     snapshot: snapshotStore.state)
            .equatable()
    }
}

struct AtriaOverviewReadinessSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Readiness", subtitle: "What is ready right now")

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AtriaQuickTile(title: "Recovery",
                               value: hero.recoveryValue,
                               detail: hero.recoveryDetail,
                               system: "gauge.with.dots.needle.bottom.50percent",
                               tint: .green)
                AtriaQuickTile(title: "Strain",
                               value: hero.strainValue,
                               detail: hero.strainDetail,
                               system: "flame.fill",
                               tint: .orange)
                AtriaQuickTile(title: "HRV",
                               value: hero.hrvValue,
                               detail: hero.hrvDetail,
                               system: "waveform.path.ecg",
                               tint: .pink)
                AtriaQuickTile(title: "Sleep",
                               value: snapshot.sleepValue,
                               detail: snapshot.sleepDetail,
                               system: "bed.double.fill",
                               tint: .cyan)
            }
        }
        .padding(.horizontal, 2)
    }
}

struct AtriaOverviewLaunchChecklistHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewLaunchChecklist(live: liveStore.state,
                                     stats: homeStatsStore.state,
                                     snapshot: snapshotStore.state,
                                     onOpenVitals: onOpenVitals,
                                     onOpenCollection: onOpenCollection)
            .equatable()
    }
}

struct AtriaOverviewLaunchChecklist: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let onOpenVitals: () -> Void
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaOverviewLaunchChecklist, rhs: AtriaOverviewLaunchChecklist) -> Bool {
        lhs.live == rhs.live
            && lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
    }

    private var completeCount: Int {
        checklistItems.filter(\.isComplete).count
    }

    private var checklistItems: [AtriaLaunchChecklistItem] {
        [
            AtriaLaunchChecklistItem(id: "connection",
                                     title: "Strap connection",
                                     value: live.status == .connected ? "Connected" : live.status.rawValue,
                                     detail: live.status == .connected ? live.deviceName : "Open Vitals when the strap is nearby.",
                                     systemImage: "bolt.heart.fill",
                                     tint: live.status == .connected ? .green : .orange,
                                     isComplete: live.status == .connected,
                                     actionTitle: live.status == .connected ? nil : "Vitals",
                                     action: live.status == .connected ? nil : onOpenVitals),
            AtriaLaunchChecklistItem(id: "baseline",
                                     title: "HRV baseline",
                                     value: "\(stats.baselineSamples)/7",
                                     detail: stats.baselineSamples >= 7 ? "Personal baseline is ready." : "Wear overnight to improve recovery confidence.",
                                     systemImage: "waveform.path.ecg",
                                     tint: stats.baselineSamples >= 7 ? .green : .pink,
                                     isComplete: stats.baselineSamples >= 7,
                                     actionTitle: nil,
                                     action: nil),
            AtriaLaunchChecklistItem(id: "capture",
                                     title: "Live recording",
                                     value: snapshot.loggingText,
                                     detail: snapshot.loggingText.localizedCaseInsensitiveContains("samples") ? "Atria is saving your readings." : stats.nextAction,
                                     systemImage: "waveform.badge.plus",
                                     tint: snapshot.loggingText.localizedCaseInsensitiveContains("samples") ? .green : .orange,
                                     isComplete: snapshot.loggingText.localizedCaseInsensitiveContains("samples"),
                                     actionTitle: "Data",
                                     action: onOpenCollection)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Getting set up",
                                        subtitle: "\(completeCount) of \(checklistItems.count) ready")

                Spacer(minLength: 0)

                AtriaStatusChip(text: completeCount == checklistItems.count ? "ready" : "learning",
                                systemImage: completeCount == checklistItems.count ? "checkmark.circle.fill" : "hourglass",
                                tint: completeCount == checklistItems.count ? .green : .orange)
            }

            VStack(spacing: 8) {
                ForEach(checklistItems) { item in
                    AtriaLaunchChecklistRow(item: item)
                }
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaLaunchChecklistItem: Identifiable {
    let id: String
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tint: Color
    let isComplete: Bool
    let actionTitle: String?
    let action: (() -> Void)?
}

private struct AtriaLaunchChecklistRow: View {
    let item: AtriaLaunchChecklistItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.isComplete ? "checkmark.circle.fill" : item.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(item.tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: item.tint))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                    Text(item.value)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            if let actionTitle = item.actionTitle, let action = item.action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                .tint(item.tint)
            }
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 18, tint: item.tint)
    }
}

struct AtriaOverviewGuidanceSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    var body: some View {
        AtriaOverviewGuidanceSection(hero: heroStore.state,
                                     settings: settings,
                                     hasAPIKey: hasAPIKey,
                                     onSettingsChange: onSettingsChange,
                                     onSaveAPIKey: onSaveAPIKey,
                                     onDeleteAPIKey: onDeleteAPIKey)
            .equatable()
    }
}

struct AtriaOverviewGuidanceSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot
    let settings: AtriaAICoachSettings
    let hasAPIKey: Bool
    let onSettingsChange: (AtriaAICoachSettings) -> Void
    let onSaveAPIKey: (String) -> Void
    let onDeleteAPIKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Guidance", subtitle: "Daily target from today's signal")
            AtriaGuidanceCard(guidance: hero.guidance, strain: hero.strain)
            AtriaAICoachCard(context: coachContext,
                             settings: settings,
                             hasAPIKey: hasAPIKey,
                             onSettingsChange: onSettingsChange,
                             onSaveAPIKey: onSaveAPIKey,
                             onDeleteAPIKey: onDeleteAPIKey)
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    static func == (lhs: AtriaOverviewGuidanceSection, rhs: AtriaOverviewGuidanceSection) -> Bool {
        lhs.hero == rhs.hero
            && lhs.settings == rhs.settings
            && lhs.hasAPIKey == rhs.hasAPIKey
    }

    private var coachContext: AtriaCoachContext {
        AtriaCoachContext(guidance: hero.guidance,
                          strain: hero.strain,
                          recoveryText: hero.recoveryEstimate.percent.map { "\($0)%" } ?? hero.recoveryEstimate.confidence.rawValue,
                          hrvText: hero.hrvValue,
                          stressText: hero.stressValue,
                          baselineSamples: hero.baselineSamples,
                          sessionsCount: hero.sessionsCount)
    }
}

struct AtriaOverviewTrendSectionHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewTrendSection(snapshot: snapshotStore.state)
            .equatable()
    }
}

struct AtriaOverviewTrendSection: View, Equatable {
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Trend", subtitle: "Local 90-day coverage")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.trendCoverageText)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(snapshot.trendDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                AtriaStatusChip(text: snapshot.trendConfidence,
                                systemImage: "chart.line.uptrend.xyaxis",
                                tint: snapshot.trendConfidence == "high" ? .green : .orange)
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

struct AtriaOverviewBehaviorJournalSection: View {
    @ObservedObject var store: SessionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var todayEntry: BehaviorJournalEntry {
        store.behaviorJournalEntry()
    }

    private var summaries: [BehaviorCorrelationSummary] {
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? 60
        return store.behaviorCorrelationSummaries(rest: rest, maxHR: store.profile.maxHR)
            .filter { $0.days > 0 }
            .sorted { lhs, rhs in
                if lhs.days != rhs.days { return lhs.days > rhs.days }
                return lhs.tag.rawValue < rhs.tag.rawValue
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Journal", subtitle: "Tag today and learn local patterns")

                Spacer(minLength: 0)

                AtriaStatusChip(text: todayEntry.tags.isEmpty ? "empty" : "\(todayEntry.tags.count) tags",
                                systemImage: "tag.fill",
                                tint: todayEntry.tags.isEmpty ? .gray : .purple)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(BehaviorJournalEntry.Tag.allCases) { tag in
                    Button {
                        if reduceMotion {
                            store.toggleBehaviorTag(tag)
                        } else {
                            withAnimation(.snappy(duration: 0.2)) {
                                store.toggleBehaviorTag(tag)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: todayEntry.tags.contains(tag) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(todayEntry.tags.contains(tag) ? .purple : .secondary)
                            Text(tag.label)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(AtriaSegmentButtonStyle(selected: todayEntry.tags.contains(tag)))
                }
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    correlationTiles
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    correlationTiles
                }
            }

            Text("Correlations are computed only on this device and stay in learning mode until a tag has at least three matching days.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    @ViewBuilder
    private var correlationTiles: some View {
        let visible = Array(summaries.prefix(2))
        if visible.isEmpty {
            AtriaInlineQuickStat(label: "Tagged days", value: "\(store.behaviorJournalEntries.count)")
            AtriaInlineQuickStat(label: "Pattern", value: "Learning")
        } else {
            ForEach(visible, id: \.tag) { summary in
                AtriaInlineQuickStat(label: summary.tag.label,
                                     value: summary.recoveryText,
                                     detail: summary.detail)
            }
        }
    }
}

struct AtriaOverviewTrailingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool
    let onOpenCollection: () -> Void

    var body: some View {
        Group {
            if hasUnlockedSecondarySections && snapshotStore.diagnosticsReady {
                VStack(spacing: 16) {
                    AtriaOverviewLiveStrapSectionHost(liveStore: liveStore,
                                                      homeStatsStore: homeStatsStore)

                    AtriaOverviewCollectionSectionHost(homeStatsStore: homeStatsStore,
                                                       snapshotStore: snapshotStore,
                                                       onOpenCollection: onOpenCollection)

                    AtriaOverviewBackupSectionHost(homeStatsStore: homeStatsStore,
                                                   snapshotStore: snapshotStore)
                }
            } else {
                AtriaLoadingPanel(title: "Preparing saved insights",
                                  subtitle: "Trends, backup state, and saved data are settling in the background.")
            }
        }
    }
}

struct AtriaOverviewLiveStrapSectionHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore

    var body: some View {
        AtriaOverviewLiveStrapSection(live: liveStore.state,
                                     stats: homeStatsStore.state)
            .equatable()
    }
}

struct AtriaOverviewLiveStrapSection: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let stats: AtriaHomeModel.HomeStatsState

    private var statusTint: Color {
        switch live.status {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                AtriaPanelSectionHeader(title: "Live strap", subtitle: "Current connection and battery")

                Spacer(minLength: 0)

                AtriaStatusChip(text: live.status.rawValue,
                                systemImage: "bolt.heart.fill",
                                tint: statusTint)
            }

            Text(live.deviceName)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits {
                HStack(spacing: 12) {
                    AtriaInlineQuickStat(label: "Battery", value: live.batteryText)
                    AtriaInlineQuickStat(label: "Baseline", value: "\(stats.baselineSamples)/7")
                    AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    AtriaInlineQuickStat(label: "Battery", value: live.batteryText)
                    AtriaInlineQuickStat(label: "Baseline", value: "\(stats.baselineSamples)/7")
                    AtriaInlineQuickStat(label: "Sessions", value: "\(stats.sessionsCount)")
                }
            }
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

struct AtriaOverviewCollectionSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onOpenCollection: () -> Void

    var body: some View {
        AtriaOverviewCollectionSection(stats: homeStatsStore.state,
                                      snapshot: snapshotStore.state,
                                      onOpenCollection: onOpenCollection)
            .equatable()
    }
}

struct AtriaOverviewCollectionSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let onOpenCollection: () -> Void

    static func == (lhs: AtriaOverviewCollectionSection, rhs: AtriaOverviewCollectionSection) -> Bool {
        lhs.stats == rhs.stats
            && lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "internaldrive.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.blue)
                .frame(width: 38, height: 38)
                .background(AtriaIconTileBackground(cornerRadius: 12, tint: .blue))

            VStack(alignment: .leading, spacing: 4) {
                Text("Local backup")
                    .font(.headline.weight(.semibold))
                Text(backupDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            AtriaInlineQuickStat(label: "HRV window", value: stats.rrPackageText)
                .frame(maxWidth: 118)

            Button(action: onOpenCollection) {
                Label("Data", systemImage: "arrow.right.circle.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glassProminent)
            .tint(.blue)
            .accessibilityLabel("Open Data")
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    private var backupDetail: String {
        if snapshot.loggingText.localizedCaseInsensitiveContains("samples") {
            return "Saving readings locally. Open Data when you want exports or saved sessions."
        }
        if stats.backupValue.localizedCaseInsensitiveContains("ready") {
            return "Saved sessions are on device. Open Data when you want exports."
        }
        return "Atria is preparing local backup while your baseline settles."
    }
}

private struct AtriaOverviewActionStrip: View {
    let title: String
    let primaryTitle: String
    let primarySystemImage: String
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondarySystemImage: String
    let secondaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ViewThatFits {
                HStack(spacing: 8) {
                    actionButtons
                }

                VStack(spacing: 8) {
                    actionButtons
                }
            }
        }
        .padding(12)
        .atriaInsetCard(cornerRadius: 18, tint: .white)
    }

    @ViewBuilder
    private var actionButtons: some View {
        Button(action: primaryAction) {
            Label(primaryTitle, systemImage: primarySystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.blue)

        Button(action: secondaryAction) {
            Label(secondaryTitle, systemImage: secondarySystemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.gray)
    }
}

struct AtriaOverviewBackupSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewBackupSection(stats: homeStatsStore.state,
                                  snapshot: snapshotStore.state)
            .equatable()
    }
}

struct AtriaOverviewBackupSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Backup", subtitle: "On-device safety net")

            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "State", value: stats.backupValue)
                AtriaInlineQuickStat(label: "Confirmed",
                                    value: "\(snapshot.confirmedWorkouts + snapshot.confirmedSleeps)")
            }

            Text(stats.backupDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("\(snapshot.confirmedWorkouts) workouts and \(snapshot.confirmedSleeps) sleeps are already confirmed on device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewAutomaticCard: View, Equatable {
    let status: WhoopBLEManager.Status
    let tint: Color
    let setupDetail: String
    let context: AtriaConnectionGuideContext
    let onShowConnectionGuide: () -> Void

    static func == (lhs: AtriaDisconnectedOverviewAutomaticCard, rhs: AtriaDisconnectedOverviewAutomaticCard) -> Bool {
        lhs.status == rhs.status
            && lhs.setupDetail == rhs.setupDetail
            && lhs.context == rhs.context
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

                VStack(alignment: .leading, spacing: 2) {
                    Text(context.isFirstHandoff ? "Automatic setup" : "Automatic reconnect")
                        .font(.subheadline.weight(.semibold))
                    Text(context.progressLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Text(setupDetail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                AtriaInlineQuickStat(label: "Flow", value: context.flowLabel)
                AtriaInlineQuickStat(label: "State", value: status.rawValue)
                AtriaInlineQuickStat(label: "Attempts", value: "\(max(context.attempts, 1))")
            }

            Button(context.isFirstHandoff ? "Review setup steps" : "Review reconnect steps", action: onShowConnectionGuide)
                .buttonStyle(.glassProminent)
        .tint(tint)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewCoexistenceCard: View, Equatable {
    let context: AtriaConnectionGuideContext

    private var tint: Color {
        context.officialWhoopCoexistenceRisk == .suspected ? .red : .orange
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.headline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

            VStack(alignment: .leading, spacing: 4) {
                Text(context.coexistenceTitle)
                    .font(.subheadline.weight(.semibold))
                Text(context.coexistenceDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaCard(cornerRadius: 22, emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewChecklistCard: View, Equatable {
    let title: String
    let items: [String]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaDisconnectedOverviewSavedStateCard: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(AtriaIconTileBackground(cornerRadius: 11, tint: tint))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Saved data stays ready")
                        .font(.subheadline.weight(.semibold))
                    Text("Saved metrics and backup remain available while the strap reconnects.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ViewThatFits {
                HStack(spacing: 12) {
                    savedStateTiles
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    savedStateTiles
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .atriaCard(cornerRadius: 24, emphasis: .soft)
    }

    @ViewBuilder
    private var savedStateTiles: some View {
        AtriaInlineQuickStat(label: "Baseline", value: snapshot.referenceText)
        AtriaInlineQuickStat(label: "Backup", value: stats.backupValue)
        AtriaInlineQuickStat(label: "Saved HRV", value: "\(stats.baselineSamples)/7")
        AtriaInlineQuickStat(label: "Next", value: stats.nextAction)
    }
}
