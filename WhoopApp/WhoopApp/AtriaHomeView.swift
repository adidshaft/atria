import SwiftUI
import Combine
import UniformTypeIdentifiers

struct AtriaHomeContainer: View, Equatable {
    let ble: WhoopBLEManager
    let store: SessionStore

    static func == (lhs: AtriaHomeContainer, rhs: AtriaHomeContainer) -> Bool {
        ObjectIdentifier(lhs.ble) == ObjectIdentifier(rhs.ble)
            && ObjectIdentifier(lhs.store) == ObjectIdentifier(rhs.store)
    }

    var body: some View {
        AtriaHomeView(ble: ble, store: store)
    }
}

struct AtriaHomeView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case overview
        case vitals
        case collection

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .vitals: return "Vitals"
            case .collection: return "Collection"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "sparkles"
            case .vitals: return "heart.text.square"
            case .collection: return "waveform.badge.magnifyingglass"
            }
        }
    }

    let ble: WhoopBLEManager
    let store: SessionStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: AtriaHomeModel
    @State private var selectedTab: Tab = .overview
    @State private var showRRImporter = false
    @State private var showHRImporter = false
    @State private var rrShareURL: URL?
    @State private var hrShareURL: URL?
    @State private var captureShareURL: URL?
    @State private var rrImportStatus = ""
    @State private var hrImportStatus = ""
    @State private var hasUnlockedPrimaryContent = false
    @State private var hasUnlockedSecondarySections = false
    @State private var showConnectionGuide = false
    @State private var connectionGuideSnoozedUntil: Date?
    @State private var connectionGuidePresentationToken = UUID()
    @State private var connectionGuidePresentationTask: Task<Void, Never>?
    @State private var lastAutomaticConnectionSetupAt: Date?
    @State private var secondaryUnlockTask: Task<Void, Never>?
    @State private var overviewDiagnosticsKickoffTask: Task<Void, Never>?
    @State private var automaticConnectionSetupTask: Task<Void, Never>?
    @State private var homeAppearedAt: Date?
    @State private var hasLoggedPrimaryReady = false
    @State private var hasLoggedSecondaryReady = false
    @State private var hasLoggedDiagnosticsReady = false

    init(ble: WhoopBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        _model = State(initialValue: AtriaHomeModel(ble: ble, store: store))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaBackdropLayer(isDark: isDark)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 20) {
                        header
                        hero
                        tabPicker
                        tabContent
                    }
                    .frame(maxWidth: contentWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 18)
                    .padding(.bottom, 40)
                        .frame(maxWidth: .infinity)
                }

                AtriaHomeObservers(statusStore: model.statusStore,
                                   snapshotStore: model.snapshotStore) { status in
                    handleStatusChange(status)
                } onDiagnosticsReady: {
                    overviewDiagnosticsKickoffTask?.cancel()
                    overviewDiagnosticsKickoffTask = nil
                    logDiagnosticsReadyIfNeeded()
                }
            }
            .navigationBarHidden(true)
            .fileImporter(isPresented: $showRRImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false,
                          onCompletion: handleRRImport)
            .fileImporter(isPresented: $showHRImporter,
                          allowedContentTypes: [.commaSeparatedText, .plainText, .data],
                          allowsMultipleSelection: false,
                          onCompletion: handleHRImport)
            .sheet(isPresented: $showConnectionGuide) {
                AtriaConnectionGuideSheetHost(statusStore: model.statusStore,
                                              context: connectionGuideContext) {
                    connectionGuideSnoozedUntil = Date().addingTimeInterval(90)
                    showConnectionGuide = false
                    if model.statusStore.state.status != .connected {
                        ble.startScan(reason: "connection_guide_continue")
                    }
                } retry: {
                    connectionGuideSnoozedUntil = nil
                    ble.startScan(reason: "connection_guide_retry")
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                guard !hasUnlockedPrimaryContent else { return }
                if homeAppearedAt == nil {
                    homeAppearedAt = Date()
                }
                ble.setForegroundHighFrequencyDisplayMode(selectedTab == .vitals)
                model.setPulseDetailMode(active: selectedTab == .vitals)
                scheduleAutomaticConnectionSetupIfNeeded(reason: "home_appear",
                                                         delayNanoseconds: 60_000_000)
                hasUnlockedPrimaryContent = true
                logPrimaryContentReadyIfNeeded()
                secondaryUnlockTask?.cancel()
                secondaryUnlockTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: secondaryUnlockDelayNanoseconds(for: model.coreLiveStore.state.status))
                    guard !Task.isCancelled else { return }
                    hasUnlockedSecondarySections = true
                }
                scheduleOverviewDiagnosticsKickoff(reason: "home_overview_idle",
                                                   delayNanoseconds: 6_800_000_000)
                presentConnectionGuideIfNeeded()
            }
            .onChange(of: selectedTab) { _, tab in
                ble.setForegroundHighFrequencyDisplayMode(tab == .vitals)
                model.setPulseDetailMode(active: tab == .vitals)
                if tab != .overview {
                    overviewDiagnosticsKickoffTask?.cancel()
                    overviewDiagnosticsKickoffTask = nil
                    hasUnlockedPrimaryContent = true
                    hasUnlockedSecondarySections = true
                    if tab == .collection {
                        model.loadDeferredDiagnosticsIfNeeded(reason: "tab_\(tab.rawValue)")
                    }
                } else if !model.snapshotStore.diagnosticsReady {
                    scheduleOverviewDiagnosticsKickoff(reason: "overview_return_idle",
                                                       delayNanoseconds: 6_800_000_000)
                }
            }
            .onChange(of: hasUnlockedSecondarySections) { _, unlocked in
                guard unlocked else { return }
                logSecondaryContentReadyIfNeeded()
            }
            .onDisappear {
                connectionGuidePresentationTask?.cancel()
                connectionGuidePresentationTask = nil
                secondaryUnlockTask?.cancel()
                secondaryUnlockTask = nil
                overviewDiagnosticsKickoffTask?.cancel()
                overviewDiagnosticsKickoffTask = nil
                automaticConnectionSetupTask?.cancel()
                automaticConnectionSetupTask = nil
            }
        }
    }

    private var contentWidth: CGFloat {
        horizontalSizeClass == .regular ? 1120 : 720
    }

    private func scheduleOverviewDiagnosticsKickoff(reason: String,
                                                    delayNanoseconds: UInt64) {
        guard selectedTab == .overview else { return }
        guard !model.snapshotStore.diagnosticsReady else { return }
        guard model.coreLiveStore.state.status == .connected else { return }
        overviewDiagnosticsKickoffTask?.cancel()
        overviewDiagnosticsKickoffTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard selectedTab == .overview else { return }
            guard model.coreLiveStore.state.status == .connected else { return }
            model.loadDeferredDiagnosticsIfNeeded(reason: reason)
        }
    }

    private func secondaryUnlockDelayNanoseconds(for status: WhoopBLEManager.Status) -> UInt64 {
        switch status {
        case .connected:
            return 300_000_000
        case .connecting, .scanning:
            return 320_000_000
        case .poweredOff, .disconnected:
            return 180_000_000
        }
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var header: some View {
        AtriaHeaderBar(statusStore: model.statusStore,
                       store: store,
                       ble: ble)
    }

    private var hero: some View {
        AtriaHeroPanelHost(statusStore: model.statusStore,
                           liveStore: model.coreLiveStore,
                           heroStore: model.heroStore,
                           pulseStore: model.heroPulseStore)
    }

    private var tabPicker: some View {
        Group {
            if #available(iOS 26, *) {
                GlassEffectContainer(spacing: 8) {
                    tabPickerContent
                }
            } else {
                tabPickerContent
            }
        }
        .padding(8)
        .atriaGlassCapsule(tint: isDark ? .cyan.opacity(0.18) : .white.opacity(0.8))
    }

    private var tabPickerContent: some View {
        HStack(spacing: 8) {
            ForEach(Tab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        selectedTab = tab
                    }
                } label: {
                    Label(tab.title, systemImage: tab.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(AtriaSegmentButtonStyle(selected: selectedTab == tab))
            }
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .overview:
            if hasUnlockedPrimaryContent {
                overviewContent
            } else {
                secondaryLoadingCard(title: "Preparing overview",
                                     subtitle: "Getting the fastest local readout on screen before the deeper cards load.")
            }
        case .vitals:
            vitalsContent
        case .collection:
            collectionContent
        }
    }

    private var overviewContent: some View {
        AtriaOverviewTabContent(statusStore: model.statusStore,
                                liveStore: model.coreLiveStore,
                                heroStore: model.heroStore,
                                homeStatsStore: model.homeStatsStore,
                                snapshotStore: model.snapshotStore,
                                hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                horizontalSizeClass: horizontalSizeClass)
    }

    private var vitalsContent: some View {
        AtriaVitalsTabContent(liveStore: model.coreLiveStore,
                              pulseStore: model.pulseLiveStore,
                              pulseSparklineStore: model.pulseSparklineStore,
                              heroStore: model.heroStore,
                              homeStatsStore: model.homeStatsStore,
                              profileStore: model.profileStore,
                              store: store,
                              ble: ble,
                              horizontalSizeClass: horizontalSizeClass)
    }

    private var collectionContent: some View {
        AtriaCollectionTabContent(coreLiveStore: model.coreLiveStore,
                                  collectionLiveStore: model.collectionLiveStore,
                                  homeStatsStore: model.homeStatsStore,
                                  snapshotStore: model.snapshotStore,
                                  profileStore: model.profileStore,
                                  store: store,
                                  ble: ble,
                                  horizontalSizeClass: horizontalSizeClass,
                                  showRRImporter: $showRRImporter,
                                  showHRImporter: $showHRImporter,
                                  rrShareURL: $rrShareURL,
                                  hrShareURL: $hrShareURL,
                                  captureShareURL: $captureShareURL,
                                  rrImportStatus: $rrImportStatus,
                                  hrImportStatus: $hrImportStatus)
    }

    private func secondaryLoadingCard(title: String, subtitle: String) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .tint(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
    }

    private func handleRRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                rrImportStatus = "No RR file selected"
                return
            }
            let passed = store.importRRReferenceCSVForUI(from: url)
            rrImportStatus = passed ? "RR reference validated" : "RR reference still pending"
            model.forceRefresh()
        case .failure:
            rrImportStatus = "RR import failed"
        }
    }

    private func handleHRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                hrImportStatus = "No HR file selected"
                return
            }
            let passed = store.importHRReferenceCSVForUI(from: url)
            hrImportStatus = passed ? "HR reference validated" : "HR reference still pending"
            model.forceRefresh()
        case .failure:
            hrImportStatus = "HR import failed"
        }
    }

    private func presentConnectionGuideIfNeeded() {
        connectionGuidePresentationTask?.cancel()
        connectionGuidePresentationTask = nil
        let defaults = UserDefaults.standard
        let successes = defaults.integer(forKey: WhoopBLEManager.LinkDefaults.successes)
        let attempts = defaults.integer(forKey: WhoopBLEManager.LinkDefaults.attempts)
        let failures = defaults.integer(forKey: WhoopBLEManager.LinkDefaults.failures)
        guard store.profile.hasCompletedOnboarding,
              successes == 0,
              !isConnectionGuideSnoozed,
              model.coreLiveStore.state.status != .connected else { return }
        let status = model.coreLiveStore.state.status
        let needsImmediateHelp = status == .poweredOff
        let hasAutomaticPassStarted = attempts > 0 || failures > 0
        guard needsImmediateHelp || hasAutomaticPassStarted else { return }
        let token = UUID()
        connectionGuidePresentationToken = token
        let delay: TimeInterval
        switch status {
        case .poweredOff:
            delay = 0.8
        case .disconnected:
            delay = failures > 0 ? 2.0 : 5.5
        case .scanning, .connecting:
            delay = failures > 0 ? 5.0 : 8.5
        case .connected:
            delay = 0
        }
        connectionGuidePresentationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            guard connectionGuidePresentationToken == token,
                  store.profile.hasCompletedOnboarding,
                  UserDefaults.standard.integer(forKey: WhoopBLEManager.LinkDefaults.successes) == 0,
                  !isConnectionGuideSnoozed,
                  model.coreLiveStore.state.status != .connected else { return }
            showConnectionGuide = true
            logHomeTiming(event: "connection_guide_presented", status: model.coreLiveStore.state.status)
        }
    }

    private func scheduleAutomaticConnectionSetupIfNeeded(reason: String,
                                                          delayNanoseconds: UInt64) {
        guard model.coreLiveStore.state.status == .disconnected else { return }
        automaticConnectionSetupTask?.cancel()
        automaticConnectionSetupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            guard model.coreLiveStore.state.status == .disconnected else { return }
            let now = Date()
            let minimumSpacing: TimeInterval =
                UserDefaults.standard.integer(forKey: WhoopBLEManager.LinkDefaults.successes) == 0 ? 2.2 : 4.5
            if let lastAutomaticConnectionSetupAt,
               now.timeIntervalSince(lastAutomaticConnectionSetupAt) < minimumSpacing {
                return
            }
            lastAutomaticConnectionSetupAt = now
            ble.startScan(reason: reason)
        }
    }

    private func handleStatusChange(_ status: WhoopBLEManager.Status) {
        if status == .connected {
            automaticConnectionSetupTask?.cancel()
            automaticConnectionSetupTask = nil
            connectionGuideSnoozedUntil = nil
            showConnectionGuide = false
            connectionGuidePresentationToken = UUID()
            logHomeTiming(event: "connected", status: status)
            if selectedTab == .overview, !model.snapshotStore.diagnosticsReady {
                scheduleOverviewDiagnosticsKickoff(reason: "connected_overview_idle",
                                                   delayNanoseconds: 6_800_000_000)
            }
            return
        }

        if status == .disconnected {
            scheduleAutomaticConnectionSetupIfNeeded(reason: "status_\(status.logToken)",
                                                     delayNanoseconds: 120_000_000)
        } else {
            automaticConnectionSetupTask?.cancel()
            automaticConnectionSetupTask = nil
        }

        if status == .disconnected || status == .poweredOff {
            presentConnectionGuideIfNeeded()
        }
    }

    private var isConnectionGuideSnoozed: Bool {
        guard let connectionGuideSnoozedUntil else { return false }
        return connectionGuideSnoozedUntil > Date()
    }

    private var connectionGuideContext: AtriaConnectionGuideContext {
        let defaults = UserDefaults.standard
        return AtriaConnectionGuideContext(
            hasEverConnected: defaults.integer(forKey: WhoopBLEManager.LinkDefaults.successes) > 0,
            attempts: defaults.integer(forKey: WhoopBLEManager.LinkDefaults.attempts),
            failures: defaults.integer(forKey: WhoopBLEManager.LinkDefaults.failures),
            lastStatus: defaults.string(forKey: WhoopBLEManager.LinkDefaults.lastStatus) ?? "idle",
            lastReason: defaults.string(forKey: WhoopBLEManager.LinkDefaults.lastReason) ?? "waiting"
        )
    }

    private func logPrimaryContentReadyIfNeeded() {
        guard !hasLoggedPrimaryReady else { return }
        hasLoggedPrimaryReady = true
        logHomeTiming(event: "primary_ready", status: model.coreLiveStore.state.status)
    }

    private func logSecondaryContentReadyIfNeeded() {
        guard !hasLoggedSecondaryReady else { return }
        hasLoggedSecondaryReady = true
        logHomeTiming(event: "secondary_ready", status: model.coreLiveStore.state.status)
    }

    private func logDiagnosticsReadyIfNeeded() {
        guard !hasLoggedDiagnosticsReady else { return }
        hasLoggedDiagnosticsReady = true
        logHomeTiming(event: "diagnostics_ready", status: model.coreLiveStore.state.status)
    }

    private func logHomeTiming(event: String, status: WhoopBLEManager.Status) {
        let elapsedMS = Int((Date().timeIntervalSince(homeAppearedAt ?? Date())) * 1000)
        WHOOPDebugLog("WHOOPDBG home_launch_timing event=%@ elapsed_ms=%d status=%@ tab=%@",
                      event,
                      elapsedMS,
                      status.logToken,
                      selectedTab.rawValue)
    }
}

