import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit

struct AtriaHomeContainer: View, Equatable {
    let ble: AtriaBLEManager
    let store: SessionStore

    static func == (lhs: AtriaHomeContainer, rhs: AtriaHomeContainer) -> Bool {
        ObjectIdentifier(lhs.ble) == ObjectIdentifier(rhs.ble)
            && ObjectIdentifier(lhs.store) == ObjectIdentifier(rhs.store)
    }

    var body: some View {
        AtriaHomeView(ble: ble, store: store)
    }
}

fileprivate struct AtriaWorkoutDetectionPrompt: Equatable {
    let heartRate: Int
    let strain: Double
    let samples: Int
}

struct AtriaHomeView: View {
    private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15
    private static let connectionDiagnosisTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 45
    private static let liveWidgetSnapshotMeaningfulChangeInterval: TimeInterval = 15
    private static let liveWidgetSnapshotMeaningfulBPMDelta = 4
    private static let workoutPromptCooldown: TimeInterval = 45 * 60
    private static let workoutPromptMinimumSamples = 180
    private static let workoutPromptMinimumTRIMP = 1.2
    private static let workoutPromptMinimumBPMOverRest = 25

    private struct AtriaWorkoutEndNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum HomeTab: String, CaseIterable, Identifiable {
        case overview
        case vitals
        case collection

        var id: String { rawValue }

        var deepLinkPath: String {
            switch self {
            case .overview: return "overview"
            case .vitals: return "vitals"
            case .collection: return "data"
            }
        }

        static func deepLinkDestination(for url: URL) -> HomeTab? {
            guard url.scheme?.lowercased() == "atria" else { return nil }
            let pieces = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
                .map { $0.lowercased() }
            guard let token = pieces.first(where: { $0 != "tab" }) else { return nil }
            switch token {
            case "overview", "today": return .overview
            case "vitals": return .vitals
            case "data", "collection": return .collection
            default: return nil
            }
        }

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

    let ble: AtriaBLEManager
    let store: SessionStore

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("atriaAppearanceMode") private var appearanceMode = "system"
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
    @State private var workoutSession: AtriaWorkoutSession?
    @State private var workoutEndNotice: AtriaWorkoutEndNotice?
    @State private var showCoexistenceModal = false
    @State private var officialAppInstalled: Bool = {
        guard let url = URL(string: "whoop://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }()
    @State private var didApplyDebugUIScreenLaunchArgument = false
    @State private var coexistenceSnoozedUntil: Date?
    @State private var connectionGuideSnoozedUntil: Date?
    @State private var connectionGuidePresentationToken = UUID()
    @State private var connectionGuidePresentationTask: Task<Void, Never>?
    @State private var connectionDiagnosisCandidate: AtriaConnectionDiagnosis?
    @State private var connectionDiagnosisCandidateSince: Date?
    @State private var visibleConnectionDiagnosis: AtriaConnectionDiagnosis?
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
    @State private var lastLiveWidgetSnapshotAt: Date?
    @State private var lastLiveWidgetSnapshotHeartRate: Int?
    @State private var workoutDetectionPrompt: AtriaWorkoutDetectionPrompt?
    @State private var workoutPromptDismissedUntil: Date?

    init(ble: AtriaBLEManager, store: SessionStore) {
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
                tabNavigation(title: "Today") {
                    if hasUnlockedPrimaryContent {
                        overviewContent
                    } else {
                        secondaryLoadingCard(title: "Preparing overview",
                                             subtitle: "Getting the first live readout on screen before the deeper cards load.")
                    }
                }
                .tabItem { Label(HomeTab.overview.title, systemImage: HomeTab.overview.systemImage) }
                .tag(HomeTab.overview)

                tabNavigation(title: "Vitals") {
                    vitalsContent
                }
                .tabItem { Label(HomeTab.vitals.title, systemImage: HomeTab.vitals.systemImage) }
                .tag(HomeTab.vitals)

                tabNavigation(title: "Data") {
                    collectionContent
                }
                .tabItem { Label(HomeTab.collection.title, systemImage: HomeTab.collection.systemImage) }
                .tag(HomeTab.collection)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory && selectedTab != .overview) {
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
        .preferredColorScheme(preferredColorScheme)
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
                              strapName: ble.resolvedDeviceName,
                              strapModel: ble.strapModelLabel,
                              strapFirmware: ble.firmwareRevision,
                              onRenameStrap: { ble.setCustomDeviceName($0) },
                              onUpdateProfile: store.updateProfile,
                              hapticSettings: hapticSettings,
                              onUpdateHaptics: { hapticSettings = $0 },
                              batterySaverEnabled: ble.standardHROnlyEnabled,
                              onUpdateBatterySaver: { ble.setStandardHROnlyEnabled($0) },
                              onExportHealth: { store.exportToHealthKit() },
                              onSyncMissedData: {
                                  _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "manual_user_request",
                                                                              force: true)
                              },
                              onForgetStrap: { ble.forgetSavedStrap(reason: "user_settings") })
        }
        .fullScreenCover(item: $workoutSession) { session in
            AtriaLiveWorkoutView(pulseStore: model.pulseLiveStore,
                                 heroStore: model.heroStore,
                                 liveStore: model.coreLiveStore,
                                 maxHR: store.profile.maxHR,
                                 startDate: session.start,
                                 onStop: { endWorkoutSession(startedAt: session.start) })
        }
        .sheet(isPresented: $showCoexistenceModal) {
            AtriaCoexistenceModal(context: connectionGuideContext) {
                acknowledgeCoexistenceModal(reason: "button")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert(item: $workoutEndNotice) { notice in
            Alert(title: Text(notice.title),
                  message: Text(notice.message),
                  dismissButton: .default(Text("OK")))
        }
        .onReceive(ble.$officialAppCoexistenceRisk.removeDuplicates()) { risk in
            presentCoexistenceModalIfNeeded(for: risk)
            updateConnectionDiagnosisVisibility(reason: "coexistence_risk")
        }
        .onReceive(model.coreLiveStore.$state.map { _ in () }) { _ in
            updateConnectionDiagnosisVisibility(reason: "core_live")
        }
        .onReceive(model.pulseLiveStore.$state.map { _ in () }) { _ in
            updateConnectionDiagnosisVisibility(reason: "pulse_live")
        }
        .onReceive(Self.connectionDiagnosisTimer) { _ in
            updateConnectionDiagnosisVisibility(reason: "timer")
        }
        .onAppear {
            applyDebugUIScreenLaunchArgumentIfNeeded()
            if workoutSession == nil,
               ProcessInfo.processInfo.arguments.contains("--atria-show-workout") {
                workoutSession = AtriaWorkoutSession(start: Date())
            }
            presentCoexistenceModalIfNeeded(for: ble.officialAppCoexistenceRisk)
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
            ble.refreshPhoneStepsToday(reason: "home_appear")
            updateMediaRefreshLoop()
            updateLiveActivity()
            updateHapticCoordinator()
            updateConnectionDiagnosisVisibility(reason: "home_appear")
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
            // Defer radio/diagnostics reconfiguration to the next runloop so the
            // tab transition renders immediately instead of janking while we
            // reconfigure BLE notifications and kick off diagnostics work.
            Task { @MainActor in
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
        }
        .onChange(of: hasUnlockedSecondarySections) { _, unlocked in
            guard unlocked else { return }
            logSecondaryContentReadyIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            updateMediaRefreshLoop()
            guard phase == .active else {
                ble.pausePhoneStepUpdates(reason: "scene_inactive")
                // Refresh Lock Screen / Home Screen widgets with the latest
                // Steps/Strain/HRV/BPM right as the user leaves the app.
                WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: "scene_background")
                return
            }
            ble.refreshPhoneStepsToday(reason: "scene_active")
            WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: "scene_active")
            if let url = URL(string: "whoop://") {
                officialAppInstalled = UIApplication.shared.canOpenURL(url)
            }
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
            publishLiveWidgetSnapshotIfNeeded()
            updateWorkoutDetectionPrompt()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryState = UIDevice.current.batteryState
        }
        .onOpenURL(perform: handleDeepLink)
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

    private func handleDeepLink(_ url: URL) {
        guard let tab = HomeTab.deepLinkDestination(for: url) else { return }
        selectedTab = tab
        hasUnlockedPrimaryContent = true
        if tab != .overview {
            hasUnlockedSecondarySections = true
        }
        if tab == .collection {
            model.loadDeferredDiagnosticsIfNeeded(reason: "deeplink_\(tab.deepLinkPath)")
        }
        AtriaDebugLog("ATRIADBG deeplink status=handled target=%@ url=%@",
                      tab.deepLinkPath,
                      url.absoluteString)
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

    private func secondaryUnlockDelayNanoseconds(for status: AtriaBLEManager.Status) -> UInt64 {
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
        guard !didApplyDebugUIScreenLaunchArgument else { return }
        let requestedScreen: String
        if arguments.contains("--atria-open-settings") {
            requestedScreen = "settings"
        } else if let screenIndex = arguments.firstIndex(of: "--atria-ui-screen"),
                  arguments.indices.contains(arguments.index(after: screenIndex)) {
            requestedScreen = arguments[arguments.index(after: screenIndex)].lowercased()
        } else {
            return
        }

        didApplyDebugUIScreenLaunchArgument = true
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
            Task { @MainActor in
                for delay in [100, 450, 900] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    showSettings = false
                    await Task.yield()
                    showSettings = true
                }
            }
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
            batteryChargeStatus: model.coreLiveStore.state.batteryChargeStatus,
            readingCount: model.coreLiveStore.state.sessionSampleCount,
            mediaTitle: mediaController.state.title,
            mediaArtist: mediaController.state.artist,
            mediaIsPlaying: mediaController.state.isPlaying,
            mediaHasNowPlayingInfo: mediaController.state.hasNowPlayingInfo
        ))
    }

