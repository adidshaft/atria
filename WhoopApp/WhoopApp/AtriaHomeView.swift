import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

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
    private enum HomeTab: String, CaseIterable, Identifiable {
        case overview
        case vitals
        case collection

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .vitals: return "Vitals"
            case .collection: return "Data"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "house.fill"
            case .vitals: return "heart.text.square"
            case .collection: return "waveform.badge.magnifyingglass"
            }
        }
    }

    let ble: WhoopBLEManager
    let store: SessionStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var model: AtriaHomeModel
    @State private var selectedTab: HomeTab = .overview
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
    @State private var showSettings = false
    @State private var showCoexistenceModal = false
    @State private var coexistenceSnoozedUntil: Date?
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
    @State private var entitlements = AtriaEntitlements()
    @State private var hapticSettings = AtriaHapticAlertSettings.load()
    @State private var hapticCoordinator = AtriaHapticAlertCoordinator()
    @StateObject private var mediaController = AtriaMediaController()
    @State private var liveActivityCoordinator = AtriaLiveActivityCoordinator()
    @State private var aiCoachSettings = AtriaAICoachSettings.load()
    @State private var aiCoachHasAPIKey = false
    @State private var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState
    @State private var standByDismissedUntil: Date?
    @State private var missedDataBannerDismissedUntil: Date?
    @State private var developerModeEnabled = AtriaDeveloperMode.isEnabled

    init(ble: WhoopBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        _model = State(initialValue: AtriaHomeModel(ble: ble, store: store))
    }

    var body: some View {
        ZStack {
            AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TabView(selection: $selectedTab) {
                Tab("Today", systemImage: "house.fill", value: HomeTab.overview) {
                    tabNavigation(title: "Today") {
                        if hasUnlockedPrimaryContent {
                            overviewContent
                        } else {
                            secondaryLoadingCard(title: "Preparing overview",
                                                 subtitle: "Getting the first live readout on screen before the deeper cards load.")
                        }
                    }
                }

                Tab("Vitals", systemImage: "heart.text.square", value: HomeTab.vitals) {
                    tabNavigation(title: "Vitals") {
                        vitalsContent
                    }
                }

                Tab("Data", systemImage: "waveform.badge.magnifyingglass", value: HomeTab.collection) {
                    tabNavigation(title: "Data") {
                        collectionContent
                    }
                }
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory) {
                AtriaLiveTabAccessory(liveStore: model.coreLiveStore)
            }

            AtriaHomeObservers(statusStore: model.statusStore,
                               snapshotStore: model.snapshotStore) { status in
                handleStatusChange(status)
            } onDiagnosticsReady: {
                overviewDiagnosticsKickoffTask?.cancel()
                overviewDiagnosticsKickoffTask = nil
                logDiagnosticsReadyIfNeeded()
            }

            GeometryReader { proxy in
                let isLandscape = proxy.size.width > proxy.size.height
                if shouldShowStandBy(isLandscape: isLandscape) {
                    AtriaStandByOverlay(coreLiveStore: model.coreLiveStore,
                                        pulseLiveStore: model.pulseLiveStore,
                                        heroStore: model.heroStore) {
                        standByDismissedUntil = Date().addingTimeInterval(20 * 60)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }
            }
            .ignoresSafeArea()
        }
        .environment(\.atriaEntitlements, entitlements)
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
        .sheet(isPresented: $showSettings) {
            AtriaSettingsView(profile: model.profileStore.profile,
                              restingBaseline: store.baseline.restingInt,
                              onUpdateProfile: store.updateProfile,
                              hapticSettings: hapticSettings,
                              onUpdateHaptics: { hapticSettings = $0 },
                              onExportHealth: { store.exportToHealthKit() },
                              onSyncMissedData: {
                                  _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "manual_user_request",
                                                                              force: true)
                              })
        }
        .sheet(isPresented: $showCoexistenceModal) {
            AtriaWhoopCoexistenceModal(context: connectionGuideContext) {
                acknowledgeCoexistenceModal(reason: "button")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onReceive(ble.$officialWhoopCoexistenceRisk.removeDuplicates()) { risk in
            presentCoexistenceModalIfNeeded(for: risk)
        }
        .onAppear {
            applyDebugUIScreenLaunchArgumentIfNeeded()
            presentCoexistenceModalIfNeeded(for: ble.officialWhoopCoexistenceRisk)
            guard !hasUnlockedPrimaryContent else { return }
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryState = UIDevice.current.batteryState
            if homeAppearedAt == nil {
                homeAppearedAt = Date()
            }
            ble.setForegroundHighFrequencyDisplayMode(selectedTab == .vitals)
            model.setPulseDetailMode(active: selectedTab == .vitals)
            consumePendingIntentCommandIfNeeded()
            refreshAICoachKeyState()
            runCoexistenceSnoozeSelfTestIfRequested()
            updateMediaRefreshLoop()
            updateLiveActivity()
            updateHapticCoordinator()
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
        .onChange(of: scenePhase) { _, phase in
            updateMediaRefreshLoop()
            guard phase == .active else { return }
            consumePendingIntentCommandIfNeeded()
            refreshAICoachKeyState()
            updateHapticCoordinator()
        }
        .onChange(of: hapticSettings) { _, settings in
            settings.save()
            updateHapticCoordinator()
        }
        .onChange(of: aiCoachSettings) { _, settings in
            settings.save()
            refreshAICoachKeyState()
        }
        .onReceive(liveSideEffectUpdates) { _ in
            updateLiveActivity()
            updateHapticCoordinator()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryState = UIDevice.current.batteryState
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
            mediaController.setRefreshLoopActive(false)
        }
    }

    private var contentWidth: CGFloat {
        horizontalSizeClass == .regular ? 1120 : 720
    }

    private var shouldShowLiveAccessory: Bool {
        model.statusStore.state.status == .connected
            && model.coreLiveStore.state.status == .connected
    }

    private var liveSideEffectUpdates: AnyPublisher<Void, Never> {
        Publishers.MergeMany([
            model.coreLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.pulseLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.collectionLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.heroStore.$state.map { _ in () }.eraseToAnyPublisher(),
            mediaController.$state.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
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

    private func consumePendingIntentCommandIfNeeded() {
        guard let command = AtriaIntentCommandStore.consume() else { return }
        switch command {
        case .open(let destination):
            performMotionAwareUpdate {
                switch destination {
                case .today:
                    selectedTab = .overview
                case .vitals:
                    selectedTab = .vitals
                case .collection:
                    selectedTab = .collection
                }
            }
        case .capture(let command):
            if command == .start && !ble.isRecording {
                ble.toggleRecording()
            } else if command == .stop && ble.isRecording {
                ble.toggleRecording()
            }
            performMotionAwareUpdate {
                selectedTab = .collection
            }
        case .focus(let mode):
            AtriaIntentCommandStore.persistFocusMode(mode)
            let rest = model.homeStatsStore.state.restingHeartRate
            let maxHR = model.profileStore.profile.maxHR
            switch mode {
            case .off:
                ble.setLongWearModeEnabled(false, rest: rest, maxHR: maxHR)
            case .workout:
                ble.setCollectionProfile(.maxCoverage, rest: rest, maxHR: maxHR)
                ble.setLongWearModeEnabled(true, rest: rest, maxHR: maxHR)
            case .sleep:
                ble.setCollectionProfile(.batterySaver, rest: rest, maxHR: maxHR)
                ble.setLongWearModeEnabled(true, rest: rest, maxHR: maxHR)
            }
            performMotionAwareUpdate {
                selectedTab = .collection
            }
        }
    }

    private func applyDebugUIScreenLaunchArgumentIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard let screenIndex = arguments.firstIndex(of: "--atria-ui-screen"),
              arguments.indices.contains(arguments.index(after: screenIndex)) else {
            return
        }

        let requestedScreen = arguments[arguments.index(after: screenIndex)].lowercased()
        hasUnlockedPrimaryContent = true
        hasUnlockedSecondarySections = true
        switch requestedScreen {
        case "today", "overview":
            selectedTab = .overview
        case "vitals":
            selectedTab = .vitals
        case "data", "collection":
            selectedTab = .collection
            model.loadDeferredDiagnosticsIfNeeded(reason: "debug_ui_screen")
        case "settings":
            selectedTab = .overview
            showSettings = true
        default:
            break
        }
#endif
    }

    private func performMotionAwareUpdate(_ update: () -> Void) {
        if reduceMotion {
            update()
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                update()
            }
        }
    }

    private func updateHapticCoordinator() {
        hapticCoordinator.update(AtriaHapticAlertCoordinator.Snapshot(
            status: model.coreLiveStore.state.status,
            isRecording: model.collectionLiveStore.state.isRecording,
            heartRate: model.pulseLiveStore.state.heartRate,
            maxHR: model.profileStore.profile.maxHR,
            batteryLevel: model.coreLiveStore.state.batteryLevel,
            recoveryPercent: model.heroStore.state.recoveryEstimate.percent,
            strain: model.heroStore.state.strain,
            strainTarget: model.heroStore.state.guidance.target,
            settings: hapticSettings
        ))
    }

    private func updateLiveActivity() {
        liveActivityCoordinator.update(AtriaLiveActivityCoordinator.Snapshot(
            isRecording: model.collectionLiveStore.state.isRecording,
            heartRate: model.pulseLiveStore.state.heartRate,
            strain: Metrics.strain(fromTRIMP: model.coreLiveStore.state.liveTRIMP),
            batteryLevel: model.coreLiveStore.state.batteryLevel,
            readingCount: model.coreLiveStore.state.sessionSampleCount,
            mediaTitle: mediaController.state.title,
            mediaArtist: mediaController.state.artist,
            mediaIsPlaying: mediaController.state.isPlaying,
            mediaHasNowPlayingInfo: mediaController.state.hasNowPlayingInfo
        ))
    }

    private func updateMediaRefreshLoop() {
        let isActive = scenePhase == .active
        let isConnected = model.coreLiveStore.state.status == .connected
        mediaController.setRefreshLoopActive(isActive && isConnected)
    }

    private func refreshAICoachKeyState() {
        aiCoachHasAPIKey = AtriaCoachKeychain.hasAPIKey(provider: aiCoachSettings.cloudProvider)
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private func shouldShowStandBy(isLandscape: Bool) -> Bool {
        guard isLandscape else { return false }
        guard model.coreLiveStore.state.status == .connected else { return false }
        guard batteryState == .charging || batteryState == .full else { return false }
        if let standByDismissedUntil, standByDismissedUntil > Date() {
            return false
        }
        return true
    }

    private func tabNavigation<Content: View>(title: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    hero
                    content()
                }
                .frame(maxWidth: contentWidth)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(title)
            .toolbar {
                toolbarContent
            }
        }
    }

    private var hero: some View {
        AtriaHeroPanelHost(statusStore: model.statusStore,
                           liveStore: model.coreLiveStore,
                           heroStore: model.heroStore,
                           pulseStore: model.heroPulseStore)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Single connection-status indicator for the whole screen, colored by
        // state and tappable to scan when not connected.
        ToolbarItem(placement: .topBarLeading) {
            // A non-button styled chip so iOS 26 doesn't collapse it to an
            // icon-only glass circle. Single connection-status indicator,
            // colored by state, tappable to scan when not connected.
            HStack(spacing: 5) {
                Image(systemName: statusSymbol)
                    .imageScale(.small)
                Text(statusShortLabel)
            }
            .font(.caption.weight(.bold))
            .foregroundStyle(statusChipForeground)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AtriaLiquidStatusPillBackground(tint: statusTint))
            .fixedSize()
            .contentShape(.capsule)
            .onTapGesture {
                if model.statusStore.state.status != .connected {
                    ble.startScan(reason: "home_status_chip")
                }
            }
            .accessibilityLabel("Connection \(statusShortLabel)")
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if model.statusStore.state.status != .connected {
                Button {
                    connectionGuideSnoozedUntil = nil
                    showConnectionGuide = true
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .accessibilityLabel("Connection help")
            }

            NavigationLink {
                HistoryView(store: store)
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .accessibilityLabel("History")

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    private var statusShortLabel: String {
        switch model.statusStore.state.status {
        case .connected: return "Live"
        case .connecting: return "Connecting"
        case .scanning: return "Searching"
        case .poweredOff: return "Bluetooth off"
        case .disconnected: return "Disconnected"
        }
    }

    private var statusSymbol: String {
        switch model.statusStore.state.status {
        case .connected: return "bolt.heart.fill"
        case .connecting, .scanning: return "dot.radiowaves.left.and.right"
        case .poweredOff: return "bolt.slash.fill"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    private var statusTint: Color {
        switch model.statusStore.state.status {
        case .connected: return .green
        case .connecting, .scanning: return .orange
        case .poweredOff: return .red
        case .disconnected: return .blue
        }
    }

    private var statusChipForeground: Color {
        switch model.statusStore.state.status {
        case .connected: return Color(red: 0.77, green: 1.00, blue: 0.86)
        case .connecting, .scanning: return Color(red: 1.00, green: 0.87, blue: 0.62)
        case .poweredOff: return Color(red: 1.00, green: 0.72, blue: 0.72)
        case .disconnected: return Color(red: 0.42, green: 0.82, blue: 1.00)
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 18) {
            if shouldShowMissedDataBanner {
                AtriaMissedDataBanner {
                    missedDataBannerDismissedUntil = Date().addingTimeInterval(60 * 60)
                } onSync: {
                    missedDataBannerDismissedUntil = nil
                    _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "home_missed_data_banner",
                                                                 force: true)
                }
            }

            AtriaOverviewTabContent(statusStore: model.statusStore,
                                    liveStore: model.coreLiveStore,
                                    heroStore: model.heroStore,
                                    homeStatsStore: model.homeStatsStore,
                                    snapshotStore: model.snapshotStore,
                                    store: store,
                                    hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                    aiCoachSettings: aiCoachSettings,
                                    aiCoachHasAPIKey: aiCoachHasAPIKey,
                                    horizontalSizeClass: horizontalSizeClass,
                                    connectionContext: connectionGuideContext,
                                    onAICoachSettingsChange: { settings in
                                        aiCoachSettings = settings
                                    },
                                    onSaveAICoachAPIKey: { key in
                                        AtriaCoachKeychain.saveAPIKey(key, provider: aiCoachSettings.cloudProvider)
                                        refreshAICoachKeyState()
                                    },
                                    onDeleteAICoachAPIKey: {
                                        AtriaCoachKeychain.deleteAPIKey(provider: aiCoachSettings.cloudProvider)
                                        refreshAICoachKeyState()
                                    },
                                    onShowConnectionGuide: {
                                        connectionGuideSnoozedUntil = nil
                                        showConnectionGuide = true
                                    },
                                    onOpenVitals: {
                                        performMotionAwareUpdate {
                                            selectedTab = .vitals
                                        }
                                    },
                                    onOpenCollection: {
                                        performMotionAwareUpdate {
                                            selectedTab = .collection
                                        }
                                    })
        }
    }

    private var shouldShowMissedDataBanner: Bool {
        guard model.collectionLiveStore.state.rangeLossBackfillPending else { return false }
        guard showsMissedDataBannerForCurrentStatus else { return false }
        guard selectedTab == .overview else { return false }
        if let missedDataBannerDismissedUntil, missedDataBannerDismissedUntil > Date() {
            return false
        }
        return true
    }

    private var showsMissedDataBannerForCurrentStatus: Bool {
        switch model.statusStore.state.status {
        case .disconnected, .poweredOff:
            return model.coreLiveStore.state.sessionSampleCount == 0
        case .connected, .connecting, .scanning:
            return false
        }
    }

    private func presentCoexistenceModalIfNeeded(for risk: WhoopBLEManager.OfficialWhoopCoexistenceRisk) {
        guard risk == .suspected else { return }
        Task { @MainActor in
            await Task.yield()
            let snoozed = coexistenceSnoozedUntil.map { Date() < $0 } ?? false
            if !snoozed, !showCoexistenceModal {
                showCoexistenceModal = true
            }
        }
    }

    private func acknowledgeCoexistenceModal(reason: String) {
        coexistenceSnoozedUntil = Date().addingTimeInterval(60 * 60)
        showCoexistenceModal = false
        recordCoexistenceSnoozeVerification(status: "acknowledged", reason: reason)
    }

    private func runCoexistenceSnoozeSelfTestIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--whoop-verify-coexistence-snooze") else { return }
        showCoexistenceModal = true
        acknowledgeCoexistenceModal(reason: "debug_launch_arg")
        presentCoexistenceModalIfNeeded(for: .suspected)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            let snoozed = coexistenceSnoozedUntil.map { Date() < $0 } ?? false
            let passed = snoozed && !showCoexistenceModal
            recordCoexistenceSnoozeVerification(status: passed ? "pass" : "fail",
                                                reason: "debug_launch_arg")
        }
#endif
    }

    private func recordCoexistenceSnoozeVerification(status: String, reason: String) {
#if DEBUG
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: "whoop.link.coexistenceSnoozeVerificationStatus")
        defaults.set(reason, forKey: "whoop.link.coexistenceSnoozeVerificationReason")
        defaults.set(Date().timeIntervalSince1970, forKey: "whoop.link.coexistenceSnoozeVerificationAt")
#endif
    }

    private var vitalsContent: some View {
        AtriaVitalsTabContent(liveStore: model.coreLiveStore,
                              pulseStore: model.pulseLiveStore,
                              pulseSparklineStore: model.pulseSparklineStore,
                              heroStore: model.heroStore,
                              homeStatsStore: model.homeStatsStore,
                              profileStore: model.profileStore,
                              profileMetricsStore: model.profileMetricsStore,
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
                                  hrImportStatus: $hrImportStatus,
                                  hapticSettings: $hapticSettings,
                                  developerModeEnabled: developerModeEnabled)
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
        .atriaCard(emphasis: .soft)
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
        updateMediaRefreshLoop()
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
            lastReason: defaults.string(forKey: WhoopBLEManager.LinkDefaults.lastReason) ?? "waiting",
            officialWhoopCoexistenceRisk: model.statusStore.state.officialWhoopCoexistenceRisk
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

private struct AtriaLiquidStatusPillBackground: View {
    let tint: Color

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule(style: .continuous)
            .fill(baseFill)
            .overlay {
                Capsule(style: .continuous)
                    .fill(liquidWash)
                    .blendMode(colorScheme == .dark ? .screen : .plusLighter)
                    .opacity(colorScheme == .dark ? 0.62 : 0.38)
            }
            .overlay(alignment: .topLeading) {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.26 : 0.58),
                            .clear
                        ], startPoint: .topLeading, endPoint: .center)
                    )
                    .padding(1)
                    .opacity(0.7)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(borderGradient, lineWidth: 1)
            }
            .shadow(color: tint.opacity(colorScheme == .dark ? 0.30 : 0.18),
                    radius: 10,
                    x: 0,
                    y: 4)
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.10),
                    radius: 8,
                    x: 0,
                    y: 2)
    }

    private var baseFill: AnyShapeStyle {
        colorScheme == .dark
            ? AnyShapeStyle(Color(red: 0.035, green: 0.045, blue: 0.058).opacity(0.94))
            : AnyShapeStyle(Color.white.opacity(0.78))
    }

    private var liquidWash: LinearGradient {
        LinearGradient(colors: [
            tint.opacity(colorScheme == .dark ? 0.34 : 0.28),
            tint.opacity(colorScheme == .dark ? 0.12 : 0.14),
            Color.white.opacity(colorScheme == .dark ? 0.08 : 0.24)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var borderGradient: LinearGradient {
        LinearGradient(colors: [
            tint.opacity(0.95),
            tint.opacity(colorScheme == .dark ? 0.42 : 0.30),
            Color.white.opacity(colorScheme == .dark ? 0.12 : 0.70)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct AtriaMissedDataBanner: View, Equatable {
    let onDismiss: () -> Void
    let onSync: () -> Void

    static func == (lhs: AtriaMissedDataBanner, rhs: AtriaMissedDataBanner) -> Bool {
        true
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: .cyan))

            VStack(alignment: .leading, spacing: 3) {
                Text("New data on your strap")
                    .font(.subheadline.weight(.semibold))
                Text("Sync missed data when you are ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button("Sync", action: onSync)
                .font(.caption.weight(.bold))
                .buttonStyle(.glassProminent)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Dismiss missed data banner")
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
    }
}

private struct AtriaLiveTabAccessory: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        HStack(spacing: isInline ? 8 : 12) {
            Image(systemName: "heart.fill")
                .font(isInline ? .caption.weight(.bold) : .subheadline.weight(.bold))
                .foregroundStyle(.red)

            Text(liveStore.state.sessionSampleCount > 0 ? "\(liveStore.state.sessionSampleCount)" : "Live")
                .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                .monospacedDigit()

            Text(sampleLabel)
                .font(isInline ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !isInline {
                Spacer(minLength: 0)
                Label(liveStore.state.batteryText, systemImage: "battery.100")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .padding(.horizontal, isInline ? 8 : 12)
        .padding(.vertical, isInline ? 4 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live strap connected. \(liveStore.state.sessionSampleCount) \(sampleLabel). Battery \(liveStore.state.batteryText). \(liveStore.state.rrContinuityText).")
    }

    private var sampleLabel: String {
        switch liveStore.state.sessionSampleCount {
        case 0:
            return "connected"
        case 1:
            return "sample"
        default:
            return "samples"
        }
    }
}

private struct AtriaStandByOverlay: View {
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    @ObservedObject var heroStore: AtriaHomeModel.HeroStore
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(.green)
                            .frame(width: 10, height: 10)
                        Text(coreLiveStore.state.deviceName.isEmpty ? "Atria live" : coreLiveStore.state.deviceName)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }

                    Text(pulseLiveStore.state.heartRateText)
                        .font(.system(size: 118, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.7)

                    Text(pulseLiveStore.state.hasContact ? "BPM live" : "BPM waiting")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 14) {
                    AtriaStandByMetric(title: "Recovery",
                                       value: heroStore.state.recoveryValue,
                                       detail: heroStore.state.recoveryEstimate.confidence.rawValue,
                                       tint: .green)
                    AtriaStandByMetric(title: "Strain",
                                       value: String(format: "%.1f", heroStore.state.strain),
                                       detail: heroStore.state.strainConfidence,
                                       tint: .orange)
                    AtriaStandByMetric(title: "Battery",
                                       value: coreLiveStore.state.batteryText,
                                       detail: coreLiveStore.state.rrContinuityText,
                                       tint: .cyan)
                }
                .frame(width: 230)
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 34)

            VStack {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .accessibilityLabel("Dismiss StandBy view")
                }
                Spacer()
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct AtriaStandByMetric: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.08))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

@MainActor
final class AtriaHomeModel {
    struct StatusState: Equatable {
        var status: WhoopBLEManager.Status
        var officialWhoopCoexistenceRisk: WhoopBLEManager.OfficialWhoopCoexistenceRisk
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
        var rangeLossBackfillPending: Bool
        var collectionProfile: WhoopBLEManager.CollectionProfile
        var officialWhoopCoexistenceRisk: WhoopBLEManager.OfficialWhoopCoexistenceRisk

        var recordingState: String { isRecording ? "Recording" : (captureWasValidationReady ? "Ready" : "Idle") }
        var captureFileLabel: String { lastCaptureFile.isEmpty ? "None" : "Saved" }
        var modeLabel: String {
            longWearModeEnabled ? "Long wear" : collectionProfile.label
        }
        var coexistenceStatusText: String { officialWhoopCoexistenceRisk.label }
    }

    struct HeroSnapshot: Equatable {
        let recoveryEstimate: Metrics.RecoveryEstimate
        let strain: Double
        let strainConfidence: String
        let guidance: Coach.Guidance
        let hrvValue: String
        let hrvDetail: String
        let hrvNarrative: String
        let stressValue: String
        let stressDetail: String
        let stressNarrative: String
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
        let loadRatioText: String
        let loadTargetText: String
        let loadConfidence: String
        let loadNarrative: String

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
                && lhs.stressValue == rhs.stressValue
                && lhs.stressDetail == rhs.stressDetail
                && lhs.stressNarrative == rhs.stressNarrative
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
                && lhs.loadRatioText == rhs.loadRatioText
                && lhs.loadTargetText == rhs.loadTargetText
                && lhs.loadConfidence == rhs.loadConfidence
                && lhs.loadNarrative == rhs.loadNarrative
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

    struct ProfileMetricsState: Equatable {
        let vo2MaxEstimate: VO2MaxEstimateSummary
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

    final class ProfileMetricsStore: ObservableObject {
        @Published fileprivate(set) var state: ProfileMetricsState

        init(state: ProfileMetricsState) {
            self.state = state
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
    let profileMetricsStore: ProfileMetricsStore

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
    private var diagnosticsWorkInFlight = false
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
                                                      sleepValue: "Preparing",
                                                      sleepDetail: "saved history",
                                                      workoutText: "Preparing",
                                                      loggingText: "settling",
                                                      trendCoverageText: "--",
                                                      trendConfidence: "learning",
                                                      trendDetail: "Saved trends are preparing.",
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
        let initialStatus = StatusState(status: ble.status,
                                        officialWhoopCoexistenceRisk: ble.officialWhoopCoexistenceRisk)
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
        let initialProfileMetrics = Self.makeProfileMetricsState(store: store,
                                                                 liveSessionDerived: initialLiveSessionDerived)
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
        self.profileMetricsStore = ProfileMetricsStore(state: initialProfileMetrics)
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

        ble.$officialWhoopCoexistenceRisk
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishStatus()
                self.publishCollectionLive()
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
            ble.$longWearModeEnabled.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$collectionProfile.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$officialWhoopCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
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
                self.publishProfileMetrics()
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
                self.publishProfileMetrics()
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
        let next = StatusState(status: ble.status,
                               officialWhoopCoexistenceRisk: ble.officialWhoopCoexistenceRisk)
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

    private func publishProfileMetrics() {
        refreshLiveSessionDerivedIfNeeded()
        let next = Self.makeProfileMetricsState(store: store,
                                                liveSessionDerived: liveSessionDerived)
        guard next != profileMetricsStore.state else { return }
        profileMetricsStore.state = next
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
        guard !diagnosticsWorkInFlight else {
            WHOOPDebugLog("WHOOPDBG home_diagnostics status=skipped reason=refresh_in_flight")
            return
        }
        diagnosticsWorkItem?.cancel()
        let token = UUID()
        diagnosticsRefreshToken = token
        diagnosticsWorkInFlight = true
        let workItem = DispatchWorkItem(qos: .utility) { [weak self] in
            guard let self else { return }
            let details = Self.makeDeferredDetails(ble: self.ble, store: self.store)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.diagnosticsRefreshToken == token else {
                    self.diagnosticsWorkInFlight = false
                    return
                }
                self.deferredDetails = details
                self.diagnosticsWorkInFlight = false
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
                                   longWearModeEnabled: ble.longWearModeEnabled,
                                   rangeLossBackfillPending: ble.rangeLossBackfillPending,
                                   collectionProfile: ble.collectionProfile,
                                   officialWhoopCoexistenceRisk: ble.officialWhoopCoexistenceRisk)
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
        let validatedHRV = store.latestReferenceValidatedHRV
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil)
        let stress = stressState(ble: ble, baseline: store.baseline)
        let liveTRIMP = live.liveTRIMP
        let totalTRIMP = savedAggregate.savedTodayTRIMP + liveTRIMP
        let strain = Metrics.strain(fromTRIMP: totalTRIMP)
        let load = store.trainingLoadSummary(rest: rest, maxHR: maxHR)
        let strainConfidence: String
        if maxHR <= rest {
            strainConfidence = "learning"
        } else if savedAggregate.hasSavedToday || live.sessionSampleCount >= 60 {
            strainConfidence = "local"
        } else {
            strainConfidence = "learning"
        }

        let guidance = Coach.guide(recovery: recovery, strain: strain, load: load)
        return HeroSnapshot(recoveryEstimate: recovery,
                            strain: strain,
                            strainConfidence: strainConfidence,
                            guidance: guidance,
                            hrvValue: deferredDetails?.hrvValue ?? fallbackHrv.value,
                            hrvDetail: deferredDetails?.hrvDetail ?? fallbackHrv.detail,
                            hrvNarrative: deferredDetails?.hrvNarrative ?? fallbackHrv.narrative,
                            stressValue: stress.value,
                            stressDetail: stress.detail,
                            stressNarrative: stress.narrative,
                            rrPackageText: deferredDetails?.rrPackageText ?? fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: deferredDetails?.backupValue ?? "Preparing",
                            backupDetail: deferredDetails?.backupDetail ?? "saved history",
                            restingHeartRate: rest,
                            restingHeartRateText: "\(rest)",
                            strainNarrative: String(format: "TRIMP %.1f from saved %.1f + live %.1f", totalTRIMP, savedAggregate.savedTodayTRIMP, liveTRIMP),
                            loadRatioText: load.ratioText,
                            loadTargetText: load.targetBandText,
                            loadConfidence: load.confidence,
                            loadNarrative: load.detail)
    }

    private struct FallbackHeroHRVState {
        let value: String
        let detail: String
        let narrative: String
        let packageText: String
    }

    private struct StressState {
        let value: String
        let detail: String
        let narrative: String
    }

    private static func stressState(ble: WhoopBLEManager, baseline: PersonalBaseline) -> StressState {
        guard let snapshot = ble.hrvSnapshot else {
            return StressState(value: "Learning",
                               detail: "RR window",
                               narrative: "Stress appears after a clean live RR window is ready.")
        }
        guard snapshot.isReady else {
            return StressState(value: "Learning",
                               detail: snapshot.readinessReason,
                               narrative: snapshot.readinessMessage)
        }
        guard let stats = baseline.lnRMSSDStats, stats.count >= 3 else {
            return StressState(value: "Learning",
                               detail: "\(baseline.hrvSampleCount)/3 baseline",
                               narrative: "Atria needs a few personal HRV samples before comparing stress to your norm.")
        }

        let spread = max(stats.sd, 0.15)
        let z = (stats.mean - snapshot.lnRMSSD) / spread
        let index: Int
        if z < 0.5 {
            index = 0
        } else if z < 1.0 {
            index = 1
        } else if z < 2.0 {
            index = 2
        } else {
            index = 3
        }
        let badge = stats.count >= 7 ? "personal baseline" : "unverified"
        return StressState(value: "\(index)/3",
                           detail: badge,
                           narrative: String(format: "Live lnRMSSD is %.1f SD from your baseline.", z))
    }

    private static func fallbackHeroHRVState(ble: WhoopBLEManager,
                                             store: SessionStore) -> FallbackHeroHRVState {
        let value: String
        if let validated = store.latestReferenceValidatedHRV {
            value = "\(validated)"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            value = "\(Int(snapshot.rmssd.rounded()))"
        } else if let local = store.latestLocalRMSSD {
            value = "\(local)"
        } else {
            value = "Learning"
        }

        let detail: String
        if store.latestReferenceValidatedHRV != nil {
            detail = "validated"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            detail = "personal baseline"
        } else if store.latestLocalRMSSD != nil {
            detail = "personal baseline"
        } else {
            detail = ble.hrvQuality
        }

        let narrative: String
        if store.latestReferenceValidatedHRV != nil {
            narrative = "Reference-checked HRV is ready."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            narrative = "The live RR window is ready as personal-baseline HRV."
        } else if store.latestLocalRMSSD != nil {
            narrative = "Saved local RMSSD is ready as personal-baseline HRV."
        } else {
            narrative = "Atria keeps the live RR window light while the connection settles."
        }

        let packageText: String
        if store.latestReferenceValidatedHRV != nil {
            packageText = "Validated"
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            packageText = "Unverified"
        } else if store.latestLocalRMSSD != nil {
            packageText = "Personal"
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
            return "Live connection is active."
        }
        return "A lighter dashboard that gets to your signal faster."
    }

    private static func defaultHeroNextAction(status: WhoopBLEManager.Status) -> String {
        if status != .connected {
            return "Keep the phone near the strap until Atria reconnects."
        }
        return "Settling saved insights in the background."
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
            guidance = Coach.Guidance(headline: "Looking for your strap",
                                      detail: "Your dashboard stays responsive while Atria searches for your strap nearby.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_scanning_fast_path")
        case .connecting:
            guidance = Coach.Guidance(headline: "Connecting to your strap",
                                      detail: "Atria is finishing the connection. Your live readings appear right after.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_connecting_fast_path")
        case .poweredOff:
            guidance = Coach.Guidance(headline: "Turn Bluetooth on to continue",
                                      detail: "Your data is safe. Atria reconnects automatically once Bluetooth is back on.",
                                      color: .orange,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_powered_off_fast_path")
        case .disconnected:
            guidance = Coach.Guidance(headline: "Ready to reconnect",
                                      detail: "Your saved data is here right away while Atria keeps trying to reconnect in the background.",
                                      color: .blue,
                                      target: nil,
                                      state: "learning",
                                      reason: "disconnected_idle_fast_path")
        case .connected:
            guidance = Coach.Guidance(headline: "Connected and reading live",
                                      detail: "Your live scores fill in moments after the screen is ready.",
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
                            stressValue: "Learning",
                            stressDetail: "RR window",
                            stressNarrative: "Stress appears after the strap reconnects and RR is ready.",
                            rrPackageText: fallbackHrv.packageText,
                            nextAction: nextAction,
                            headline: headline,
                            sessionsCount: savedAggregate.sessionsCount,
                            baselineSamples: savedAggregate.baselineSamples,
                            backupValue: hasSavedBackup ? "Ready" : "Learning",
                            backupDetail: hasSavedBackup ? "saved on device" : "no backup yet",
                            restingHeartRate: rest,
                            restingHeartRateText: "\(rest)",
                            strainNarrative: "Live strain resumes after the strap reconnects.",
                            loadRatioText: "Learning",
                            loadTargetText: "Learning",
                            loadConfidence: "learning",
                            loadNarrative: "Training load appears after local strain history builds.")
    }

    private static func makeSnapshot(store: SessionStore,
                                     hero: HeroSnapshot,
                                     deferredDetails: DeferredDetails?) -> Snapshot {
        let defaultReferenceText = baselineMaturityText(sampleCount: hero.baselineSamples)

        return Snapshot(referenceText: deferredDetails?.referenceText ?? defaultReferenceText,
                        sleepValue: deferredDetails?.sleepValue ?? "Preparing",
                        sleepDetail: deferredDetails?.sleepDetail ?? "saved history",
                        workoutText: deferredDetails?.workoutText ?? "Preparing",
                        loggingText: deferredDetails?.loggingText ?? "settling",
                        trendCoverageText: deferredDetails?.trendCoverageText ?? "--",
                        trendConfidence: deferredDetails?.trendConfidence ?? "learning",
                        trendDetail: deferredDetails?.trendDetail ?? "Saved trends are preparing.",
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

    private static func makeProfileMetricsState(store: SessionStore,
                                                liveSessionDerived: LiveSessionDerived) -> ProfileMetricsState {
        ProfileMetricsState(vo2MaxEstimate: store.vo2MaxEstimateSummary(rest: liveSessionDerived.rest,
                                                                        maxHR: store.profile.maxHR))
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
        let validatedHRV = store.latestReferenceValidatedHRV
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil)
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
            hrvDetail = "personal baseline"
        } else {
            hrvDetail = ble.hrvQuality
        }

        let hrvNarrative: String
        if store.latestReferenceValidatedHRV != nil {
            hrvNarrative = "Reference-checked HRV is ready."
        } else if rrPackage.ready {
            hrvNarrative = "A clean RR window is ready as personal-baseline HRV."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            hrvNarrative = "The live RR window is ready as personal-baseline HRV."
        } else {
            hrvNarrative = ble.hrvQuality
        }

        let sleepValue: String
        let sleepDetail: String
        if sleep.ready {
            sleepValue = "Ready"
            sleepDetail = sleep.confidence
        } else if sleep.fallbackAvailable {
            sleepValue = "Maybe"
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
            workoutText = "Strength-like"
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

        let referenceText = baselineMaturityText(sampleCount: store.baseline.hrvSampleCount)

        let headline: String
        if ble.status == .connected {
            headline = "Live connection is active."
        } else if rrPackage.ready {
            headline = "Saved RR is ready while the strap reconnects."
        } else {
            headline = "A lighter dashboard that gets to your signal faster."
        }

        let nextAction: String
        if ble.status != .connected {
            nextAction = "Keep the phone near the strap until Atria reconnects."
        } else if recovery.percent == nil && rrPackage.ready {
            nextAction = "Keep wearing while Atria finishes your personal baseline."
        } else if !collection.ready {
            nextAction = "Keep Atria open a little longer while backup settles."
        } else {
            nextAction = "Keep wearing; local backup is active."
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

    private static func baselineMaturityText(sampleCount: Int) -> String {
        sampleCount >= 7 ? "Ready" : "\(max(0, sampleCount))/7"
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