private struct AtriaHeaderBar: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let store: SessionStore
    let ble: WhoopBLEManager

    var body: some View {
        HStack(alignment: .top) {
            AtriaHeaderTitleBlock(headline: headline)
                .equatable()

            Spacer(minLength: 12)

            HStack(spacing: 10) {
                connectionButton
                NavigationLink {
                    HistoryView(store: store)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3.weight(.semibold))
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(AtriaGlassIconButtonStyle())
            }
        }
    }

    private var headline: String {
        switch statusStore.state.status {
        case .connected:
            return "Connected fast path with local-only data."
        case .connecting:
            return "Finishing the first handoff."
        case .scanning:
            return "Searching quietly in the background."
        case .poweredOff:
            return "Bluetooth is paused."
        case .disconnected:
            return "Ready to reconnect when the strap is free."
        }
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch statusStore.state.status {
        case .connected:
            Button {
                ble.disconnect()
            } label: {
                Label("Connected", systemImage: "bolt.heart.fill")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .green))

        case .connecting, .scanning:
            Label(statusStore.state.status.rawValue, systemImage: "dot.radiowaves.left.and.right")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .atriaGlassCapsule(tint: .orange)

        case .poweredOff, .disconnected:
            Button {
                ble.startScan(reason: "home_manual")
            } label: {
                Label("Scan now", systemImage: "bolt.horizontal.circle")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .blue))
        }
    }
}

private struct AtriaHeroPanelHost: View {
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

private struct AtriaOverviewTabContent: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let heroStore: AtriaHomeModel.HeroStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool
    let horizontalSizeClass: UserInterfaceSizeClass?

    var body: some View {
        Group {
            if statusStore.state.status != .connected {
                if hasUnlockedSecondarySections {
                    AtriaDisconnectedOverviewHost(statusStore: statusStore,
                                                  homeStatsStore: homeStatsStore,
                                                  snapshotStore: snapshotStore)
                }
            } else if !hasUnlockedSecondarySections {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(heroStore: heroStore,
                                             snapshotStore: snapshotStore,
                                             hasUnlockedSecondarySections: false)
                    AtriaLoadingPanel(title: "Preparing saved insights",
                                      subtitle: "Trend, backup, and collection summaries join after the first live dashboard settles.")
                }
            } else if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        AtriaOverviewLeadingHost(heroStore: heroStore,
                                                 snapshotStore: snapshotStore,
                                                 hasUnlockedSecondarySections: hasUnlockedSecondarySections)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)

                    LazyVStack(spacing: 18) {
                        AtriaOverviewTrailingHost(liveStore: liveStore,
                                                  homeStatsStore: homeStatsStore,
                                                  snapshotStore: snapshotStore,
                                                  hasUnlockedSecondarySections: hasUnlockedSecondarySections)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                LazyVStack(spacing: 18) {
                    AtriaOverviewLeadingHost(heroStore: heroStore,
                                             snapshotStore: snapshotStore,
                                             hasUnlockedSecondarySections: hasUnlockedSecondarySections)
                    AtriaOverviewTrailingHost(liveStore: liveStore,
                                              homeStatsStore: homeStatsStore,
                                              snapshotStore: snapshotStore,
                                              hasUnlockedSecondarySections: hasUnlockedSecondarySections)
                }
            }
        }
    }
}

private struct AtriaDisconnectedOverviewHost: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaDisconnectedOverviewPanel(status: statusStore.state.status,
                                       stats: homeStatsStore.state,
                                       snapshot: snapshotStore.state)
            .equatable()
    }
}

private struct AtriaDisconnectedOverviewPanel: View, Equatable {
    let status: WhoopBLEManager.Status
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot

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
            return "Finishing the first handoff"
        case .scanning:
            return "Searching nearby"
        case .poweredOff:
            return "Bluetooth is paused"
        case .disconnected:
            return "Waiting for the strap"
        case .connected:
            return "Live data is flowing"
        }
    }

    private var detail: String {
        switch status {
        case .connecting:
            return "Atria is already trying to attach with the lightweight connection path."
        case .scanning:
            return "The radio is scanning quietly in the background while the rest of the dashboard stays light."
        case .poweredOff:
            return "Turn Bluetooth back on and Atria will resume its automatic scan."
        case .disconnected:
            return "The home screen stays intentionally minimal until the strap is free and nearby."
        case .connected:
            return "The heavier saved-session diagnostics will unlock after the live path settles."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Overview", subtitle: title)

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AtriaSummaryRow(label: "Reference", value: snapshot.referenceText)
            AtriaSummaryRow(label: "Baseline", value: "\(stats.baselineSamples)/7 HRV samples")
            AtriaSummaryRow(label: "Sessions", value: "\(stats.sessionsCount) saved")
            AtriaSummaryRow(label: "Next", value: stats.nextAction)
        }
        .padding(18)
        .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaOverviewLeadingHost: View {
    let heroStore: AtriaHomeModel.HeroStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool

    var body: some View {
        AtriaOverviewLeadingSection(heroStore: heroStore,
                                    snapshotStore: snapshotStore,
                                    hasUnlockedSecondarySections: hasUnlockedSecondarySections)
    }
}

private struct AtriaOverviewTrailingHost: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool

    var body: some View {
        AtriaOverviewTrailingSection(liveStore: liveStore,
                                     homeStatsStore: homeStatsStore,
                                     snapshotStore: snapshotStore,
                                     hasUnlockedSecondarySections: hasUnlockedSecondarySections)
    }
}

private struct AtriaVitalsTabContent: View {
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
                                   onUpdateProfile: store.updateProfile)
    }
}

private struct AtriaCollectionTabContent: View {
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

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(alignment: .top, spacing: 18) {
                    LazyVStack(spacing: 18) {
                        captureCard
                        rrReferenceCard
                        hrReferenceCard
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
                    rrReferenceCard
                    hrReferenceCard
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
                                        ble: ble)
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
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    var body: some View {
        AtriaProfileCard(profile: profileStore.profile,
                         observedPeakHeartRateText: pulseStore.state.peakHeartRateText,
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
            AtriaPanelSectionHeader(title: "Capture", subtitle: "Start quickly and keep exports local")

            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "Rows", value: "\(collectionLiveStore.state.capturedRows)")
                AtriaInlineQuickStat(label: "State", value: collectionLiveStore.state.recordingState)
                AtriaInlineQuickStat(label: "File", value: collectionLiveStore.state.captureFileLabel)
            }

            Text(collectionLiveStore.state.captureSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(collectionLiveStore.state.isRecording ? "Stop capture" : "Start capture") {
                    ble.toggleRecording()
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: collectionLiveStore.state.isRecording ? .red : .blue))

                Button("Prepare export") {
                    captureShareURL = ble.exportCSV()
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .gray))

                if let captureShareURL {
                    ShareLink(item: captureShareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .green))
                }
            }
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
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
            AtriaPanelSectionHeader(title: "RR reference", subtitle: "Validate local HRV with an external file")
            AtriaSummaryRow(label: "Status", value: homeStatsStore.state.rrPackageText)
            AtriaSummaryRow(label: "Detail", value: homeStatsStore.state.hrvDetail)
            if !rrImportStatus.isEmpty {
                Text(rrImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Export RR") {
                    rrShareURL = store.exportRRReferencePackageForUI()
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .gray))
                Button("Import RR") {
                    showRRImporter = true
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .blue))
                if let rrShareURL {
                    ShareLink(item: rrShareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .green))
                }
            }
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
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
            AtriaPanelSectionHeader(title: "HR reference", subtitle: "Validate workout intensity against an external HR source")
            AtriaSummaryRow(label: "Status", value: snapshotStore.state.referenceText)
            AtriaSummaryRow(label: "Workout", value: snapshotStore.state.workoutText)
            if !hrImportStatus.isEmpty {
                Text(hrImportStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button("Export HR") {
                    hrShareURL = store.exportHRReferencePackageForUI()
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .gray))
                Button("Import HR") {
                    showHRImporter = true
                }
                .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .blue))
                if let hrShareURL {
                    ShareLink(item: hrShareURL) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .green))
                }
            }
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
    }
}

private struct AtriaCollectionControlsCardHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var profileStore: AtriaHomeModel.ProfileStore
    let store: SessionStore
    let ble: WhoopBLEManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Collection controls", subtitle: "Low-friction radio and long wear modes")

            Toggle(isOn: Binding(
                get: { collectionLiveStore.state.standardHROnlyEnabled },
                set: { enabled in
                    ble.setStandardHROnlyEnabled(enabled)
                })
            ) {
                Label("Low radio HR", systemImage: "dot.radiowaves.left.and.right")
            }
            .tint(.blue)

            Toggle(isOn: Binding(
                get: { collectionLiveStore.state.longWearModeEnabled },
                set: { enabled in
                    ble.setLongWearModeEnabled(enabled,
                                               rest: homeStatsStore.state.restingHeartRate,
                                               maxHR: profileStore.profile.maxHR)
                })
            ) {
                Label("Long wear", systemImage: "record.circle")
            }
            .tint(.green)

            NavigationLink {
                HistoryView(store: store)
            } label: {
                Label("Open saved sessions", systemImage: "clock.arrow.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .atriaQuietPanel()
    }
}

private struct AtriaCollectionStatusCardHost: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Collection status", subtitle: "Show useful state fast")
            AtriaCollectionLoggingStatusHost(snapshotStore: snapshotStore)
            AtriaCollectionBackupStatusHost(homeStatsStore: homeStatsStore)
            AtriaCollectionBatteryStatusHost(coreLiveStore: coreLiveStore)
            AtriaCollectionModeStatusHost(collectionLiveStore: collectionLiveStore)
        }
        .padding(18)
        .atriaQuietPanel()
    }
}

private struct AtriaCollectionLoggingStatusHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaSummaryRow(label: "Logging", value: snapshotStore.state.loggingText)
            .equatable()
    }
}

private struct AtriaCollectionBackupStatusHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore

    var body: some View {
        AtriaSummaryRow(label: "Backup", value: homeStatsStore.state.backupValue)
            .equatable()
    }
}

private struct AtriaCollectionBatteryStatusHost: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore

    var body: some View {
        AtriaSummaryRow(label: "Battery", value: coreLiveStore.state.batteryText)
            .equatable()
    }
}

private struct AtriaCollectionModeStatusHost: View {
    @ObservedObject var collectionLiveStore: AtriaHomeModel.CollectionLiveStore

    var body: some View {
        AtriaSummaryRow(label: "Mode", value: collectionLiveStore.state.modeLabel)
            .equatable()
    }
}

@MainActor
final class AtriaHomeModel {
    struct StatusState: Equatable {
        var status: WhoopBLEManager.Status
    }

    struct CoreLiveState: Equatable {
        var status: WhoopBLEManager.Status
        var deviceName: String
        var batteryLevel: Int
        var rrContinuityState: String
        var sessionSampleCount: Int
        var liveTRIMP: Double

        var batteryText: String { batteryLevel >= 0 ? "\(batteryLevel)%" : "Waiting" }
        var rrContinuityText: String { rrContinuityState.replacingOccurrences(of: "_", with: " ") }
    }

    struct PulseLiveState: Equatable {
        var heartRate: Int
        var hasContact: Bool
        var averageHeartRate: Int?
        var peakHeartRate: Int?

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
        var contactText: String { hasContact ? "Live" : "No contact" }
        var averageHeartRateText: String { averageHeartRate.map(String.init) ?? "--" }
        var peakHeartRateText: String { peakHeartRate.map(String.init) ?? "--" }
    }

    struct HeroPulseState: Equatable {
        var heartRate: Int

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
    }

    struct PulseSparklineState: Equatable {
        var values: [Int]
    }

    struct CollectionLiveState: Equatable {
        var isRecording: Bool
        var capturedRows: Int
        var captureSummary: String
        var captureWasValidationReady: Bool
        var lastCaptureFile: String
        var standardHROnlyEnabled: Bool
        var longWearModeEnabled: Bool

        var recordingState: String { isRecording ? "Recording" : (captureWasValidationReady ? "Ready" : "Idle") }
        var captureFileLabel: String { lastCaptureFile.isEmpty ? "None" : "Saved" }
        var modeLabel: String {
            longWearModeEnabled ? "long wear" : (standardHROnlyEnabled ? "low radio" : "full protocol")
        }
    }

    struct HeroSnapshot: Equatable {
        let recoveryEstimate: Metrics.RecoveryEstimate
        let strain: Double
        let strainConfidence: String
        let guidance: Coach.Guidance
        let hrvValue: String
        let hrvDetail: String
        let hrvNarrative: String
        let rrPackageText: String
        let nextAction: String
        let headline: String
        let sessionsCount: Int
        let baselineSamples: Int
        let backupValue: String
        let backupDetail: String
        let restingHeartRate: Int
        let restingHeartRateText: String
        let strainNarrative: String

        var recoveryValue: String {
            recoveryEstimate.percent.map { "\($0)%" } ?? "Learning"
        }

        var recoveryDetail: String {
            recoveryEstimate.confidence.rawValue
        }

        var strainValue: String {
            String(format: "%.1f", strain)
        }

        var strainDetail: String {
            strainConfidence
        }

        static func == (lhs: HeroSnapshot, rhs: HeroSnapshot) -> Bool {
            lhs.recoveryEstimate.percent == rhs.recoveryEstimate.percent
                && lhs.recoveryEstimate.confidence == rhs.recoveryEstimate.confidence
                && lhs.recoveryEstimate.detail == rhs.recoveryEstimate.detail
                && lhs.strainConfidence == rhs.strainConfidence
                && lhs.guidance == rhs.guidance
                && lhs.hrvValue == rhs.hrvValue
                && lhs.hrvDetail == rhs.hrvDetail
                && lhs.hrvNarrative == rhs.hrvNarrative
                && lhs.rrPackageText == rhs.rrPackageText
                && lhs.nextAction == rhs.nextAction
                && lhs.headline == rhs.headline
                && lhs.sessionsCount == rhs.sessionsCount
                && lhs.baselineSamples == rhs.baselineSamples
                && lhs.backupValue == rhs.backupValue
                && lhs.backupDetail == rhs.backupDetail
                && lhs.restingHeartRate == rhs.restingHeartRate
                && lhs.restingHeartRateText == rhs.restingHeartRateText
                && lhs.strainNarrative == rhs.strainNarrative
                && Self.displayStrainBucket(lhs.strain) == Self.displayStrainBucket(rhs.strain)
        }

        private static func displayStrainBucket(_ value: Double) -> Int {
            Int((value * 10).rounded())
        }
    }

    struct Snapshot: Equatable {
        let referenceText: String
        let sleepValue: String
        let sleepDetail: String
        let workoutText: String
        let loggingText: String
        let trendCoverageText: String
        let trendConfidence: String
        let trendDetail: String
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
    }

    struct HomeStatsState: Equatable {
        let rrPackageText: String
        let hrvDetail: String
        let nextAction: String
        let sessionsCount: Int
        let baselineSamples: Int
        let backupValue: String
        let backupDetail: String
        let restingHeartRate: Int
        let restingHeartRateText: String
    }

    final class HeroStore: ObservableObject {
        @Published fileprivate(set) var state: HeroSnapshot

        init(state: HeroSnapshot) {
            self.state = state
        }
    }

    final class CoreLiveStore: ObservableObject {
        @Published fileprivate(set) var state: CoreLiveState

        init(state: CoreLiveState) {
            self.state = state
        }
    }

    final class PulseLiveStore: ObservableObject {
        @Published fileprivate(set) var state: PulseLiveState

        init(state: PulseLiveState) {
            self.state = state
        }
    }

    final class HeroPulseStore: ObservableObject {
        @Published fileprivate(set) var state: HeroPulseState

        init(state: HeroPulseState) {
            self.state = state
        }
    }

    final class PulseSparklineStore: ObservableObject {
        @Published fileprivate(set) var state: PulseSparklineState

        init(state: PulseSparklineState) {
            self.state = state
        }
    }

    final class CollectionLiveStore: ObservableObject {
        @Published fileprivate(set) var state: CollectionLiveState

        init(state: CollectionLiveState) {
            self.state = state
        }
    }

    final class SnapshotStore: ObservableObject {
        @Published fileprivate(set) var state: Snapshot
        @Published fileprivate(set) var diagnosticsReady = false

        init(state: Snapshot) {
            self.state = state
        }
    }

    final class HomeStatsStore: ObservableObject {
        @Published fileprivate(set) var state: HomeStatsState

        init(state: HomeStatsState) {
            self.state = state
        }
    }

    final class ProfileStore: ObservableObject {
        @Published fileprivate(set) var profile: AthleteProfile

        init(profile: AthleteProfile) {
            self.profile = profile
        }
    }

    final class StatusStore: ObservableObject {
        @Published fileprivate(set) var state: StatusState

        init(state: StatusState) {
            self.state = state
        }
    }

    let heroStore: HeroStore
    let heroPulseStore: HeroPulseStore
    let statusStore: StatusStore
    let coreLiveStore: CoreLiveStore
    let pulseLiveStore: PulseLiveStore
    let pulseSparklineStore: PulseSparklineStore
    let collectionLiveStore: CollectionLiveStore
    let snapshotStore: SnapshotStore
    let homeStatsStore: HomeStatsStore
    let profileStore: ProfileStore

    private let ble: WhoopBLEManager
    private let store: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private let coreRefreshSubject = PassthroughSubject<Void, Never>()
    private let heroRefreshSubject = PassthroughSubject<Void, Never>()
    private let diagnosticsRefreshSubject = PassthroughSubject<Void, Never>()
    private let storeRefreshSubject = PassthroughSubject<Void, Never>()
    private var deferredDetails: DeferredDetails?
    private var savedAggregate: SavedAggregate
    private var diagnosticsRequested = false
    private var liveSessionDerived: LiveSessionDerived
    private var diagnosticsWorkItem: DispatchWorkItem?
    private var diagnosticsRefreshToken = UUID()
    private var prefersPulseSparklineUpdates = false

    private struct SavedAggregate: Equatable {
        let savedTodayTRIMP: Double
        let hasSavedToday: Bool
        let sessionsCount: Int
        let baselineSamples: Int
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
    }

    private struct DeferredDetails: Equatable {
        let hrvValue: String
        let hrvDetail: String
        let hrvNarrative: String
        let rrPackageText: String
        let referenceText: String
        let sleepValue: String
        let sleepDetail: String
        let workoutText: String
        let loggingText: String
        let backupValue: String
        let backupDetail: String
        let trendCoverageText: String
        let trendConfidence: String
        let trendDetail: String
        let nextAction: String
        let headline: String
        let confirmedWorkouts: Int
        let confirmedSleeps: Int
    }

    private static let placeholderSnapshot = Snapshot(referenceText: "Waiting",
                                                      sleepValue: "Loading",
                                                      sleepDetail: "saved history",
                                                      workoutText: "Loading",
                                                      loggingText: "warming up",
                                                      trendCoverageText: "--",
                                                      trendConfidence: "learning",
                                                      trendDetail: "Saved trends are loading.",
                                                      confirmedWorkouts: 0,
                                                      confirmedSleeps: 0)

    private struct LiveSessionDerived: Equatable {
        let sampleCount: Int
        let lastTimestamp: Date?
        let rest: Int
        let maxHR: Int
        let trimp: Double
    }

    private struct PulseWindowSummary: Equatable {
        let averageHeartRate: Int?
        let peakHeartRate: Int?
    }