    private func publishLiveWidgetSnapshotIfNeeded(now: Date = Date()) {
        guard scenePhase == .active else { return }
        let heartRate = model.pulseLiveStore.state.heartRate
        guard heartRate > 0 else { return }
        let elapsed = lastLiveWidgetSnapshotAt.map { now.timeIntervalSince($0) }
        let meaningfulDelta = lastLiveWidgetSnapshotHeartRate.map {
            abs(heartRate - $0) >= Self.liveWidgetSnapshotMeaningfulBPMDelta
        } ?? true
        let cadenceReady = elapsed.map { $0 >= Self.liveWidgetSnapshotMinimumInterval } ?? true
        let changeReady = meaningfulDelta
            && (elapsed.map { $0 >= Self.liveWidgetSnapshotMeaningfulChangeInterval } ?? true)
        guard cadenceReady || changeReady else {
            return
        }
        lastLiveWidgetSnapshotAt = now
        lastLiveWidgetSnapshotHeartRate = heartRate
        WidgetSnapshotPublisher.publish(store: store,
                                        ble: ble,
                                        reason: cadenceReady ? "live_throttled" : "live_bpm_delta")
    }

    private func updateWorkoutDetectionPrompt(now: Date = Date()) {
        guard scenePhase == .active else { return }
        guard selectedTab == .overview else { return }
        guard workoutSession == nil else {
            workoutDetectionPrompt = nil
            return
        }
        guard model.coreLiveStore.state.status == .connected else {
            workoutDetectionPrompt = nil
            return
        }
        if let workoutPromptDismissedUntil, workoutPromptDismissedUntil > now {
            workoutDetectionPrompt = nil
            return
        }
        let heartRate = model.pulseLiveStore.state.heartRate
        let rest = model.homeStatsStore.state.restingHeartRate
        let samples = model.coreLiveStore.state.sessionSampleCount
        let liveTRIMP = model.coreLiveStore.state.liveTRIMP
        let strain = Metrics.strain(fromTRIMP: liveTRIMP)
        let looksActive = samples >= Self.workoutPromptMinimumSamples
            && liveTRIMP >= Self.workoutPromptMinimumTRIMP
            && heartRate >= rest + Self.workoutPromptMinimumBPMOverRest
        if looksActive {
            workoutDetectionPrompt = AtriaWorkoutDetectionPrompt(heartRate: heartRate,
                                                                 strain: strain,
                                                                 samples: samples)
        } else {
            workoutDetectionPrompt = nil
        }
    }