    init(ble: WhoopBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        self.savedAggregate = Self.makeSavedAggregate(store: store)
        let initialLiveSessionDerived = Self.makeLiveSessionDerived(samples: ble.session,
                                                                    rest: Self.currentRestingHeartRate(ble: ble, store: store),
                                                                    maxHR: store.profile.maxHR)
        let initialStatus = StatusState(status: ble.status)
        let initialCoreLive = Self.makeCoreLiveState(ble: ble, liveSessionDerived: initialLiveSessionDerived)
        let initialHeroPulse = Self.makeHeroPulseState(ble: ble)
        let initialPulseLive = Self.makePulseLiveState(ble: ble)
        let initialPulseSparkline = Self.makePulseSparklineState(ble: ble)
        let initialCollectionLive = Self.makeCollectionLiveState(ble: ble)
        let initialHero = Self.makeHeroSnapshot(ble: ble,
                                                store: store,
                                                live: initialCoreLive,
                                                savedAggregate: self.savedAggregate,
                                                deferredDetails: nil)
        let initialHomeStats = Self.makeHomeStatsState(hero: initialHero)
        self.liveSessionDerived = initialLiveSessionDerived
        self.heroStore = HeroStore(state: initialHero)
        self.heroPulseStore = HeroPulseStore(state: initialHeroPulse)
        self.statusStore = StatusStore(state: initialStatus)
        self.coreLiveStore = CoreLiveStore(state: initialCoreLive)
        self.pulseLiveStore = PulseLiveStore(state: initialPulseLive)
        self.pulseSparklineStore = PulseSparklineStore(state: initialPulseSparkline)
        self.collectionLiveStore = CollectionLiveStore(state: initialCollectionLive)
        self.snapshotStore = SnapshotStore(state: Self.placeholderSnapshot)
        self.homeStatsStore = HomeStatsStore(state: initialHomeStats)
        self.profileStore = ProfileStore(profile: store.profile)
        bind()
        coreRefreshSubject.send(())
        heroRefreshSubject.send(())
    }

    func setPulseDetailMode(active: Bool) {
        guard prefersPulseSparklineUpdates != active else { return }
        prefersPulseSparklineUpdates = active
        if active {
            publishPulseLive()
            publishPulseSparkline()
        }
    }

    func forceRefresh() {
        publishStatus()
        publishCoreLive()
        publishHeroPulse()
        publishPulseLive()
        publishPulseSparkline()
        publishCollectionLive()
        refreshHeroSnapshot()
        coreRefreshSubject.send(())
        loadDeferredDiagnosticsIfNeeded(reason: "force_refresh")
    }

    func loadDeferredDiagnosticsIfNeeded(reason: String) {
        if !diagnosticsRequested {
            diagnosticsRequested = true
            WHOOPDebugLog("WHOOPDBG home_diagnostics status=requested reason=%@", reason)
        }
        diagnosticsRefreshSubject.send(())
    }

    private func bind() {
        let immediateStatusChanges = ble.$status
            .removeDuplicates()
            .map { _ in () }

        immediateStatusChanges
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishStatus()
                self.publishCoreLive()
                self.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        ble.$deviceName
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                self?.publishCoreLive()
            }
            .store(in: &cancellables)

        let throttledCoreLiveChanges = Publishers.MergeMany([
            ble.$batteryLevel.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rrContinuityState.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)

        throttledCoreLiveChanges
            .sink { [weak self] _ in
                self?.publishCoreLive()
            }
            .store(in: &cancellables)

        let pulseRateChanges = ble.$heartRate
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        pulseRateChanges
            .throttle(for: .milliseconds(650), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.publishHeroPulse()
            }
            .store(in: &cancellables)

        let pulseContactChanges = ble.$hasContact
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        let pulseSummaryChanges = ble.$liveHeartWindow
            .map { window in
                PulseWindowSummary(averageHeartRate: window.average,
                                   peakHeartRate: window.peak)
            }
            .removeDuplicates()
            .map { _ in () }
            .eraseToAnyPublisher()

        let throttledPulseLiveChanges = Publishers.MergeMany([
            pulseRateChanges,
            pulseContactChanges,
            pulseSummaryChanges
        ])
        .throttle(for: .milliseconds(650), scheduler: RunLoop.main, latest: true)

        throttledPulseLiveChanges
            .sink { [weak self] _ in
                guard let self, self.prefersPulseSparklineUpdates else { return }
                self.publishPulseLive()
            }
            .store(in: &cancellables)

        ble.$liveHeartWindow
            .map(\.sparkline)
            .removeDuplicates()
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] (_: [Int]) in
                guard let self, self.prefersPulseSparklineUpdates else { return }
                self.publishPulseSparkline()
            }
            .store(in: &cancellables)

        Publishers.Merge(
            ble.$hrvSnapshot.map { _ in () }.eraseToAnyPublisher(),
            ble.$hrvQuality.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(1200), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in
            self?.heroRefreshSubject.send(())
        }
        .store(in: &cancellables)

        let collectionLiveChanges = Publishers.MergeMany([
            ble.$isRecording.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$capturedRows.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$captureSummary.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$captureWasValidationReady.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastCaptureFile.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$standardHROnlyEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$longWearModeEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)

        collectionLiveChanges
            .sink { [weak self] _ in self?.publishCollectionLive() }
            .store(in: &cancellables)

        store.$dashboardRevision
            .map { _ in () }
            .sink { [weak self] _ in
                self?.storeRefreshSubject.send(())
            }
            .store(in: &cancellables)

        storeRefreshSubject
            .debounce(for: .milliseconds(900), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.refreshSavedAggregate()
                self.coreRefreshSubject.send(())
                self.heroRefreshSubject.send(())
                if self.diagnosticsRequested {
                    self.diagnosticsRefreshSubject.send(())
                }
            }
            .store(in: &cancellables)

        store.$profile
            .removeDuplicates()
            .sink { [weak self] profile in
                guard let self else { return }
                if self.ble.maxHRSetting != profile.maxHR {
                    self.ble.maxHRSetting = profile.maxHR
                }
                self.publishProfile()
                self.refreshSavedAggregate()
                self.publishCoreLive()
                self.publishHeroPulse()
                if self.prefersPulseSparklineUpdates {
                    self.publishPulseLive()
                    self.publishPulseSparkline()
                }
                self.coreRefreshSubject.send(())
                self.refreshHeroSnapshot()
                if self.diagnosticsRequested {
                    self.diagnosticsRefreshSubject.send(())
                }
            }
            .store(in: &cancellables)

        heroRefreshSubject
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.refreshHeroSnapshot()
            }
            .store(in: &cancellables)

        coreRefreshSubject
            .debounce(for: .milliseconds(450), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.publishSnapshotIfNeeded(Self.makeSnapshot(store: self.store,
                                                               hero: self.heroStore.state,
                                                               deferredDetails: self.deferredDetails))
            }
            .store(in: &cancellables)

        diagnosticsRefreshSubject
            .debounce(for: .milliseconds(2800), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.scheduleDeferredDiagnosticsRefresh()
            }
            .store(in: &cancellables)

    }

    private func publishStatus() {
        let next = StatusState(status: ble.status)
        guard next != statusStore.state else { return }
        statusStore.state = next
    }

    private func publishCoreLive() {
        refreshLiveSessionDerivedIfNeeded()
        let next = Self.makeCoreLiveState(ble: ble, liveSessionDerived: liveSessionDerived)
        guard next != coreLiveStore.state else { return }
        coreLiveStore.state = next
    }

    private func publishHeroPulse() {
        let next = Self.makeHeroPulseState(ble: ble)
        guard next != heroPulseStore.state else { return }
        heroPulseStore.state = next
    }

    private func publishPulseLive() {
        let next = Self.makePulseLiveState(ble: ble)
        guard next != pulseLiveStore.state else { return }
        pulseLiveStore.state = next
    }

    private func publishPulseSparkline() {
        let next = Self.makePulseSparklineState(ble: ble)
        guard next != pulseSparklineStore.state else { return }
        pulseSparklineStore.state = next
    }

    private func publishCollectionLive() {
        let next = Self.makeCollectionLiveState(ble: ble)
        guard next != collectionLiveStore.state else { return }
        collectionLiveStore.state = next
    }

    private func publishProfile() {
        let next = store.profile
        guard next != profileStore.profile else { return }
        profileStore.profile = next
    }

    private func refreshSavedAggregate() {
        let next = Self.makeSavedAggregate(store: store)
        guard next != savedAggregate else { return }
        savedAggregate = next
    }

    private func refreshHeroSnapshot() {
        publishHeroSnapshotIfNeeded(Self.makeHeroSnapshot(ble: ble,
                                                          store: store,
                                                          live: coreLiveStore.state,
                                                          savedAggregate: savedAggregate,
                                                          deferredDetails: deferredDetails))
    }

    private func publishHeroSnapshotIfNeeded(_ next: HeroSnapshot) {
        guard next != heroStore.state else { return }
        heroStore.state = next
        publishHomeStatsIfNeeded(Self.makeHomeStatsState(hero: next))
    }

    private func publishSnapshotIfNeeded(_ next: Snapshot) {
        guard next != snapshotStore.state else { return }
        snapshotStore.state = next
    }

    private func publishHomeStatsIfNeeded(_ next: HomeStatsState) {
        guard next != homeStatsStore.state else { return }
        homeStatsStore.state = next
    }

    private func scheduleDeferredDiagnosticsRefresh() {
        diagnosticsWorkItem?.cancel()
        let token = UUID()
        diagnosticsRefreshToken = token
        let workItem = DispatchWorkItem(qos: .utility) { [weak self] in
            guard let self else { return }
            let details = Self.makeDeferredDetails(ble: self.ble, store: self.store)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.diagnosticsRefreshToken == token else { return }
                self.deferredDetails = details
                if !self.snapshotStore.diagnosticsReady {
                    self.snapshotStore.diagnosticsReady = true
                }
                let nextHero = Self.makeHeroSnapshot(ble: self.ble,
                                                     store: self.store,
                                                     live: self.coreLiveStore.state,
                                                     savedAggregate: self.savedAggregate,
                                                     deferredDetails: details)
                self.publishHeroSnapshotIfNeeded(nextHero)
                self.publishSnapshotIfNeeded(Self.makeSnapshot(store: self.store,
                                                               hero: nextHero,
                                                               deferredDetails: details))
            }
        }
        diagnosticsWorkItem = workItem
        DispatchQueue.global(qos: .utility).async(execute: workItem)
    }

    private func refreshLiveSessionDerived() {
        liveSessionDerived = Self.nextLiveSessionDerived(previous: liveSessionDerived,
                                                         samples: ble.session,
                                                         rest: Self.currentRestingHeartRate(ble: ble, store: store),
                                                         maxHR: store.profile.maxHR)
    }

    private func refreshLiveSessionDerivedIfNeeded() {
        let rest = Self.currentRestingHeartRate(ble: ble, store: store)
        let maxHR = store.profile.maxHR
        let samples = ble.session
        let needsRefresh = liveSessionDerived.rest != rest
            || liveSessionDerived.maxHR != maxHR
            || liveSessionDerived.sampleCount != samples.count
            || liveSessionDerived.lastTimestamp != samples.last?.t

        guard needsRefresh else { return }
        liveSessionDerived = Self.nextLiveSessionDerived(previous: liveSessionDerived,
                                                         samples: samples,
                                                         rest: rest,
                                                         maxHR: maxHR)
    }

    private static func currentRestingHeartRate(ble: WhoopBLEManager, store: SessionStore) -> Int {
        store.baseline.restingInt ?? ble.restingHR ?? store.sessions.first?.restingStable ?? 60
    }

    private static func makeCoreLiveState(ble: WhoopBLEManager,
                                          liveSessionDerived: LiveSessionDerived) -> CoreLiveState {
        return CoreLiveState(status: ble.status,
                             deviceName: ble.deviceName,
                             batteryLevel: ble.batteryLevel,
                             rrContinuityState: ble.rrContinuityState,
                             sessionSampleCount: liveSessionDerived.sampleCount,
                             liveTRIMP: liveSessionDerived.trimp)
    }

    private static func makePulseLiveState(ble: WhoopBLEManager) -> PulseLiveState {
        PulseLiveState(heartRate: ble.heartRate,
                       hasContact: ble.hasContact,
                       averageHeartRate: ble.liveHeartWindow.average,
                       peakHeartRate: ble.liveHeartWindow.peak)
    }

    private static func makeHeroPulseState(ble: WhoopBLEManager) -> HeroPulseState {
        HeroPulseState(heartRate: ble.heartRate)
    }

    private static func makePulseSparklineState(ble: WhoopBLEManager) -> PulseSparklineState {
        PulseSparklineState(values: ble.liveHeartWindow.sparkline)
    }

    private static func makeCollectionLiveState(ble: WhoopBLEManager) -> CollectionLiveState {
        return CollectionLiveState(isRecording: ble.isRecording,
                                   capturedRows: ble.capturedRows,
                                   captureSummary: ble.captureSummary,
                                   captureWasValidationReady: ble.captureWasValidationReady,
                                   lastCaptureFile: ble.lastCaptureFile,
                                   standardHROnlyEnabled: ble.standardHROnlyEnabled,
                                   longWearModeEnabled: ble.longWearModeEnabled)
    }

    private static func makeHeroSnapshot(ble: WhoopBLEManager,
                                         store: SessionStore,
                                         live: CoreLiveState,
                                         savedAggregate: SavedAggregate,
                                         deferredDetails: DeferredDetails?) -> HeroSnapshot {
        let rest = currentRestingHeartRate(ble: ble, store: store)
        let fallbackHrv = fallbackHeroHRVState(ble: ble, store: store)
        let headline = deferredDetails?.headline ?? defaultHeroHeadline(status: ble.status)
        let nextAction = deferredDetails?.nextAction ?? defaultHeroNextAction(status: ble.status)

        if live.status != .connected && deferredDetails == nil {
            return makeDisconnectedHeroSnapshot(live: live,
                                                savedAggregate: savedAggregate,
                                                fallbackHrv: fallbackHrv,
                                                headline: headline,
                                                nextAction: nextAction,
                                                rest: rest)
        }

        let maxHR = store.profile.maxHR
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: store.latestReferenceValidatedHRV,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline)
        let liveTRIMP = live.liveTRIMP
        let totalTRIMP = savedAggregate.savedTodayTRIMP + liveTRIMP
        let strain = Metrics.strain(fromTRIMP: totalTRIMP)
        let strainConfidence: String
        if maxHR <= rest {
            strainConfidence = "learning"
        } else if savedAggregate.hasSavedToday || live.sessionSampleCount >= 60 {
            strainConfidence = "local"
        } else {
            strainConfidence = "learning"
        }

        let guidance = Coach.guide(recovery: recovery, strain: strain)
        return HeroSnapshot(recoveryEstimate: recovery,
                            strain: strain,
                            strainConfidence: strainConfidence,
                            guidance: guidance,
                            hrvValue: deferredDetails?.hrvValue ?? fallbackHrv.value,
                            hrvDetail: deferredDetails?.hrvDetail ?? fallbackHrv.detail,
                            hrvNarrative: deferredDetails?.hrvNarrative ?? fallbackHrv.narrative,
                            rrPackageText: deferredDetails?.rrPackageText ?? fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: deferredDetails?.backupValue ?? "Loading",
                            backupDetail: deferredDetails?.backupDetail ?? "saved history",
                            restingHeartRate: rest,
                            restingHeartRateText: "\(rest)",
                            strainNarrative: String(format: "TRIMP %.1f from saved %.1f + live %.1f", totalTRIMP, savedAggregate.savedTodayTRIMP, liveTRIMP))
    }

    private struct FallbackHeroHRVState {
        let value: String
        let detail: String
        let narrative: String
        let packageText: String
    }

    private static func fallbackHeroHRVState(ble: WhoopBLEManager,
                                             store: SessionStore) -> FallbackHeroHRVState {
        let value: String
        if let validated = store.latestReferenceValidatedHRV {
            value = "\(validated)"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            value = "\(Int(snapshot.rmssd.rounded()))"
        } else {
            value = "Learning"
        }

        let detail: String
        if store.latestReferenceValidatedHRV != nil {
            detail = "validated"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            detail = "reference pending"
        } else {
            detail = ble.hrvQuality
        }

        let narrative: String
        if store.latestReferenceValidatedHRV != nil {
            narrative = "Validated HRV is unlocked from your local reference flow."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            narrative = "The live RR window is clean enough to measure while deeper diagnostics catch up."
        } else {
            narrative = "Atria is keeping the live RR window lightweight while connection settles."
        }

        let packageText: String
        if store.latestReferenceValidatedHRV != nil {
            packageText = "Validated"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            packageText = "Preparing"
        } else {
            packageText = "Learning"
        }

        return FallbackHeroHRVState(value: value,
                                    detail: detail,
                                    narrative: narrative,
                                    packageText: packageText)
    }

    private static func defaultHeroHeadline(status: WhoopBLEManager.Status) -> String {
        if status == .connected {
            return "Connected fast path with local-only data."
        }
        return "A lighter dashboard that gets to data faster."
    }

    private static func defaultHeroNextAction(status: WhoopBLEManager.Status) -> String {
        if status != .connected {
            return "Keep the phone near the strap until Atria reconnects."
        }
        return "Settling saved diagnostics in the background."
    }

    private static func makeDisconnectedHeroSnapshot(live: CoreLiveState,
                                                     savedAggregate: SavedAggregate,
                                                     fallbackHrv: FallbackHeroHRVState,
                                                     headline: String,
                                                     nextAction: String,
                                                     rest: Int) -> HeroSnapshot {
        let guidance: Coach.Guidance
        switch live.status {
        case .scanning:
            guidance = Coach.Guidance(headline: "Scanning with the light radio path",
                                      detail: "Atria is keeping the first screen responsive while it looks for the strap in the background.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_scanning_fast_path")
        case .connecting:
            guidance = Coach.Guidance(headline: "Finishing the handoff",
                                      detail: "The app is prioritizing connection setup first, then it will expand into the richer live cards.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_connecting_fast_path")
        case .poweredOff:
            guidance = Coach.Guidance(headline: "Bluetooth needs to come back first",
                                      detail: "Atria is holding the dashboard in a low-power state until Bluetooth is available again.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_powered_off_fast_path")
        case .disconnected:
            guidance = Coach.Guidance(headline: "Ready for a clean reconnect",
                                      detail: "Saved data stays available immediately while Atria keeps the live connection path quiet in the background.",
                                      color: .blue,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_idle_fast_path")
        case .connected:
            guidance = Coach.Guidance(headline: "Connected fast path with local-only data.",
                                      detail: "Live scoring will settle in after the first screen becomes interactive.",
                                      color: .green,
                                      target: nil,
                                      state: "learning",
                                      reason: "connected_fast_path_placeholder")
        }

        let hasSavedBackup = savedAggregate.sessionsCount > 0

        return HeroSnapshot(recoveryEstimate: Metrics.RecoveryEstimate(percent: nil,
                                                                       confidence: .learning,
                                                                       usesHRV: false,
                                                                       detail: "learning: reconnecting"),
                            strain: 0,
                            strainConfidence: "standby",
                            guidance: guidance,
                            hrvValue: fallbackHrv.value,
                            hrvDetail: fallbackHrv.detail,
                            hrvNarrative: fallbackHrv.narrative,
                            rrPackageText: fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: hasSavedBackup ? "Ready" : "Learning",
                            backupDetail: hasSavedBackup ? "saved locally" : "no backup yet",
                            restingHeartRate: rest,
                            restingHeartRateText: "\(rest)",
                            strainNarrative: "Live strain resumes after the strap reconnects.")
    }

    private static func makeSnapshot(store: SessionStore,
                                     hero: HeroSnapshot,
                                     deferredDetails: DeferredDetails?) -> Snapshot {
        let defaultReferenceText = store.externalHRReferenceValidated ? "Validated" : "Waiting"

        return Snapshot(referenceText: deferredDetails?.referenceText ?? defaultReferenceText,
                        sleepValue: deferredDetails?.sleepValue ?? "Loading",
                        sleepDetail: deferredDetails?.sleepDetail ?? "saved history",
                        workoutText: deferredDetails?.workoutText ?? "Loading",
                        loggingText: deferredDetails?.loggingText ?? "warming up",
                        trendCoverageText: deferredDetails?.trendCoverageText ?? "--",
                        trendConfidence: deferredDetails?.trendConfidence ?? "learning",
                        trendDetail: deferredDetails?.trendDetail ?? "Saved trends are loading.",
                        confirmedWorkouts: deferredDetails?.confirmedWorkouts ?? store.confirmedWorkouts.count,
                        confirmedSleeps: deferredDetails?.confirmedSleeps ?? store.confirmedSleeps.count)
    }

    private static func makeHomeStatsState(hero: HeroSnapshot) -> HomeStatsState {
        HomeStatsState(rrPackageText: hero.rrPackageText,
                       hrvDetail: hero.hrvDetail,
                       nextAction: hero.nextAction,
                       sessionsCount: hero.sessionsCount,
                       baselineSamples: hero.baselineSamples,
                       backupValue: hero.backupValue,
                       backupDetail: hero.backupDetail,
                       restingHeartRate: hero.restingHeartRate,
                       restingHeartRateText: hero.restingHeartRateText)
    }

    private static func makeSavedAggregate(store: SessionStore) -> SavedAggregate {
        let rest = store.baseline.restingInt ?? store.sessions.first?.restingStable ?? 60
        let maxHR = store.profile.maxHR
        let aggregate = store.homeSavedAggregate(rest: rest, maxHR: maxHR)
        return SavedAggregate(savedTodayTRIMP: aggregate.savedTodayTRIMP,
                              hasSavedToday: aggregate.hasSavedToday,
                              sessionsCount: aggregate.sessionsCount,
                              baselineSamples: store.baseline.hrvSampleCount,
                              confirmedWorkouts: store.confirmedWorkouts.count,
                              confirmedSleeps: store.confirmedSleeps.count)
    }

    private static func makeDeferredDetails(ble: WhoopBLEManager, store: SessionStore) -> DeferredDetails {
        let diagnostics = store.homeDashboardDiagnostics()
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: store.latestReferenceValidatedHRV,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline)
        let rrPackage = diagnostics.rrPackage
        let sleep = diagnostics.sleep
        let workout = diagnostics.workout
        let collection = diagnostics.collection
        let backup = diagnostics.backup
        let trend90 = diagnostics.trend90

        let hrvValue: String
        if let validated = store.latestReferenceValidatedHRV {
            hrvValue = "\(validated)"
        } else if rrPackage.ready, let rmssd = rrPackage.rmssd {
            hrvValue = "\(Int(rmssd.rounded()))"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            hrvValue = "\(Int(snapshot.rmssd.rounded()))"
        } else {
            hrvValue = "Learning"
        }

        let hrvDetail: String
        if store.latestReferenceValidatedHRV != nil {
            hrvDetail = "validated"
        } else if rrPackage.ready {
            hrvDetail = "\(rrPackage.confidencePercent)% kept"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            hrvDetail = "reference pending"
        } else {
            hrvDetail = ble.hrvQuality
        }

        let hrvNarrative: String
        if store.latestReferenceValidatedHRV != nil {
            hrvNarrative = "Validated HRV is unlocked from your local reference flow."
        } else if rrPackage.ready {
            hrvNarrative = "A clean RR package is ready; importing an external reference will validate HRV."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            hrvNarrative = "The live RR window is clean enough to measure, but it still needs a reference check."
        } else {
            hrvNarrative = ble.hrvQuality
        }

        let sleepValue: String
        let sleepDetail: String
        if sleep.ready {
            sleepValue = "Ready"
            sleepDetail = sleep.confidence
        } else if sleep.fallbackAvailable {
            sleepValue = "Candidate"
            sleepDetail = "\(Int((sleep.fallbackDuration / 60).rounded()))m saved"
        } else if sleep.candidates > 0 {
            sleepValue = "\(sleep.candidates)"
            sleepDetail = sleep.blocker.replacingOccurrences(of: "_", with: " ")
        } else {
            sleepValue = "Learning"
            sleepDetail = "no window"
        }

        let workoutText: String
        if workout.ready {
            workoutText = "Ready"
        } else if workout.strengthCandidate {
            workoutText = "Strength candidate"
        } else if workout.nearMiss {
            workoutText = "Near miss"
        } else if workout.source != "none" {
            workoutText = "Peak \(workout.peakHR)bpm"
        } else {
            workoutText = "Learning"
        }

        let loggingText: String
        if collection.ready {
            loggingText = "\(collection.source == "saved_session_tail" ? "saved" : "live") \(collection.samples) samples"
        } else {
            loggingText = collection.blocker.replacingOccurrences(of: "_", with: " ")
        }

        let backupValue: String
        let backupDetail: String
        if backup.current {
            backupValue = "Ready"
            backupDetail = "\(backup.sessions) sessions"
        } else if backup.available {
            backupValue = "Stale"
            backupDetail = backup.reason.replacingOccurrences(of: "_", with: " ")
        } else {
            backupValue = "Missing"
            backupDetail = "not saved"
        }

        let rrPackageText: String
        if store.latestReferenceValidatedHRV != nil {
            rrPackageText = "Validated"
        } else if rrPackage.ready {
            rrPackageText = "Ready"
        } else if rrPackage.rrSamples > 0 {
            rrPackageText = "\(rrPackage.rrSamples) RR"
        } else {
            rrPackageText = "Learning"
        }

        let referenceText: String
        if store.externalHRReferenceValidated {
            referenceText = "Validated"
        } else {
            let csv = store.csvHRReferenceDiagnostics
            referenceText = csv.pairs > 0 ? "\(csv.pairs) pairs" : "Missing"
        }

        let headline: String
        if ble.status == .connected {
            headline = "Connected fast path with local-only data."
        } else if rrPackage.ready {
            headline = "Saved RR is local and ready while the strap reconnects."
        } else {
            headline = "A lighter dashboard that gets to data faster."
        }

        let nextAction: String
        if ble.status != .connected {
            nextAction = "Keep the phone near the strap until Atria reconnects."
        } else if recovery.percent == nil && rrPackage.ready && store.latestReferenceValidatedHRV == nil {
            nextAction = "Import an RR reference to unlock validated HRV."
        } else if !collection.ready {
            nextAction = "Keep Atria open a little longer so local collection settles."
        } else {
            nextAction = "Keep wearing; local collection is active."
        }

        return DeferredDetails(hrvValue: hrvValue,
                               hrvDetail: hrvDetail,
                               hrvNarrative: hrvNarrative,
                               rrPackageText: rrPackageText,
                               referenceText: referenceText,
                               sleepValue: sleepValue,
                               sleepDetail: sleepDetail,
                               workoutText: workoutText,
                               loggingText: loggingText,
                               backupValue: backupValue,
                               backupDetail: backupDetail,
                               trendCoverageText: "\(trend90.coveragePercent)%",
                               trendConfidence: trend90.confidence,
                               trendDetail: trend90.detail,
                               nextAction: nextAction,
                               headline: headline,
                               confirmedWorkouts: store.confirmedWorkouts.count,
                               confirmedSleeps: store.confirmedSleeps.count)
    }

    private static func sessionHeartStats(_ samples: [HRSample]) -> (average: Int?, peak: Int?) {
        guard !samples.isEmpty else { return (nil, nil) }
        var total = 0
        var count = 0
        var peak = Int.min
        for sample in samples where sample.bpm > 0 {
            total += sample.bpm
            count += 1
            peak = max(peak, sample.bpm)
        }
        guard count > 0 else { return (nil, nil) }
        return (Int((Double(total) / Double(count)).rounded()),
                peak == Int.min ? nil : peak)
    }

    private static func makeLiveSessionDerived(samples: [HRSample],
                                               rest: Int,
                                               maxHR: Int) -> LiveSessionDerived {
        LiveSessionDerived(sampleCount: samples.count,
                           lastTimestamp: samples.last?.t,
                           rest: rest,
                           maxHR: maxHR,
                           trimp: liveSessionTRIMP(samples, rest: rest, max: maxHR))
    }

    private static func nextLiveSessionDerived(previous: LiveSessionDerived,
                                               samples: [HRSample],
                                               rest: Int,
                                               maxHR: Int) -> LiveSessionDerived {
        guard previous.rest == rest,
              previous.maxHR == maxHR,
              samples.count >= previous.sampleCount,
              previous.sampleCount > 0,
              previous.sampleCount <= samples.count,
              previous.lastTimestamp == samples[previous.sampleCount - 1].t else {
            return makeLiveSessionDerived(samples: samples, rest: rest, maxHR: maxHR)
        }

        guard samples.count > previous.sampleCount else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      rest: rest,
                                      maxHR: maxHR,
                                      trimp: previous.trimp)
        }

        guard maxHR > rest else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      rest: rest,
                                      maxHR: maxHR,
                                      trimp: 0)
        }

        let span = Double(maxHR - rest)
        var total = previous.trimp
        for index in previous.sampleCount..<samples.count {
            let dtMin = samples[index].t.timeIntervalSince(samples[index - 1].t) / 60.0
            guard dtMin > 0, dtMin < 5 else { continue }
            let hrr = Swift.min(Swift.max((Double(samples[index].bpm) - Double(rest)) / span, 0), 1)
            total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
        }
        return LiveSessionDerived(sampleCount: samples.count,
                                  lastTimestamp: samples.last?.t,
                                  rest: rest,
                                  maxHR: maxHR,
                                  trimp: total)
    }

    private static func liveSessionTRIMP(_ samples: [HRSample], rest: Int, max: Int) -> Double {
        guard samples.count > 1, max > rest else { return 0 }
        let span = Double(max - rest)
        var total = 0.0
        for i in 1..<samples.count {
            let dtMin = samples[i].t.timeIntervalSince(samples[i - 1].t) / 60.0
            guard dtMin > 0, dtMin < 5 else { continue }
            let hrr = Swift.min(Swift.max((Double(samples[i].bpm) - Double(rest)) / span, 0), 1)
            total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
        }
        return total
    }
}