    private func endWorkoutSession(startedAt: Date) {
        let label = "Live workout"
        let checkpointed = ble.checkpointCurrentSession(label: label, reason: "live_workout_end")
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let confirmed = store.confirmBestWorkoutCandidateForUI(rest: rest,
                                                               maxHR: store.profile.maxHR,
                                                               source: "live_workout_end")
        workoutSession = nil

        if let confirmed {
            store.exportToHealthKit()
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Workout saved",
                message: "Atria confirmed \(formatWorkoutDuration(confirmed.duration)) with \(confirmed.streamCoveragePercent)% stream coverage and queued it for Health export."
            )
        } else if checkpointed {
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Workout evidence saved",
                message: "Atria saved this live window locally. It is still learning because the workout gate needs at least 10 minutes of strong heart-rate evidence."
            )
        } else {
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Not enough data yet",
                message: "Keep the workout running until Atria has multiple heart-rate samples before ending it."
            )
        }

        AtriaDebugLog("ATRIADBG live_workout_end checkpointed=%d confirmed=%d started_unix=%d",
              checkpointed ? 1 : 0,
              confirmed == nil ? 0 : 1,
              Int(startedAt.timeIntervalSince1970.rounded()))
    }

    private func formatWorkoutDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
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

    private var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
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
                .padding(.bottom, shouldShowLiveAccessory ? 168 : 40)
                .frame(maxWidth: .infinity)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .navigationTitle(title)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                topChrome
            }
        }
    }

    private var topChrome: some View {
        AtriaHomeTopChrome(statusStore: model.statusStore,
                           coreLiveStore: model.coreLiveStore,
                           pulseLiveStore: model.pulseLiveStore,
                           store: store,
                           showWorkout: model.statusStore.state.status == .connected,
                           showHelp: model.statusStore.state.status != .connected,
                           onStartWorkout: {
                               workoutSession = AtriaWorkoutSession(start: Date())
                           },
                           onShowHelp: {
                               connectionGuideSnoozedUntil = nil
                               showConnectionGuide = true
                           },
                           onShowSettings: {
                               showSettings = true
                           },
                           onTapStatusWhenNotConnected: {
                               ble.startScan(reason: "home_status_chip")
                           })
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var hero: some View {
        AtriaHeroPanelHost(statusStore: model.statusStore,
                           liveStore: model.coreLiveStore,
                           heroStore: model.heroStore,
                           pulseStore: model.heroPulseStore)
    }


    private var overviewContent: some View {
        VStack(spacing: 18) {
            if shouldShowMissedDataBanner {
                AtriaMissedDataBanner(protectsLiveStream: missedDataBackfillIsDeferredForLiveStream) {
                    missedDataBannerDismissedUntil = Date().addingTimeInterval(60 * 60)
                } onSync: {
                    guard !missedDataBackfillIsDeferredForLiveStream else {
                        missedDataBannerDismissedUntil = Date().addingTimeInterval(15 * 60)
                        return
                    }
                    missedDataBannerDismissedUntil = nil
                    _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "home_missed_data_banner",
                                                                 force: true)
                }
            }

            if let diagnosis = connectionDiagnosis {
                AtriaConnectionDiagnosisBanner(diagnosis: diagnosis) {
                    connectionGuideSnoozedUntil = nil
                    showConnectionGuide = true
                }
            }

            if let prompt = workoutDetectionPrompt, workoutSession == nil {
                AtriaWorkoutDetectionBanner(prompt: prompt) {
                    workoutDetectionPrompt = nil
                    workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)
                } onStart: {
                    workoutDetectionPrompt = nil
                    workoutSession = AtriaWorkoutSession(start: Date())
                }
            }

            AtriaOverviewTabContent(statusStore: model.statusStore,
                                    liveStore: model.coreLiveStore,
                                    heroStore: model.heroStore,
                                    homeStatsStore: model.homeStatsStore,
                                    profileMetricsStore: model.profileMetricsStore,
                                    snapshotStore: model.snapshotStore,
                                    store: store,
                                    hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                                    aiCoachSettings: aiCoachSettings,
                                    aiCoachHasAPIKey: aiCoachHasAPIKey,
                                    hapticSettings: hapticSettings,
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
                                    },
                                    onStartWorkout: {
                                        workoutSession = AtriaWorkoutSession(start: Date())
                                    })
        }
    }

    private var connectionDiagnosis: AtriaConnectionDiagnosis? {
        visibleConnectionDiagnosis
    }

    private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date()) {
        let next = AtriaConnectionDiagnosis.derive(live: model.coreLiveStore.state,
                                                   pulse: model.pulseLiveStore.state,
                                                   officialAppInstalled: officialAppInstalled)
        guard let next else {
            if visibleConnectionDiagnosis != nil || connectionDiagnosisCandidate != nil {
                AtriaDebugLog("ATRIADBG connection_diagnosis status=hidden reason=%@ action=clear", reason)
            }
            if visibleConnectionDiagnosis?.sendsLocalNotification == true ||
                connectionDiagnosisCandidate?.sendsLocalNotification == true {
                LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: "diagnosis_cleared_\(reason)")
            }
            connectionDiagnosisCandidate = nil
            connectionDiagnosisCandidateSince = nil
            visibleConnectionDiagnosis = nil
            return
        }

        if visibleConnectionDiagnosis?.sendsLocalNotification == true,
           visibleConnectionDiagnosis?.title != next.title {
            LocalNotificationScheduler.cancelActionableConnectionDiagnosis(title: visibleConnectionDiagnosis?.title,
                                                                           reason: "diagnosis_changed_\(reason)")
        }
        if !next.sendsLocalNotification,
           visibleConnectionDiagnosis?.sendsLocalNotification == true ||
            connectionDiagnosisCandidate?.sendsLocalNotification == true {
            LocalNotificationScheduler.cancelActionableConnectionDiagnosis(reason: "diagnosis_non_actionable_\(reason)")
        }

        if next.showsImmediately {
            if next.sendsLocalNotification && visibleConnectionDiagnosis != next {
                LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,
                                                                                 body: next.action,
                                                                                 reason: reason,
                                                                                 now: now)
            }
            connectionDiagnosisCandidate = next
            connectionDiagnosisCandidateSince = now
            visibleConnectionDiagnosis = next
            return
        }

        if connectionDiagnosisCandidate != next {
            connectionDiagnosisCandidate = next
            connectionDiagnosisCandidateSince = now
            visibleConnectionDiagnosis = nil
            AtriaDebugLog("ATRIADBG connection_diagnosis status=pending reason=%@ title=%@ delay_s=%.0f",
                  reason,
                  next.title,
                  Self.connectionDiagnosisPersistenceDelay)
            return
        }

        let elapsed = connectionDiagnosisCandidateSince.map { now.timeIntervalSince($0) } ?? 0
        guard elapsed >= Self.connectionDiagnosisPersistenceDelay else {
            visibleConnectionDiagnosis = nil
            return
        }
        if visibleConnectionDiagnosis != next {
            AtriaDebugLog("ATRIADBG connection_diagnosis status=visible reason=%@ title=%@ elapsed_s=%.0f",
                  reason,
                  next.title,
                  elapsed)
        }
        visibleConnectionDiagnosis = next
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
        case .connected:
            return model.coreLiveStore.state.sessionSampleCount > 0
        case .disconnected, .poweredOff:
            return model.coreLiveStore.state.sessionSampleCount == 0
        case .connecting, .scanning:
            return false
        }
    }

    private var missedDataBackfillIsDeferredForLiveStream: Bool {
        model.statusStore.state.status == .connected
            && model.coreLiveStore.state.sessionSampleCount > 0
    }

    private func presentCoexistenceModalIfNeeded(for risk: AtriaBLEManager.OfficialAppCoexistenceRisk) {
        guard risk == .suspected else { return }
        // Never auto-interrupt the user when the official strap app isn't even installed — those
        // drops are battery/range and are handled silently by auto-reconnect. The
        // recovery steps stay available on demand via the "?" connection guide.
        guard officialAppInstalled else { return }
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
        guard arguments.contains("--atria-verify-coexistence-snooze") else { return }
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
        defaults.set(status, forKey: "atria.link.coexistenceSnoozeVerificationStatus")
        defaults.set(reason, forKey: "atria.link.coexistenceSnoozeVerificationReason")
        defaults.set(Date().timeIntervalSince1970, forKey: "atria.link.coexistenceSnoozeVerificationAt")
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
                                  profileMetricsStore: model.profileMetricsStore,
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
                                  officialAppInstalled: officialAppInstalled,
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
                rrImportStatus = "No beat-to-beat file selected"
                return
            }
            let passed = store.importRRReferenceCSVForUI(from: url)
            rrImportStatus = passed ? "Beat-to-beat reference validated" : "Beat-to-beat reference still pending"
            model.forceRefresh()
        case .failure:
            rrImportStatus = "Beat-to-beat import failed"
        }
    }

    private func handleHRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                hrImportStatus = "No heart-rate file selected"
                return
            }
            let passed = store.importHRReferenceCSVForUI(from: url)
            hrImportStatus = passed ? "Heart-rate check passed" : "Heart-rate check still pending"
            model.forceRefresh()
        case .failure:
            hrImportStatus = "Heart-rate import failed"
        }
    }

    private func presentConnectionGuideIfNeeded() {
        connectionGuidePresentationTask?.cancel()
        connectionGuidePresentationTask = nil
        let defaults = UserDefaults.standard
        let successes = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.successes)
        let attempts = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.attempts)
        let failures = defaults.integer(forKey: AtriaBLEManager.LinkDefaults.failures)
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
                  UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) == 0,
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
                UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) == 0 ? 2.2 : 4.5
            if let lastAutomaticConnectionSetupAt,
               now.timeIntervalSince(lastAutomaticConnectionSetupAt) < minimumSpacing {
                return
            }
            lastAutomaticConnectionSetupAt = now
            ble.startScan(reason: reason)
        }
    }

    private func handleStatusChange(_ status: AtriaBLEManager.Status) {
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
            hasEverConnected: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.successes) > 0,
            attempts: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.attempts),
            failures: defaults.integer(forKey: AtriaBLEManager.LinkDefaults.failures),
            lastStatus: defaults.string(forKey: AtriaBLEManager.LinkDefaults.lastStatus) ?? "idle",
            lastReason: defaults.string(forKey: AtriaBLEManager.LinkDefaults.lastReason) ?? "waiting",
            officialAppCoexistenceRisk: model.statusStore.state.officialAppCoexistenceRisk,
            officialAppInstalled: officialAppInstalled
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

    private func logHomeTiming(event: String, status: AtriaBLEManager.Status) {
        let elapsedMS = Int((Date().timeIntervalSince(homeAppearedAt ?? Date())) * 1000)
        AtriaDebugLog("ATRIADBG home_launch_timing event=%@ elapsed_ms=%d status=%@ tab=%@",
                      event,
                      elapsedMS,
                      status.logToken,
                      selectedTab.rawValue)
    }
}

private struct AtriaMissedDataBanner: View, Equatable {
    let protectsLiveStream: Bool
    let onDismiss: () -> Void
    let onSync: () -> Void