private struct AtriaBackdropLayer: View, Equatable {
    let isDark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: gradientColors,
                           startPoint: .topLeading,
                           endPoint: .bottomTrailing)

            if isDark {
                Rectangle()
                    .fill(
                        RadialGradient(colors: [accentOne, .clear],
                                       center: .topTrailing,
                                       startRadius: 18,
                                       endRadius: 210)
                    )

                Rectangle()
                    .fill(
                        RadialGradient(colors: [accentTwo, .clear],
                                       center: .bottomLeading,
                                       startRadius: 22,
                                       endRadius: 220)
                    )

                LinearGradient(colors: [
                    Color.white.opacity(0.025),
                    Color.clear,
                    Color.black.opacity(0.22)
                ], startPoint: .top, endPoint: .bottom)
            } else {
                RadialGradient(colors: [accentOne, accentOne.opacity(0.10), .clear],
                               center: .center,
                               startRadius: 12,
                               endRadius: 180)
                    .frame(width: 240, height: 240)
                    .offset(x: 74, y: -78)
            }
        }
    }

    private var gradientColors: [Color] {
        if isDark {
            return [
                Color(red: 0.018, green: 0.023, blue: 0.032),
                Color(red: 0.024, green: 0.031, blue: 0.043),
                Color(red: 0.016, green: 0.021, blue: 0.030)
            ]
        }
        return [
            Color(red: 0.95, green: 0.96, blue: 0.99),
            Color(red: 0.90, green: 0.93, blue: 0.98),
            Color(red: 0.96, green: 0.95, blue: 0.93)
        ]
    }

    private var accentOne: Color {
        isDark ? Color.cyan.opacity(0.05) : Color.white.opacity(0.36)
    }

    private var accentTwo: Color {
        Color.blue.opacity(0.04)
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
            AtriaPanelSectionHeader(title: "Heart rate", subtitle: "Live BPM without the heavy diagnostics layer")

            HStack(alignment: .firstTextBaseline) {
                Text(live.heartRateText)
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                AtriaStatusChip(text: live.contactText,
                                systemImage: live.hasContact ? "heart.fill" : "heart.slash",
                                tint: live.hasContact ? .red : .orange)
            }

            AtriaPulseSparklineHost(sparklineStore: sparklineStore)

            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "Average", value: live.averageHeartRateText)
                AtriaInlineQuickStat(label: "Peak", value: live.peakHeartRateText)
                AtriaInlineQuickStat(label: "Resting", value: restingHeartRateText)
            }
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "HRV", subtitle: "Native RR window and reference flow")
            HStack(spacing: 12) {
                AtriaInlineQuickStat(label: "Display", value: hero.hrvValue)
                AtriaInlineQuickStat(label: "RR package", value: hero.rrPackageText)
                AtriaInlineQuickStat(label: "Continuity", value: live.rrContinuityText)
            }
            Text(hero.hrvNarrative)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
    }
}

private struct AtriaRecoveryStrainCard: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Coach", subtitle: "Efficient local scoring")
            HStack(spacing: 12) {
                AtriaRecoveryMeter(estimate: hero.recoveryEstimate)
                AtriaStrainMeter(strain: hero.strain,
                                 detail: hero.strainNarrative,
                                 confidence: hero.strainConfidence)
            }
        }
        .padding(18)
        .atriaGlassPanel(emphasis: .soft)
    }
}

private struct AtriaProfileCard: View, Equatable {
    let profile: AthleteProfile
    let observedPeakHeartRateText: String
    let onUpdateProfile: (@escaping (inout AthleteProfile) -> Void) -> Void

    static func == (lhs: AtriaProfileCard, rhs: AtriaProfileCard) -> Bool {
        lhs.profile == rhs.profile
            && lhs.observedPeakHeartRateText == rhs.observedPeakHeartRateText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtriaPanelSectionHeader(title: "Profile", subtitle: "Keep HRmax and age in sync with local scoring")

            HStack(spacing: 8) {
                ForEach(AthleteProfile.HRMaxSource.allCases) { source in
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            onUpdateProfile { $0.maxHRSource = source }
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
            .atriaGlassPanel(cornerRadius: 22, emphasis: .soft)

            HStack(spacing: 12) {
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

            AtriaSummaryRow(label: "Active HRmax", value: "\(profile.maxHR)")
            AtriaSummaryRow(label: "Observed peak", value: observedPeakHeartRateText)
        }
        .padding(18)
        .atriaGlassPanel(emphasis: .soft)
    }
}

private struct AtriaInlineQuickStat: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .atriaInsetTile(cornerRadius: 16, tint: .white)
    }
}

private struct AtriaProfileStepperTile: View {
    let title: String
    let value: String
    let decrement: () -> Void
    let increment: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
            HStack(spacing: 10) {
                Button(action: decrement) {
                    Image(systemName: "minus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AtriaGlassIconSegmentStyle())

                Button(action: increment) {
                    Image(systemName: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(AtriaGlassIconSegmentStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 18, tint: .white)
    }
}

private struct AtriaHeaderTitleBlock: View, Equatable {
    let headline: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Atria")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(headline)
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.9))
                .lineLimit(2)
                .frame(maxWidth: 300, alignment: .leading)
        }
    }
}