    static func == (lhs: AtriaMissedDataBanner, rhs: AtriaMissedDataBanner) -> Bool {
        lhs.protectsLiveStream == rhs.protectsLiveStream
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.cyan)
                .frame(width: 34, height: 34)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: .cyan))

            VStack(alignment: .leading, spacing: 3) {
                Text(protectsLiveStream ? "Missed data queued" : "New data on your strap")
                    .font(.subheadline.weight(.semibold))
                Text(protectsLiveStream ? "Live HR stays protected. Sync when you can pause the stream." : "Sync missed data when you are ready.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            Button(action: onSync) {
                Text(protectsLiveStream ? "Queued" : "Sync")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(minWidth: protectsLiveStream ? 76 : 48)
            }
            .atriaCardAction(tint: .cyan)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
            }
            .atriaCardAction(prominent: false, tint: .secondary)
            .accessibilityLabel("Dismiss missed data banner")
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .contain)
    }
}

private struct AtriaWorkoutDetectionBanner: View, Equatable {
    let prompt: AtriaWorkoutDetectionPrompt
    let onDismiss: () -> Void
    let onStart: () -> Void

    static func == (lhs: AtriaWorkoutDetectionBanner, rhs: AtriaWorkoutDetectionBanner) -> Bool {
        lhs.prompt == rhs.prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(AtriaIconTileBackground(cornerRadius: 11, tint: .orange))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Looks like a workout")
                        .font(.subheadline.weight(.semibold))
                    Text("Live HR \(prompt.heartRate) bpm · strain \(String(format: "%.1f", prompt.strain)) · \(prompt.samples) readings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button(action: onStart) {
                    Text("Start workout")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(tint: .orange)

                Button(action: onDismiss) {
                    Text("Dismiss")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
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
        // Live bar: a heart (the strap is recording) + strap battery, with a
        // charging bolt when it's on the charger. No connection words here —
        // connection state lives only in the top status pill.
        HStack(spacing: isInline ? 8 : 10) {
            Image(systemName: "heart.fill")
                .font(isInline ? .caption.weight(.bold) : .subheadline.weight(.bold))
                .foregroundStyle(.red)

            Image(systemName: liveStore.state.batterySymbol)
                .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(liveStore.state.batteryChargeStatus == .charging ? Color.green : .secondary)

            Text(liveStore.state.batteryText)
                .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                .monospacedDigit()

            Text(isInline ? liveStore.state.batteryChargeCompactText : liveStore.state.batteryChargeText)
                .font((isInline ? Font.caption2 : Font.caption).weight(.semibold))
                .foregroundStyle(liveStore.state.batteryChargeStatus == .charging ? .green : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)

            if !isInline { Spacer(minLength: 0) }
        }
        .padding(.horizontal, isInline ? 8 : 12)
        .padding(.vertical, isInline ? 4 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Strap battery \(liveStore.state.batteryText), \(liveStore.state.batteryChargeText).")
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

                    Text(pulseLiveStore.state.hasPulseSignal ? "BPM live" : "BPM waiting")
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
                    AtriaStandByMetric(title: "Calories",
                                       value: coreLiveStore.state.liveActiveCaloriesText,
                                       detail: coreLiveStore.state.liveActiveCalories == nil ? "Profile needed" : "Active estimate",
                                       tint: .pink)
                    AtriaStandByMetric(title: "Battery",
                                       value: coreLiveStore.state.batteryStatusSummaryText,
                                       detail: coreLiveStore.state.batteryDetailText,
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
        var status: AtriaBLEManager.Status
        var bluetoothPermissionDenied: Bool
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
    }

    struct CoreLiveState: Equatable {
        var status: AtriaBLEManager.Status
        var bluetoothPermissionDenied: Bool
        var deviceName: String
        var displayDeviceName: String
        var batteryLevel: Int
        var batteryIsCharging: Bool
        var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus
        var batteryRecentlyDropping: Bool
        var rrContinuityState: String
        var hrvSDNN: Double?
        var hrvPNN50: Double?
        var sessionSampleCount: Int
        var liveTRIMP: Double
        var liveActiveCalories: Double?
        var phoneStepsToday: Int
        var phoneDistanceTodayMeters: Double?
        var phoneFloorsToday: Int?
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
        var lastScanRequestedAt: Date?
        var lastScanMatchAt: Date?
        var pendingKnownReconnectStartedAt: Date?
        var pendingKnownReconnectReason: String

        var batteryText: String { batteryLevel >= 0 ? "\(batteryLevel)%" : "Waiting" }
        var batteryChargeText: String { batteryLevel >= 0 ? batteryChargeStatus.label : "Waiting" }
        var batteryChargeCompactText: String {
            switch batteryChargeStatus {
            case .levelOnly: return "State pending"
            case .charging: return "Charging"
            case .notCharging: return "Not chg"
            case .full: return "Full"
            }
        }
        var batteryStatusSummaryText: String {
            guard batteryLevel >= 0 else { return "Waiting" }
            return "\(batteryText) · \(batteryChargeCompactText)"
        }
        var batteryDetailText: String {
            guard batteryLevel >= 0 else { return "Waiting for strap battery" }
            return batteryChargeStatus == .levelOnly ? "Battery level is live; waiting for charger-state signal" : batteryChargeText
        }
        var rrContinuityText: String { rrContinuityState.replacingOccurrences(of: "_", with: " ") }
        var hrvSDNNText: String { hrvSDNN.map { "\(Int($0.rounded()))" } ?? "--" }
        var hrvPNN50Text: String { hrvPNN50.map { "\(Int($0.rounded()))%" } ?? "--" }
        var needsRRQualityCoach: Bool { rrContinuityState == "poor_contact" }
        func pendingKnownReconnectAge(now: Date = Date()) -> TimeInterval? {
            pendingKnownReconnectStartedAt.map { now.timeIntervalSince($0) }
        }
        var liveActiveCaloriesText: String { liveActiveCalories.map { "\(Int($0.rounded()))" } ?? "--" }
        var phoneStepsText: String { phoneStepsToday > 0 ? "\(phoneStepsToday)" : "--" }
        var phoneMotionDetailText: String {
            var parts: [String] = []
            if let meters = phoneDistanceTodayMeters, meters >= 100 {
                parts.append(String(format: "%.1f km", meters / 1_000))
            }
            if let floors = phoneFloorsToday, floors > 0 {
                parts.append("\(floors) \(floors == 1 ? "floor" : "floors")")
            }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
            return phoneStepsToday > 0 ? "iPhone motion" : "Building"
        }

        /// SF Symbol matching the level, with the bolt overlay while charging.
        var batterySymbol: String {
            guard batteryLevel >= 0 else { return "battery.0percent" }
            if batteryChargeStatus == .charging { return "battery.100percent.bolt" }
            switch batteryLevel {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }

    struct PulseLiveState: Equatable {
        var heartRate: Int
        var hasContact: Bool
        var sensorHasContact: Bool
        var averageHeartRate: Int?
        var peakHeartRate: Int?

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
        var hasPulseSignal: Bool { heartRate > 0 || hasContact }
        var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }
        var contactText: String { hasPulseSignal ? "Live" : "No signal" }
        var averageHeartRateText: String { averageHeartRate.map(String.init) ?? "--" }
        var peakHeartRateText: String { peakHeartRate.map(String.init) ?? "--" }
    }

    struct HeroPulseState: Equatable {
        var heartRate: Int
        var hasContact: Bool
        var sensorHasContact: Bool

        var heartRateText: String { heartRate > 0 ? "\(heartRate)" : "--" }
        var hasPulseSignal: Bool { heartRate > 0 || hasContact }
        var needsContactCoach: Bool { !hasPulseSignal && !sensorHasContact }
    }

    struct PulseSparklineState: Equatable {
        var values: [Int]
        var chartPoints: [HeartRateChartPoint]
    }

    struct HeartRateChartPoint: Identifiable, Equatable {
        let t: Date
        let bpm: Int

        var id: TimeInterval { t.timeIntervalSinceReferenceDate }
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
        var collectionProfile: AtriaBLEManager.CollectionProfile
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk

        var recordingState: String { isRecording ? "Recording" : (captureWasValidationReady ? "Ready" : "Idle") }
        var captureFileLabel: String { lastCaptureFile.isEmpty ? "None" : "Saved" }
        var modeLabel: String {
            longWearModeEnabled ? "Long wear" : collectionProfile.label
        }
        var coexistenceStatusText: String { officialAppCoexistenceRisk.label }
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
        let loadReadinessText: String
        let loadACWRSignalText: String
        let loadMonotonyText: String
        let loadMonotonySignalText: String
        let loadACWRDetailText: String
        let loadMonotonyDetailText: String
        let loadSignalSummaryText: String
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
                && lhs.loadReadinessText == rhs.loadReadinessText
                && lhs.loadACWRSignalText == rhs.loadACWRSignalText
                && lhs.loadMonotonyText == rhs.loadMonotonyText
                && lhs.loadMonotonySignalText == rhs.loadMonotonySignalText
                && lhs.loadACWRDetailText == rhs.loadACWRDetailText
                && lhs.loadMonotonyDetailText == rhs.loadMonotonyDetailText
                && lhs.loadSignalSummaryText == rhs.loadSignalSummaryText
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
        let biologicalAgeSummary: BiologicalAgeSummary
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

    private let ble: AtriaBLEManager
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
        let activeCalories: Double?
    }

    private struct PulseWindowSummary: Equatable {
        let averageHeartRate: Int?
        let peakHeartRate: Int?
    }

    init(ble: AtriaBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        self.savedAggregate = Self.makeSavedAggregate(store: store)
        let initialLiveSessionDerived = Self.makeLiveSessionDerived(samples: ble.session,
                                                                    rest: Self.currentRestingHeartRate(ble: ble, store: store),
                                                                    maxHR: store.profile.maxHR,
                                                                    profile: store.profile)
        let initialStatus = StatusState(status: ble.status,
                                        bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                                        officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk)
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
            AtriaDebugLog("ATRIADBG home_diagnostics status=requested reason=%@", reason)
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

        ble.$officialAppCoexistenceRisk
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishStatus()
                self.publishCollectionLive()
            }
            .store(in: &cancellables)

        ble.$bluetoothPermissionDenied
            .removeDuplicates()
            .map { _ in () }
            .sink { [weak self] _ in
                self?.publishStatus()
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
            ble.$bluetoothPermissionDenied.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryLevel.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryChargeStatus.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$batteryRecentlyDropping.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rrContinuityState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$phoneStepsToday.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$phoneDistanceTodayMeters.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$phoneFloorsToday.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$officialAppCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanRequestedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanMatchAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectStartedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectReason.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
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
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            pulseSummaryChanges
        ])
        .throttle(for: .milliseconds(650), scheduler: RunLoop.main, latest: true)

        throttledPulseLiveChanges
            .sink { [weak self] _ in
                guard let self else { return }
                self.publishPulseLive()
            }
            .store(in: &cancellables)

        ble.$liveHeartWindow
            .map(\.sparkline)
            .removeDuplicates()
            .throttle(for: .milliseconds(1500), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] (_: [Int]) in
                guard let self else { return }
                self.publishPulseLive()
                self.publishHeroPulse()
                if self.prefersPulseSparklineUpdates {
                    self.publishPulseSparkline()
                }
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
            ble.$officialAppCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
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

        Publishers.Merge(
            store.$sleepHistorySnapshot.map { _ in () }.eraseToAnyPublisher(),
            store.$trainingLoadSummarySnapshot.map { _ in () }.eraseToAnyPublisher()
        )
        .throttle(for: .milliseconds(900), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in
            self?.publishProfileMetrics()
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
                self.publishPulseLive()
                self.publishProfileMetrics()
                if self.prefersPulseSparklineUpdates {
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
                               bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                               officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk)
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
            AtriaDebugLog("ATRIADBG home_diagnostics status=skipped reason=refresh_in_flight")
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
                                                         maxHR: store.profile.maxHR,
                                                         profile: store.profile)
    }

    private func refreshLiveSessionDerivedIfNeeded() {
        let rest = Self.currentRestingHeartRate(ble: ble, store: store)
        let maxHR = store.profile.maxHR
        let profile = store.profile
        let samples = ble.session
        let needsRefresh = liveSessionDerived.rest != rest
            || liveSessionDerived.maxHR != maxHR
            || (liveSessionDerived.activeCalories != nil) != profile.hasEnergyProfile
            || liveSessionDerived.sampleCount != samples.count
            || liveSessionDerived.lastTimestamp != samples.last?.t

        guard needsRefresh else { return }
        liveSessionDerived = Self.nextLiveSessionDerived(previous: liveSessionDerived,
                                                         samples: samples,
                                                         rest: rest,
                                                         maxHR: maxHR,
                                                         profile: profile)
    }

    private static func currentRestingHeartRate(ble: AtriaBLEManager, store: SessionStore) -> Int {
        store.baseline.restingInt ?? ble.restingHR ?? store.sessions.first?.restingStable ?? 60
    }

    private static func makeCoreLiveState(ble: AtriaBLEManager,
                                          liveSessionDerived: LiveSessionDerived) -> CoreLiveState {
        let deviceName = ble.resolvedDeviceName
        return CoreLiveState(status: ble.status,
                             bluetoothPermissionDenied: ble.bluetoothPermissionDenied,
                             deviceName: deviceName,
                             displayDeviceName: AtriaDeviceDisplayName.shortName(for: deviceName),
                             batteryLevel: ble.batteryLevel,
                             batteryIsCharging: ble.batteryIsCharging,
                             batteryChargeStatus: ble.batteryChargeStatus,
                             batteryRecentlyDropping: ble.batteryRecentlyDropping,
                             rrContinuityState: ble.rrContinuityState,
                             hrvSDNN: ble.hrvSnapshot?.sdnn,
                             hrvPNN50: ble.hrvSnapshot?.pnn50,
                             sessionSampleCount: liveSessionDerived.sampleCount,
                             liveTRIMP: liveSessionDerived.trimp,
                             liveActiveCalories: liveSessionDerived.activeCalories,
                             phoneStepsToday: ble.phoneStepsToday,
                             phoneDistanceTodayMeters: ble.phoneDistanceTodayMeters,
                             phoneFloorsToday: ble.phoneFloorsToday,
                             officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk,
                             lastScanRequestedAt: ble.lastScanRequestedAt,
                             lastScanMatchAt: ble.lastScanMatchAt,
                             pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt,
                             pendingKnownReconnectReason: ble.pendingKnownReconnectReason)
    }

    private static func makePulseLiveState(ble: AtriaBLEManager) -> PulseLiveState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return PulseLiveState(heartRate: reconciledHeartRate,
                              hasContact: ble.hasContact || reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact,
                              averageHeartRate: ble.liveHeartWindow.average,
                              peakHeartRate: ble.liveHeartWindow.peak)
    }

    private static func makeHeroPulseState(ble: AtriaBLEManager) -> HeroPulseState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return HeroPulseState(heartRate: reconciledHeartRate,
                              hasContact: ble.hasContact || reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact)
    }

    private static func makePulseSparklineState(ble: AtriaBLEManager) -> PulseSparklineState {
        PulseSparklineState(values: ble.liveHeartWindow.sparkline,
                            chartPoints: compactHeartChartPoints(Array(ble.session.suffix(900))))
    }

    private static func liveHeartRate(ble: AtriaBLEManager) -> Int {
        if ble.heartRate > 0 { return ble.heartRate }
        if let latest = ble.session.last, latest.bpm > 0,
           Date().timeIntervalSince(latest.t) <= 180 {
            return latest.bpm
        }
        if ble.status == .connected,
           let windowRate = ble.liveHeartWindow.sparkline.last(where: { $0 > 0 }) {
            return windowRate
        }
        if ble.status == .connected,
           let average = ble.liveHeartWindow.average,
           average > 0 {
            return average
        }
        return 0
    }

    private static func compactHeartChartPoints(_ samples: [HRSample], targetCount: Int = 120) -> [HeartRateChartPoint] {
        let valid = samples.filter { $0.bpm > 0 }
        guard valid.count > targetCount else {
            return valid.map { HeartRateChartPoint(t: $0.t, bpm: $0.bpm) }
        }
        let stride = Double(valid.count - 1) / Double(targetCount - 1)
        return (0..<targetCount).map { index in
            let sample = valid[Int((Double(index) * stride).rounded())]
            return HeartRateChartPoint(t: sample.t, bpm: sample.bpm)
        }
    }

    private static func makeCollectionLiveState(ble: AtriaBLEManager) -> CollectionLiveState {
        return CollectionLiveState(isRecording: ble.isRecording,
                                   capturedRows: ble.capturedRows,
                                   captureSummary: ble.captureSummary,
                                   captureWasValidationReady: ble.captureWasValidationReady,
                                   lastCaptureFile: ble.lastCaptureFile,
                                   standardHROnlyEnabled: ble.standardHROnlyEnabled,
                                   longWearModeEnabled: ble.longWearModeEnabled,
                                   rangeLossBackfillPending: ble.rangeLossBackfillPending,
                                   collectionProfile: ble.collectionProfile,
                                   officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk)
    }

    private static func makeHeroSnapshot(ble: AtriaBLEManager,
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
        let latestSleep = store.sleepHistorySnapshot.latest
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours,
                                          respiratoryRate: latestSleep?.respiratoryRate,
                                          respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
        let stress = stressState(ble: ble, baseline: store.baseline)
        let liveTRIMP = live.liveTRIMP
        let totalTRIMP = savedAggregate.savedTodayTRIMP + liveTRIMP
        let strain = Metrics.strain(fromTRIMP: totalTRIMP)
        let load = store.trainingLoadSummarySnapshot
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
                            loadReadinessText: load.readinessText,
                            loadACWRSignalText: load.acwrSignalText,
                            loadMonotonyText: load.monotonyText,
                            loadMonotonySignalText: load.monotonySignalText,
                            loadACWRDetailText: load.acwrDetailText,
                            loadMonotonyDetailText: load.monotonyDetailText,
                            loadSignalSummaryText: load.signalSummaryText,
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

    private static func stressState(ble: AtriaBLEManager, baseline: PersonalBaseline) -> StressState {
        guard let snapshot = ble.hrvSnapshot else {
            return StressState(value: "Learning",
                               detail: "Beat-to-beat window",
                               narrative: "Heart rate is live; stress appears once HRV-grade beat-to-beat windows are ready.")
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

    private static func fallbackHeroHRVState(ble: AtriaBLEManager,
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
            detail = hrvSettlingText(quality: ble.hrvQuality,
                                     liveHeartRate: liveHeartRate(ble: ble))
        }

        let narrative: String
        if store.latestReferenceValidatedHRV != nil {
            narrative = "Checked HRV is ready."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            narrative = "Beat-to-beat data is ready as personal-baseline HRV."
        } else if store.latestLocalRMSSD != nil {
            narrative = "Saved local RMSSD is ready as personal-baseline HRV."
        } else {
            narrative = "Atria keeps beat-to-beat capture light while the connection settles."
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

    private static func hrvSettlingText(quality: String, liveHeartRate: Int) -> String {
        guard liveHeartRate > 0 else { return quality }
        let normalized = quality.lowercased()
        if normalized.contains("stable contact")
            || normalized.contains("poor contact")
            || normalized.contains("poor_contact") {
            return "HRV settling"
        }
        return quality
    }

    private static func defaultHeroHeadline(status: AtriaBLEManager.Status) -> String {
        if status == .connected {
            return "Live connection is active."
        }
        return "A lighter dashboard that gets to your signal faster."
    }

    private static func defaultHeroNextAction(status: AtriaBLEManager.Status) -> String {
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
                            stressDetail: "Beat-to-beat window",
                            stressNarrative: "Stress appears after the strap reconnects and beat-to-beat data is ready.",
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
                            loadReadinessText: "Learning",
                            loadACWRSignalText: "Learning",
                            loadMonotonyText: "Learning",
                            loadMonotonySignalText: "Learning",
                            loadACWRDetailText: TrainingLoadSummary.learning.acwrDetailText,
                            loadMonotonyDetailText: TrainingLoadSummary.learning.monotonyDetailText,
                            loadSignalSummaryText: "Learning",
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
        let vo2 = store.vo2MaxEstimateSummary(rest: liveSessionDerived.rest,
                                              maxHR: store.profile.maxHR)
        return ProfileMetricsState(vo2MaxEstimate: vo2,
                                   biologicalAgeSummary: store.biologicalAgeSummary(vo2MaxEstimate: vo2))
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

    private static func makeDeferredDetails(ble: AtriaBLEManager, store: SessionStore) -> DeferredDetails {
        let diagnostics = store.homeDashboardDiagnostics()
        let validatedHRV = store.latestReferenceValidatedHRV
        let latestSleep = store.sleepHistorySnapshot.latest
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.hrvSnapshot,
                                          fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                          restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                          baseline: store.baseline,
                                          hrvReferenceValidated: validatedHRV != nil,
                                          sleepEfficiency: latestSleep?.sleepEfficiency,
                                          sleepDurationHours: latestSleep?.durationHours,
                                          respiratoryRate: latestSleep?.respiratoryRate,
                                          respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
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
            hrvDetail = hrvSettlingText(quality: ble.hrvQuality,
                                        liveHeartRate: liveHeartRate(ble: ble))
        }

        let hrvNarrative: String
        if store.latestReferenceValidatedHRV != nil {
            hrvNarrative = "Checked HRV is ready."
        } else if rrPackage.ready {
            hrvNarrative = "HRV-grade beat-to-beat data is ready as personal-baseline HRV."
        } else if let snapshot = ble.hrvSnapshot, snapshot.isReady {
            hrvNarrative = "Beat-to-beat data is ready as personal-baseline HRV."
        } else {
            hrvNarrative = hrvSettlingText(quality: ble.hrvQuality,
                                           liveHeartRate: liveHeartRate(ble: ble))
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
            rrPackageText = "\(rrPackage.rrSamples) beats"
        } else {
            rrPackageText = "Learning"
        }

        let referenceText = baselineMaturityText(sampleCount: store.baseline.hrvSampleCount)

        let headline: String
        if ble.status == .connected {
            headline = "Live connection is active."
        } else if rrPackage.ready {
            headline = "Saved beat-to-beat data is ready while the strap reconnects."
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
        sampleCount >= PersonalBaseline.trustedMinimumSamples ? "Ready" : "\(max(0, sampleCount))/\(PersonalBaseline.trustedMinimumSamples)"
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
                                               maxHR: Int,
                                               profile: AthleteProfile) -> LiveSessionDerived {
        LiveSessionDerived(sampleCount: samples.count,
                           lastTimestamp: samples.last?.t,
                           rest: rest,
                           maxHR: maxHR,
                           trimp: liveSessionTRIMP(samples, rest: rest, max: maxHR),
                           activeCalories: Metrics.dayCalories(samples.map {
                               Metrics.HeartRateEnergySample(t: $0.t, bpm: $0.bpm)
                           }, rest: rest, profile: profile))
    }

    private static func nextLiveSessionDerived(previous: LiveSessionDerived,
                                               samples: [HRSample],
                                               rest: Int,
                                               maxHR: Int,
                                               profile: AthleteProfile) -> LiveSessionDerived {
        guard previous.rest == rest,
              previous.maxHR == maxHR,
              (previous.activeCalories != nil) == profile.hasEnergyProfile,
              samples.count >= previous.sampleCount,
              previous.sampleCount > 0,
              previous.sampleCount <= samples.count,
              previous.lastTimestamp == samples[previous.sampleCount - 1].t else {
            return makeLiveSessionDerived(samples: samples, rest: rest, maxHR: maxHR, profile: profile)
        }

        guard samples.count > previous.sampleCount else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      rest: rest,
                                      maxHR: maxHR,
                                      trimp: previous.trimp,
                                      activeCalories: previous.activeCalories)
        }

        guard maxHR > rest else {
            return LiveSessionDerived(sampleCount: samples.count,
                                      lastTimestamp: samples.last?.t,
                                      rest: rest,
                                      maxHR: maxHR,
                                      trimp: 0,
                                      activeCalories: nil)
        }

        let span = Double(maxHR - rest)
        var total = previous.trimp
        var activeCalories = previous.activeCalories ?? 0
        for index in previous.sampleCount..<samples.count {
            let dtMin = samples[index].t.timeIntervalSince(samples[index - 1].t) / 60.0
            guard dtMin > 0, dtMin < 5 else { continue }
            let hrr = Swift.min(Swift.max((Double(samples[index].bpm) - Double(rest)) / span, 0), 1)
            total += dtMin * hrr * 0.64 * exp(1.92 * hrr)
            if profile.hasEnergyProfile {
                activeCalories += Metrics.dayCalories([
                    Metrics.HeartRateEnergySample(t: samples[index - 1].t, bpm: samples[index - 1].bpm),
                    Metrics.HeartRateEnergySample(t: samples[index].t, bpm: samples[index].bpm),
                ], rest: rest, profile: profile) ?? 0
            }
        }
        return LiveSessionDerived(sampleCount: samples.count,
                                  lastTimestamp: samples.last?.t,
                                  rest: rest,
                                  maxHR: maxHR,
                                  trimp: total,
                                  activeCalories: profile.hasEnergyProfile ? activeCalories : nil)
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

private struct AtriaToolbarIcon: View, Equatable {
    let symbol: String

    static func == (lhs: AtriaToolbarIcon, rhs: AtriaToolbarIcon) -> Bool {
        lhs.symbol == rhs.symbol
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.footnote.weight(.semibold))
            .imageScale(.small)
            .foregroundStyle(.primary)
    }
}

private struct AtriaHeaderActionButtonStyle: ButtonStyle {
    private static let size: CGFloat = AtriaHeaderControlMetrics.height

    func makeBody(configuration: Configuration) -> some View {
        AtriaGlassIconButtonStyle(tint: .secondary, size: Self.size)
            .makeBody(configuration: configuration)
    }
}

private struct AtriaHomeTopChrome: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    let store: SessionStore
    let showWorkout: Bool
    let showHelp: Bool
    let onStartWorkout: () -> Void
    let onShowHelp: () -> Void
    let onShowSettings: () -> Void
    let onTapStatusWhenNotConnected: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AtriaTopStatusChip(statusStore: statusStore,
                               pulseLiveStore: pulseLiveStore,
                               onTapWhenNotConnected: onTapStatusWhenNotConnected)

            Spacer(minLength: 12)

            HStack(spacing: AtriaHeaderControlMetrics.iconSpacing) {
                AtriaHeaderBatteryIndicator(liveStore: coreLiveStore)

                if showWorkout {
                    Button(action: onStartWorkout) {
                        AtriaToolbarIcon(symbol: "figure.run")
                    }
                    .buttonStyle(AtriaHeaderActionButtonStyle())
                    .accessibilityLabel("Start workout")
                }

                if showHelp {
                    Button(action: onShowHelp) {
                        AtriaToolbarIcon(symbol: "questionmark.circle")
                    }
                    .buttonStyle(AtriaHeaderActionButtonStyle())
                    .accessibilityLabel("Connection help")
                }

                NavigationLink {
                    HistoryView(store: store)
                } label: {
                    AtriaToolbarIcon(symbol: "clock.arrow.circlepath")
                }
                .buttonStyle(AtriaHeaderActionButtonStyle())
                .accessibilityLabel("History")

                Button(action: onShowSettings) {
                    AtriaToolbarIcon(symbol: "gearshape")
                }
                .buttonStyle(AtriaHeaderActionButtonStyle())
                .accessibilityLabel("Settings")
            }
            .frame(height: AtriaHeaderControlMetrics.height, alignment: .center)
            .fixedSize()
        }
        .frame(maxWidth: .infinity,
               minHeight: AtriaHeaderControlMetrics.height,
               maxHeight: AtriaHeaderControlMetrics.height,
               alignment: .center)
    }
}

private enum AtriaHeaderControlMetrics {
    static let height: CGFloat = 44
    static let statusMinWidth: CGFloat = 152
    static let iconSpacing: CGFloat = 6
}

private struct AtriaHeaderBatteryIndicator: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore

    private var tint: Color {
        switch liveStore.state.batteryChargeStatus {
        case .charging, .full: return .green
        case .notCharging: return .blue
        case .levelOnly: return liveStore.state.batteryLevel >= 0 ? .cyan : .gray
        }
    }

    var body: some View {
        Image(systemName: liveStore.state.batterySymbol)
            .font(.footnote.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: AtriaHeaderControlMetrics.height,
                   height: AtriaHeaderControlMetrics.height)
            .atriaChromeCapsule(tint: tint)
            .accessibilityLabel("Strap battery \(liveStore.state.batteryText), \(liveStore.state.batteryChargeText).")
    }
}

/// The top-left connection chip. A dedicated subview so it OBSERVES both stores —
/// status changes AND contact changes (so "No signal" appears the instant the
/// strap loses contact, even while the BLE link stays up).
private struct AtriaTopStatusChip: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    let onTapWhenNotConnected: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var status: AtriaBLEManager.Status { statusStore.state.status }
    private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }
    private var hasPulseSignal: Bool { pulseLiveStore.state.hasPulseSignal }
    private var displayStatus: AtriaBLEManager.Status {
        guard hasPulseSignal else { return status }
        switch status {
        case .poweredOff:
            return status
        case .connected, .connecting, .scanning, .disconnected:
            return .connected
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(label)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .font(.caption.weight(.bold))
        .foregroundStyle(foreground)
        .padding(.horizontal, 18)
        .frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,
               minHeight: AtriaHeaderControlMetrics.height,
               maxHeight: AtriaHeaderControlMetrics.height)
        .atriaChromeCapsule(tint: tint)
        .contentShape(Capsule())
        .onTapGesture {
            if displayStatus != .connected { onTapWhenNotConnected() }
        }
        .accessibilityLabel("Connection \(label)")
    }

    private var label: String {
        switch displayStatus {
        case .connected:
            // "Live" must mean actually reading your pulse, not just a BLE link.
            return hasPulseSignal ? "Live" : "No signal"
        case .connecting: return "Connecting"
        case .scanning: return "Searching"
        case .poweredOff: return bluetoothPermissionDenied ? "Permission" : "Bluetooth off"
        case .disconnected:
            return UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) > 0
                ? "Reconnecting…"
                : "Disconnected"
        }
    }

    private var symbol: String {
        switch displayStatus {
        case .connected: return hasPulseSignal ? "bolt.heart.fill" : "heart.slash"
        case .connecting, .scanning: return "dot.radiowaves.left.and.right"
        case .poweredOff: return bluetoothPermissionDenied ? "hand.raised.fill" : "bolt.slash.fill"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        switch displayStatus {
        case .connected: return hasPulseSignal ? .green : .orange
        case .connecting: return .yellow
        case .scanning: return .cyan
        case .poweredOff: return .red
        case .disconnected: return .blue
        }
    }

    private var foreground: Color {
        if colorScheme == .light {
            switch displayStatus {
            case .connected: return hasPulseSignal ? Color(red: 0.04, green: 0.42, blue: 0.20) : Color(red: 0.60, green: 0.34, blue: 0.00)
            case .connecting: return Color(red: 0.52, green: 0.36, blue: 0.00)
            case .scanning: return Color(red: 0.00, green: 0.36, blue: 0.46)
            case .poweredOff: return Color(red: 0.62, green: 0.10, blue: 0.10)
            case .disconnected: return Color(red: 0.10, green: 0.28, blue: 0.66)
            }
        }
        switch displayStatus {
        case .connected: return hasPulseSignal ? Color(red: 0.77, green: 1.00, blue: 0.86) : Color(red: 1.00, green: 0.86, blue: 0.62)
        case .connecting: return Color(red: 1.00, green: 0.91, blue: 0.54)
        case .scanning: return Color(red: 0.64, green: 0.95, blue: 1.00)
        case .poweredOff: return Color(red: 1.00, green: 0.72, blue: 0.72)
        case .disconnected: return Color(red: 0.74, green: 0.84, blue: 1.00)
        }
    }
}