private struct AtriaConnectedHeroPanel: View {
    let statusStore: AtriaHomeModel.StatusStore
    let liveStore: AtriaHomeModel.CoreLiveStore
    let pulseStore: AtriaHomeModel.HeroPulseStore
    let heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AtriaHeroHeadlineHost(statusStore: statusStore,
                                  heroStore: heroStore)
            AtriaHeroStatusCardLiveHost(statusStore: statusStore,
                                        liveStore: liveStore,
                                        pulseStore: pulseStore)
            AtriaHeroMetricRowHost(statusStore: statusStore,
                                   heroStore: heroStore)
            AtriaHeroNextActionHost(heroStore: heroStore)
        }
        .padding(20)
        .atriaQuietPanel(cornerRadius: 30, emphasis: .soft)
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
        case .connecting:
            return "dot.radiowaves.left.and.right"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .disconnected:
            return "bolt.horizontal.circle"
        case .poweredOff:
            return "bolt.slash.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Label("Connection", systemImage: systemImage)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .atriaGlassCapsule(tint: tint.opacity(0.82))

                Spacer(minLength: 0)

                AtriaStatusChip(text: status.rawValue,
                                systemImage: systemImage,
                                tint: tint)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(hero.guidance.headline)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .fixedSize(horizontal: false, vertical: true)
                Text(hero.guidance.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            AtriaHeroStatusTile(title: "Saved data stays ready",
                                detail: "Atria is intentionally holding the disconnected screen to a lighter native SwiftUI layout until the strap is available again.",
                                systemImage: "internaldrive.fill",
                                tint: tint)

            AtriaHeroMetricRow(liveStatus: status, hero: hero)
                .equatable()

            AtriaHeroNextActionRow(nextAction: hero.nextAction)
                .equatable()
        }
        .padding(20)
        .atriaQuietPanel(cornerRadius: 30, emphasis: .soft)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("Today", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .atriaGlassCapsule(tint: .white)
                Spacer(minLength: 0)
                AtriaStatusChip(text: status.rawValue,
                                systemImage: status == .connected ? "bolt.heart.fill" : "dot.radiowaves.left.and.right",
                                tint: heroStatusTint)
            }

            Text(guidance.headline)
                .font(.system(size: 33, weight: .bold, design: .rounded))
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.98) : Color.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(guidance.detail)
                .font(.subheadline)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.68) : .secondary)
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

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.green)
                .frame(width: 44, height: 44)
                .background(AtriaIconTileBackground(cornerRadius: 14, tint: .green))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Live pulse")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(deviceName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(heartRateText)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("bpm")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .atriaInsetTile(cornerRadius: 22, tint: .green)
    }
}

private struct AtriaHeroMetricRow: View, Equatable {
    let liveStatus: WhoopBLEManager.Status
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        HStack(spacing: 12) {
            if liveStatus == .connected {
                AtriaHeroMetricTile(title: "Recovery",
                                    value: hero.recoveryValue,
                                    detail: hero.recoveryDetail,
                                    tint: .green)
                AtriaHeroMetricTile(title: "Strain",
                                    value: hero.strainValue,
                                    detail: hero.strainDetail,
                                    tint: .orange)
                AtriaHeroMetricTile(title: "HRV",
                                    value: hero.hrvValue,
                                    detail: hero.hrvDetail,
                                    tint: .pink)
            } else {
                AtriaHeroMetricTile(title: "Sessions",
                                    value: "\(hero.sessionsCount)",
                                    detail: "saved local",
                                    tint: .cyan)
                AtriaHeroMetricTile(title: "Baseline",
                                    value: "\(hero.baselineSamples)/7",
                                    detail: "HRV samples",
                                    tint: .green)
                AtriaHeroMetricTile(title: "Backup",
                                    value: hero.backupValue,
                                    detail: hero.backupDetail,
                                    tint: .orange)
            }
        }
    }
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
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .atriaInsetTile(cornerRadius: 16, tint: .cyan)
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

    static func == (lhs: AtriaHeroMetricTile, rhs: AtriaHeroMetricTile) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 18, tint: tint)
    }
}

private struct AtriaHeroStatusTile: View, Equatable {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(AtriaIconTileBackground(cornerRadius: 14, tint: tint))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .atriaInsetTile(cornerRadius: 18, tint: tint.opacity(0.65))
    }
}

private struct AtriaOverviewLeadingSection: View {
    let heroStore: AtriaHomeModel.HeroStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool

    var body: some View {
        VStack(spacing: 18) {
            AtriaOverviewReadinessSectionHost(heroStore: heroStore,
                                              snapshotStore: snapshotStore)

            AtriaOverviewGuidanceSectionHost(heroStore: heroStore)

            if hasUnlockedSecondarySections {
                if snapshotStore.diagnosticsReady {
                    AtriaOverviewTrendSectionHost(snapshotStore: snapshotStore)
                } else {
                    AtriaLoadingPanel(title: "Warming up trends",
                                      subtitle: "Saved-session diagnostics stay off the launch path and load after the first screen is stable.")
                }
            }
        }
    }
}

private struct AtriaOverviewReadinessSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewReadinessSection(hero: heroStore.state,
                                      snapshot: snapshotStore.state)
            .equatable()
    }
}

private struct AtriaOverviewReadinessSection: View, Equatable {
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

private struct AtriaOverviewGuidanceSectionHost: View {
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore

    var body: some View {
        AtriaOverviewGuidanceSection(hero: heroStore.state)
            .equatable()
    }
}

private struct AtriaOverviewGuidanceSection: View, Equatable {
    let hero: AtriaHomeModel.HeroSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Guidance", subtitle: "Daily target from local data")
            AtriaGuidanceCard(guidance: hero.guidance, strain: hero.strain)
        }
        .padding(18)
        .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaOverviewTrendSectionHost: View {
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewTrendSection(snapshot: snapshotStore.state)
            .equatable()
    }
}

private struct AtriaOverviewTrendSection: View, Equatable {
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
        .padding(18)
        .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaOverviewTrailingSection: View {
    let liveStore: AtriaHomeModel.CoreLiveStore
    let homeStatsStore: AtriaHomeModel.HomeStatsStore
    let snapshotStore: AtriaHomeModel.SnapshotStore
    let hasUnlockedSecondarySections: Bool

    var body: some View {
        Group {
            if hasUnlockedSecondarySections && snapshotStore.diagnosticsReady {
                VStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 18) {
                        AtriaOverviewLiveStrapSectionHost(liveStore: liveStore,
                                                          homeStatsStore: homeStatsStore)

                        AtriaSectionDivider()

                        AtriaOverviewCollectionSectionHost(homeStatsStore: homeStatsStore,
                                                           snapshotStore: snapshotStore)

                        AtriaSectionDivider()

                        AtriaOverviewBackupSectionHost(homeStatsStore: homeStatsStore,
                                                       snapshotStore: snapshotStore)
                    }
                    .padding(18)
                    .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
                }
            } else {
                AtriaLoadingPanel(title: "Loading saved insights",
                                  subtitle: "Trends, backup state, and collection history are settling in the background.")
            }
        }
    }
}

private struct AtriaOverviewLiveStrapSectionHost: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore

    var body: some View {
        AtriaOverviewLiveStrapSection(live: liveStore.state,
                                      stats: homeStatsStore.state)
            .equatable()
    }
}

private struct AtriaOverviewLiveStrapSection: View, Equatable {
    let live: AtriaHomeModel.CoreLiveState
    let stats: AtriaHomeModel.HomeStatsState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Live strap", subtitle: "Fast local connection state")
            AtriaSummaryRow(label: "Status", value: live.status.rawValue)
            AtriaSummaryRow(label: "Device", value: live.deviceName)
            AtriaSummaryRow(label: "Battery", value: live.batteryText)
            AtriaSummaryRow(label: "Baseline", value: "\(stats.baselineSamples)/7 HRV samples")
            AtriaSummaryRow(label: "Sessions", value: "\(stats.sessionsCount) saved")
        }
    }
}

private struct AtriaOverviewCollectionSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewCollectionSection(stats: homeStatsStore.state,
                                       snapshot: snapshotStore.state)
            .equatable()
    }
}

private struct AtriaOverviewCollectionSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Collection", subtitle: "Capture and validation path")
            AtriaSummaryRow(label: "RR package", value: stats.rrPackageText)
            AtriaSummaryRow(label: "Reference", value: snapshot.referenceText)
            AtriaSummaryRow(label: "Workout", value: snapshot.workoutText)
            AtriaSummaryRow(label: "Logging", value: snapshot.loggingText)
        }
    }
}

private struct AtriaOverviewBackupSectionHost: View {
    @ObservedObject var homeStatsStore: AtriaHomeModel.HomeStatsStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore

    var body: some View {
        AtriaOverviewBackupSection(stats: homeStatsStore.state,
                                   snapshot: snapshotStore.state)
            .equatable()
    }
}

private struct AtriaOverviewBackupSection: View, Equatable {
    let stats: AtriaHomeModel.HomeStatsState
    let snapshot: AtriaHomeModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AtriaPanelSectionHeader(title: "Backup", subtitle: "On-device safety net")
            AtriaSummaryRow(label: "State", value: stats.backupValue)
            AtriaSummaryRow(label: "Detail", value: stats.backupDetail)
            AtriaSummaryRow(label: "Confirmed",
                            value: "\(snapshot.confirmedWorkouts) workouts · \(snapshot.confirmedSleeps) sleeps")
        }
    }
}

private struct AtriaLoadingPanel: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ProgressView()
                .tint(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .atriaQuietPanel(emphasis: .soft)
    }
}

private struct AtriaConnectionGuideContext: Equatable {
    let hasEverConnected: Bool
    let attempts: Int
    let failures: Int
    let lastStatus: String
    let lastReason: String

    var progressLabel: String {
        if hasEverConnected {
            return "Reconnect is automatic now"
        }
        if attempts == 0 {
            return "Waiting to start first handoff"
        }
        if failures == 0 {
            return "Automatic handoff in progress"
        }
        return "Still trying automatically"
    }

    var progressDetail: String {
        if hasEverConnected {
            return "Atria already owns the strap and will keep trying in the background after drops."
        }
        if attempts == 0 {
            return "As soon as the strap is free from the WHOOP app, Atria can scan, connect, and arm background logging on its own."
        }
        return "Attempt \(attempts) is the latest automatic pass. You only need to free the strap and keep the phone unlocked."
    }

    var diagnosticLabel: String {
        "last \(lastStatus) • \(lastReason.replacingOccurrences(of: "_", with: " "))"
    }
}

private struct AtriaConnectionGuideSheet: View {
    let status: WhoopBLEManager.Status
    let context: AtriaConnectionGuideContext
    let continueSetup: () -> Void
    let retry: () -> Void

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
            return "Keep the phone unlocked and the strap nearby while Atria finishes the first handoff."
        case .scanning:
            return "Atria is already scanning and will widen the search automatically if the first pass misses."
        case .poweredOff:
            return "Turn Bluetooth back on, then Atria will resume the scan without extra steps."
        case .disconnected:
            return "If WHOOP still owns the strap, disconnect it there first, then Atria can take over."
        }
    }

    private var primaryButtonTitle: String {
        switch status {
        case .scanning, .connecting:
            return "Keep setup running"
        case .poweredOff:
            return "I turned Bluetooth on"
        case .connected:
            return "Continue"
        case .disconnected:
            return "Keep automatic setup running"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("One clean handoff")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("Atria keeps reconnecting and arms background logging after the first successful take-over.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        AtriaInlineQuickStat(label: "State", value: status.rawValue)
                        AtriaInlineQuickStat(label: "Attempts", value: "\(max(context.attempts, 1))")
                        AtriaInlineQuickStat(label: "Mode", value: "Automatic")
                    }

                    AtriaConnectionStatusCard(title: setupStateTitle,
                                              detail: setupStateDetail,
                                              status: status)

                    AtriaConnectionChecklistCard(
                        title: "Before Atria takes over",
                        items: [
                            "Open the official WHOOP app and disconnect the strap there if it is still attached.",
                            "Fully quit the WHOOP app so it does not grab the strap in the background.",
                            "Leave Atria open, keep the phone unlocked, and wake the strap by wearing or tapping it."
                        ],
                        tint: .orange
                    )

                    AtriaConnectionChecklistCard(
                        title: "What happens automatically",
                        items: [
                            "Starts scanning automatically when Bluetooth is ready.",
                            "Retries with a wider search if the first filtered scan misses the strap.",
                            "Keeps reconnecting after drops so you do not need to keep tapping Connect.",
                            "Arms long-wear background checkpoints after the strap is owned by Atria."
                        ],
                        tint: .cyan
                    )

                    AtriaConnectionChecklistCard(
                        title: context.progressLabel,
                        items: [
                            context.progressDetail,
                            "Diagnostics: \(context.diagnosticLabel)",
                            "If WHOOP was just disconnected, give Atria a few seconds before forcing another retry."
                        ],
                        tint: .green
                    )
                }
                .padding(20)
            }
            .background(AtriaBackdropLayer(isDark: true).ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(primaryButtonTitle, action: continueSetup)
                        .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .blue))
                    Button("Retry scan now", action: retry)
                        .buttonStyle(AtriaGlassCapsuleButtonStyle(tint: .gray))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .background(AtriaSheetFooterBackground())
            }
        }
    }
}

private struct AtriaConnectionGuideSheetHost: View {
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

private struct AtriaHomeObservers: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var snapshotStore: AtriaHomeModel.SnapshotStore
    let onStatusChange: (WhoopBLEManager.Status) -> Void
    let onDiagnosticsReady: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: statusStore.state.status) { _, status in
                onStatusChange(status)
            }
            .onChange(of: snapshotStore.diagnosticsReady) { _, ready in
                guard ready else { return }
                onDiagnosticsReady()
            }
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
        .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
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
        .atriaQuietPanel(cornerRadius: 24, emphasis: .soft)
    }
}

private struct AtriaPanelSectionHeader: View, Equatable {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension WhoopBLEManager.Status {
    var logToken: String {
        switch self {
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .poweredOff:
            return "powered_off"
        case .scanning:
            return "scanning"
        }
    }
}

private struct AtriaQuickTile: View, Equatable {
    let title: String
    let value: String
    let detail: String
    let system: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaQuickTile, rhs: AtriaQuickTile) -> Bool {
        lhs.title == rhs.title
            && lhs.value == rhs.value
            && lhs.detail == rhs.detail
            && lhs.system == rhs.system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: system)
                .font(.caption.weight(.semibold))
                .foregroundStyle(colorScheme == .dark ? tint.opacity(0.95) : tint)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
            Text(detail)
                .font(.caption)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.66) : .secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 18, tint: tint)
    }
}

private struct AtriaGuidanceCard: View, Equatable {
    let guidance: Coach.Guidance
    let strain: Double

    private var tint: Color { guidance.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint)
                    .frame(width: 9, height: 9)
                Text(guidance.headline)
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 0)
                Text(targetLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(guidance.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 10)

                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(20, 240 * CGFloat(min(max(strain / 21, 0), 1))), height: 10)

                    if let target = guidance.target {
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.72))
                            .frame(width: 3, height: 16)
                            .offset(x: 240 * CGFloat(min(max(target / 21, 0), 1)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Text("strain \(String(format: "%.1f", strain))")
                        .font(.caption.monospacedDigit())
                    Spacer(minLength: 0)
                    Text("0-21 local scale")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .atriaInsetTile(cornerRadius: 18, tint: tint)
        }
    }

    private var targetLabel: String {
        if let target = guidance.target {
            return "target \(String(format: "%.1f", target))"
        }
        return guidance.state
    }
}

private struct AtriaRecoveryMeter: View, Equatable {
    let estimate: Metrics.RecoveryEstimate

    private var tint: Color {
        guard let percent = estimate.percent else { return .orange }
        return Metrics.recoveryColor(percent)
    }

    private var fillFraction: CGFloat {
        guard let percent = estimate.percent else { return 0.16 }
        return CGFloat(min(max(Double(percent) / 100.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recovery", systemImage: "gauge.with.dots.needle.bottom.50percent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(estimate.percent.map { "\($0)%" } ?? "Learning")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(estimate.confidence.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(estimate.confidence == .high ? .green : .orange)

            Text(estimate.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 20, tint: .green)
    }
}

private struct AtriaStrainMeter: View, Equatable {
    let strain: Double
    let detail: String
    let confidence: String

    private var tint: Color {
        Metrics.strainColor(strain)
    }

    private var fillFraction: CGFloat {
        CGFloat(min(max(strain / 21.0, 0), 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Day strain", systemImage: "flame.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)

            Text(String(format: "%.1f", strain))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()

            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: max(18, 120 * fillFraction), height: 8)
                }

            Text(confidence)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(confidence == "local" ? .green : .orange)

            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .atriaInsetTile(cornerRadius: 20, tint: .orange)
    }
}

private struct AtriaSummaryRow: View, Equatable {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

private struct AtriaStatusChip: View, Equatable {
    let text: String
    let systemImage: String
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: AtriaStatusChip, rhs: AtriaStatusChip) -> Bool {
        lhs.text == rhs.text && lhs.systemImage == rhs.systemImage
    }

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(colorScheme == .dark ? tint.opacity(0.98) : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .atriaGlassCapsule(tint: tint)
    }
}

private struct AtriaSectionDivider: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24))
            .frame(height: 1)
    }
}

private struct AtriaGlassCapsuleButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.92 : 1))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .atriaGlassCapsule(tint: tint)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

private struct AtriaGlassIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.92 : 1))
            .atraGlassIconChrome()
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private struct AtriaSegmentButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.primary.opacity(colorScheme == .dark ? 0.98 : 0.96) : Color.secondary.opacity(colorScheme == .dark ? 0.88 : 0.92))
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(selectedFill)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.48), lineWidth: 1)
                        }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }

    private var selectedFill: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.112, green: 0.126, blue: 0.158).opacity(0.98)
            )
        }
        return AnyShapeStyle(
            LinearGradient(colors: [
                Color.white.opacity(0.70),
                Color.white.opacity(0.42)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }
}

private struct AtriaGlassIconSegmentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .padding(.vertical, 10)
            .foregroundStyle(Color.primary.opacity(configuration.isPressed ? 0.88 : 1))
            .background {
                AtriaInsetTileBackground(cornerRadius: 14, tint: .white)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private enum AtriaPanelEmphasis {
    case soft
    case strong
}

private struct AtriaQuietPanelBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(strokeShape)
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.060, green: 0.071, blue: 0.092)
                    .opacity(emphasis == .strong ? 0.985 : 0.965)
            )
        }
        return AnyShapeStyle(
            LinearGradient(colors: [
                Color.white.opacity(emphasis == .strong ? 0.96 : 0.92),
                Color(red: 0.948, green: 0.958, blue: 0.982).opacity(emphasis == .strong ? 0.94 : 0.90)
            ], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    Color.white.opacity(emphasis == .strong ? 0.018 : 0.010)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.22 : 0.14),
                        Color.blue.opacity(0.018),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(emphasis == .strong ? 0.06 : 0.045)
                                         : Color.white.opacity(emphasis == .strong ? 0.52 : 0.34),
                    lineWidth: 1)
    }
}

private struct AtriaGlassPanelBackground: View {
    let cornerRadius: CGFloat
    let emphasis: AtriaPanelEmphasis

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(strokeShape)
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.074, green: 0.088, blue: 0.116)
                    .opacity(emphasis == .strong ? 0.975 : 0.95)
            )
        }
        return AnyShapeStyle(
            emphasis == .strong ? .regularMaterial : .thinMaterial
        )
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.028 : 0.018),
                        Color.cyan.opacity(emphasis == .strong ? 0.016 : 0.008),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        Color.white.opacity(emphasis == .strong ? 0.16 : 0.10),
                        Color.blue.opacity(0.025),
                        Color.clear
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    @ViewBuilder
    private var strokeShape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(colorScheme == .dark ? Color.white.opacity(emphasis == .strong ? 0.08 : 0.055)
                                         : Color.white.opacity(emphasis == .strong ? 0.28 : 0.18),
                    lineWidth: 1)
    }
}

private struct AtriaInsetTileBackground: View {
    let cornerRadius: CGFloat
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.10), lineWidth: 1)
            )
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.085, green: 0.097, blue: 0.126).opacity(0.955)
            )
        }
        return AnyShapeStyle(
            .ultraThinMaterial
        )
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accentTint.opacity(0.028))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(colors: [
                        tint.opacity(0.045),
                        Color.white.opacity(0.02)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
    }

    private var accentTint: Color {
        if tint == .white {
            return Color(red: 0.52, green: 0.76, blue: 0.98)
        }
        return tint
    }
}

private struct AtriaIconTileBackground: View {
    let cornerRadius: CGFloat
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(baseFill)
            .overlay(tintWash)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14), lineWidth: 1)
            }
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.092, green: 0.104, blue: 0.132).opacity(0.97)
            )
        }
        return AnyShapeStyle(
            .ultraThinMaterial
        )
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(accentTint.opacity(0.035))
        } else {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(tint.opacity(0.06))
        }
    }

    private var accentTint: Color {
        if tint == .white {
            return Color(red: 0.55, green: 0.78, blue: 0.98)
        }
        return tint
    }
}

private struct AtriaChecklistBadgeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(
                LinearGradient(colors: [
                    colorScheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.80),
                    colorScheme == .dark ? tint.opacity(0.16) : tint.opacity(0.10)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
    }
}

private struct AtriaSheetFooterBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(
                colorScheme == .dark
                    ? AnyShapeStyle(Color(red: 0.040, green: 0.048, blue: 0.066).opacity(0.98))
                    : AnyShapeStyle(.thinMaterial)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.14))
                    .frame(height: 1)
            }
    }
}

private extension View {
    @ViewBuilder
    func atriaGlassPanel(cornerRadius: CGFloat = 28,
                         emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaGlassPanelBackground(cornerRadius: cornerRadius, emphasis: emphasis)
            }
    }

    @ViewBuilder
    func atriaQuietPanel(cornerRadius: CGFloat = 28,
                         emphasis: AtriaPanelEmphasis = .soft) -> some View {
        self
            .background {
                AtriaQuietPanelBackground(cornerRadius: cornerRadius, emphasis: emphasis)
            }
    }

    @ViewBuilder
    func atriaGlassCapsule(tint: Color) -> some View {
        self.background(AtriaCapsuleChromeBackground(tint: tint))
    }

    func atraGlassIconChrome() -> some View {
        self
            .padding(12)
            .frame(width: 46, height: 46)
            .background(AtriaIconChromeBackground())
    }

    func atriaInsetTile(cornerRadius: CGFloat = 18, tint: Color) -> some View {
        self
            .background {
                AtriaInsetTileBackground(cornerRadius: cornerRadius, tint: tint)
            }
    }
}

private struct AtriaCapsuleChromeBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Capsule(style: .continuous)
                    .fill(baseFill)
                    .glassEffect(.regular.tint(glassTint).interactive(), in: .capsule)
                    .overlay(stroke)
            } else {
                Capsule(style: .continuous)
                    .fill(baseFill)
                    .overlay(stroke)
            }
        }
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.084, green: 0.095, blue: 0.124).opacity(0.96)
            )
        }
        return AnyShapeStyle(
            .ultraThinMaterial
        )
    }

    private var glassTint: Color {
        colorScheme == .dark ? effectiveTint.opacity(0.025) : tint.opacity(0.12)
    }

    private var stroke: some View {
        Capsule(style: .continuous)
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.16), lineWidth: 1)
    }

    private var effectiveTint: Color {
        if tint == .gray {
            return Color.white
        }
        return tint
    }
}

private struct AtriaIconChromeBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Circle()
                    .fill(baseFill)
                    .glassEffect(.regular.tint(colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.16)).interactive(), in: .circle)
                    .overlay(stroke)
            } else {
                Circle()
                    .fill(baseFill)
                    .overlay(tintWash)
                    .overlay(stroke)
            }
        }
    }

    private var baseFill: some ShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(
                Color(red: 0.086, green: 0.098, blue: 0.126).opacity(0.97)
            )
        }
        return AnyShapeStyle(
            .ultraThinMaterial
        )
    }

    @ViewBuilder
    private var tintWash: some View {
        if colorScheme == .dark {
            Circle()
                .fill(
                    Color.white.opacity(0.016)
                )
        }
    }

    private var stroke: some View {
        Circle()
            .stroke(Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18), lineWidth: 1)
    }
}