private struct AtriaConnectionDiagnosis: Equatable {
    private static let lowBatteryThreshold = 20
    private static let pendingKnownReconnectActionAge: TimeInterval = 15

    let title: String
    let action: String
    let systemImage: String
    let tint: Color

    static func == (lhs: AtriaConnectionDiagnosis, rhs: AtriaConnectionDiagnosis) -> Bool {
        lhs.title == rhs.title
            && lhs.action == rhs.action
            && lhs.systemImage == rhs.systemImage
    }

    var showsImmediately: Bool {
        title == "Bluetooth is off"
            || title == "Bluetooth permission needed"
            || title == "Strap battery low"
    }

    var sendsLocalNotification: Bool {
        title == "Bluetooth is off"
            || title == "Strap battery low"
    }

    static func derive(live: AtriaHomeModel.CoreLiveState,
                       pulse: AtriaHomeModel.PulseLiveState,
                       officialAppInstalled: Bool) -> AtriaConnectionDiagnosis? {
        let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared
        let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected
        let pendingKnownReconnectAge = live.pendingKnownReconnectAge() ?? 0
        let pendingKnownReconnectActive = pendingKnownReconnectAge >= Self.pendingKnownReconnectActionAge

        switch live.status {
        case .poweredOff:
            if live.bluetoothPermissionDenied {
                return AtriaConnectionDiagnosis(title: "Bluetooth permission needed",
                                                action: "Allow Bluetooth for Atria in Settings.",
                                                systemImage: "hand.raised.fill",
                                                tint: .red)
            }
            return AtriaConnectionDiagnosis(title: "Bluetooth is off",
                                            action: "Turn on Bluetooth in Settings.",
                                            systemImage: "bolt.slash.fill",
                                            tint: .red)
        case .connected where pulse.needsContactCoach:
            return AtriaConnectionDiagnosis(title: "Fit check needed",
                                            action: "Tighten the strap fit so Atria can read pulse.",
                                            systemImage: "heart.slash",
                                            tint: .orange)
        case .connected where live.needsRRQualityCoach && !pulse.hasPulseSignal:
            return AtriaConnectionDiagnosis(title: "Beat-to-beat waiting",
                                            action: "Atria needs pulse before it can build HRV and Recovery.",
                                            systemImage: "waveform.path.ecg",
                                            tint: .orange)
        case .connected where live.needsRRQualityCoach && pulse.hasPulseSignal:
            return AtriaConnectionDiagnosis(title: "HRV settling",
                                            action: "Heart rate is live. Keep wearing normally while HRV settles.",
                                            systemImage: "waveform.path.ecg",
                                            tint: .green)
        case _ where live.batteryLevel >= 0 && live.batteryLevel <= Self.lowBatteryThreshold && live.batteryRecentlyDropping && !live.batteryIsCharging:
            return AtriaConnectionDiagnosis(title: "Strap battery low",
                                            action: "Charge your strap before a workout or overnight wear.",
                                            systemImage: "battery.25percent",
                                            tint: .yellow)
        case .connected where officialAppRiskActive && live.officialAppCoexistenceRisk == .suspected:
            return AtriaConnectionDiagnosis(title: "WHOOP may interrupt",
                                            action: "Close or uninstall WHOOP if readings fragment.",
                                            systemImage: "exclamationmark.triangle.fill",
                                            tint: .orange)
        case .connected where officialAppRiskActive:
            return AtriaConnectionDiagnosis(title: "WHOOP coexistence watch",
                                            action: "Atria is streaming; close WHOOP if drops return.",
                                            systemImage: "app.connected.to.app.below.fill",
                                            tint: .orange)
        case .scanning, .connecting:
            if officialAppRiskActive {
                return AtriaConnectionDiagnosis(title: "WHOOP app may interfere",
                                                action: "Keep the strap nearby and close WHOOP if it keeps reclaiming it.",
                                                systemImage: "exclamationmark.triangle.fill",
                                                tint: .orange)
            }
            if pendingKnownReconnectActive {
                return AtriaConnectionDiagnosis(title: "Strap out of range",
                                                action: "Atria is still reconnecting to your saved strap. Bring it closer or keep wearing it.",
                                                systemImage: "dot.radiowaves.left.and.right",
                                                tint: .cyan)
            }
            if stalePairingSuspected {
                return AtriaConnectionDiagnosis(title: "Connection keeps dropping",
                                                action: "Forget the strap in Bluetooth, then reconnect.",
                                                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                                                tint: .orange)
            }
            return AtriaConnectionDiagnosis(title: "Looking for your strap",
                                            action: "Bring your strap closer and keep it on your wrist.",
                                            systemImage: "dot.radiowaves.left.and.right",
                                            tint: .cyan)
        case .disconnected:
            if officialAppRiskActive {
                return AtriaConnectionDiagnosis(title: "WHOOP app may interfere",
                                                action: "Close or uninstall WHOOP if it keeps reclaiming the strap.",
                                                systemImage: "exclamationmark.triangle.fill",
                                                tint: .orange)
            }
            if pendingKnownReconnectActive {
                return AtriaConnectionDiagnosis(title: "Strap out of range",
                                                action: "Atria is still waiting for your saved strap. Bring it closer or keep wearing it.",
                                                systemImage: "dot.radiowaves.left.and.right",
                                                tint: .cyan)
            }
            if stalePairingSuspected {
                return AtriaConnectionDiagnosis(title: "Stale Bluetooth pairing",
                                                action: "Forget the strap in Bluetooth, then reconnect.",
                                                systemImage: "arrow.triangle.2.circlepath.circle.fill",
                                                tint: .orange)
            }
            return AtriaConnectionDiagnosis(title: "Strap disconnected",
                                            action: "Bring it closer. If it keeps failing, forget it in Bluetooth and reconnect.",
                                            systemImage: "bolt.horizontal.circle",
                                            tint: .blue)
        case .connected:
            return nil
        }
    }
}

private struct AtriaConnectionDiagnosisBanner: View, Equatable {
    let diagnosis: AtriaConnectionDiagnosis
    let onHelp: () -> Void

    static func == (lhs: AtriaConnectionDiagnosisBanner, rhs: AtriaConnectionDiagnosisBanner) -> Bool {
        lhs.diagnosis == rhs.diagnosis
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: diagnosis.systemImage)
                .font(.headline.weight(.semibold))
                .foregroundStyle(diagnosis.tint)
                .frame(width: 32, height: 32)
                .background(AtriaIconTileBackground(cornerRadius: 11, tint: diagnosis.tint))

            VStack(alignment: .leading, spacing: 3) {
                Text(diagnosis.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(diagnosis.action)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(2)

            Spacer(minLength: 0)

            Button(action: onHelp) {
                Image(systemName: "questionmark.circle")
                    .frame(width: 18, height: 18)
            }
            .atriaCardAction(prominent: false, tint: diagnosis.tint)
            .accessibilityLabel("Connection help")
        }
        .padding(12)
        .atriaInsetCard(tint: diagnosis.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnosis.title). \(diagnosis.action)")
    }
}
