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
    let bpmOverRest: Int
    let restingHeartRate: Int
    let maxHeartRate: Int

    var heartRateZone: Metrics.HeartRateZone? {
        Metrics.heartRateZone(bpm: heartRate, rest: restingHeartRate, max: maxHeartRate)
    }

    var confidenceLabel: String {
        if isReviewReady {
            return "Ready"
        }
        switch samples {
        case 720...:
            return "Strong signal"
        case 360...:
            return "Likely"
        default:
            return "Possible"
        }
    }

    var progressFraction: Double {
        min(max(Double(samples) / 720.0, 0.18), 1)
    }

    var evidenceMinutes: Int {
        max(1, Int((Double(samples) / 60.0).rounded()))
    }

    var reviewHint: String {
        isReviewReady ? "Review now" : "Keep wearing"
    }

    var isReviewReady: Bool {
        samples >= AtriaWorkoutPromptEvaluator.minimumSustainedSamples
            && bpmOverRest >= AtriaWorkoutPromptEvaluator.minimumBPMOverRest
    }

    var primaryTitle: String {
        isReviewReady ? "Review workout" : "Keep watching"
    }

    var headline: String {
        isReviewReady ? "Review this workout" : "Watching effort"
    }

    var subtitle: String {
        isReviewReady
            ? "Sustained strap HR is ready to confirm."
            : "Atria is waiting for a steadier strap rise."
    }

    var typeSuggestions: [String] {
        strain >= 6 || bpmOverRest >= 45
            ? ["Strength", "Cardio", "Mixed"]
            : ["Walk", "Strength", "Mobility"]
    }

    var exerciseSuggestions: [String] {
        strain >= 6 || bpmOverRest >= 45
            ? ["Chest", "Triceps", "Abs"]
            : ["Walk", "Core", "Stretch"]
    }

    var suggestedActivityType: AtriaWorkoutActivityType {
        if typeSuggestions.contains("Walk") {
            return .walking
        }
        if typeSuggestions.contains("Cardio"), strain >= 8 || bpmOverRest >= 55 {
            return .cardio
        }
        if typeSuggestions.contains("Mobility") {
            return .mobility
        }
        return .strength
    }

    var suggestedActivityTypes: [AtriaWorkoutActivityType] {
        var resolved: [AtriaWorkoutActivityType] = []
        for suggestion in typeSuggestions {
            guard let type = AtriaWorkoutActivityType(suggestion: suggestion),
                  !resolved.contains(type) else { continue }
            resolved.append(type)
        }
        if !resolved.contains(suggestedActivityType) {
            resolved.insert(suggestedActivityType, at: 0)
        }
        return Array(resolved.prefix(3))
    }
}

fileprivate struct AtriaWorkoutReviewDraft: Identifiable, Equatable {
    let id = UUID()
    let prompt: AtriaWorkoutDetectionPrompt
    let suggestedStart: Date
    let suggestedEnd: Date
    var strengthSets: [LoggedSet] = []
    var strengthHistorySessions: [SavedSession] = []

    static func == (lhs: AtriaWorkoutReviewDraft, rhs: AtriaWorkoutReviewDraft) -> Bool {
        lhs.id == rhs.id
            && lhs.prompt == rhs.prompt
            && lhs.suggestedStart == rhs.suggestedStart
            && lhs.suggestedEnd == rhs.suggestedEnd
            && lhs.strengthSets == rhs.strengthSets
            && lhs.strengthHistorySessions.map(\.id) == rhs.strengthHistorySessions.map(\.id)
    }
}

fileprivate struct AtriaWorkoutReviewResult: Equatable {
    let start: Date
    let end: Date
    let activityType: String
    let activitySubtype: String?
    let exerciseNames: [String]
    let strengthSets: [LoggedSet]
}

fileprivate enum AtriaWorkoutReviewStep: Int, CaseIterable {
    case time
    case type
    case exercises
    case summary

    var title: String {
        switch self {
        case .time: return "Time"
        case .type: return "Type"
        case .exercises: return "Exercises"
        case .summary: return "Save"
        }
    }
}

fileprivate struct AtriaConnectionDiagnosisLiveTrigger: Equatable {
    let status: AtriaBLEManager.Status
    let bluetoothPermissionDenied: Bool
    let batteryLevel: Int
    let batteryIsCharging: Bool
    let batteryRecentlyDropping: Bool
    let rrContinuityState: String
    let hasRecentHeartRateSample: Bool
    let officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
    let lastScanRequestedAt: Date?
    let lastScanMatchAt: Date?
    let pendingKnownReconnectStartedAt: Date?
    let rangeLossBackfillPending: Bool

    init(_ state: AtriaHomeModel.CoreLiveState) {
        status = state.status
        bluetoothPermissionDenied = state.bluetoothPermissionDenied
        batteryLevel = state.batteryLevel
        batteryIsCharging = state.batteryIsCharging
        batteryRecentlyDropping = state.batteryRecentlyDropping
        rrContinuityState = state.rrContinuityState
        hasRecentHeartRateSample = state.hasRecentHeartRateSample
        officialAppCoexistenceRisk = state.officialAppCoexistenceRisk
        lastScanRequestedAt = state.lastScanRequestedAt
        lastScanMatchAt = state.lastScanMatchAt
        pendingKnownReconnectStartedAt = state.pendingKnownReconnectStartedAt
        rangeLossBackfillPending = state.rangeLossBackfillPending
    }
}

fileprivate struct AtriaConnectionDiagnosisPulseTrigger: Equatable {
    let hasPulseSignal: Bool
    let sensorHasContact: Bool

    init(_ state: AtriaHomeModel.PulseLiveState) {
        hasPulseSignal = state.hasPulseSignal
        sensorHasContact = state.sensorHasContact
    }
}

#if DEBUG
private enum AtriaScreenshotShowcase {
    struct HomeModelSnapshot {
        let status: AtriaHomeModel.StatusState
        let coreLive: AtriaHomeModel.CoreLiveState
        let heroPulse: AtriaHomeModel.HeroPulseState
        let pulseLive: AtriaHomeModel.PulseLiveState
        let pulseSparkline: AtriaHomeModel.PulseSparklineState
        let collectionLive: AtriaHomeModel.CollectionLiveState
        let hero: AtriaHomeModel.HeroSnapshot
        let snapshot: AtriaHomeModel.Snapshot
        let homeStats: AtriaHomeModel.HomeStatsState
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("live-zone")
    }
    static func homeModelSnapshot() -> HomeModelSnapshot? { nil }
}
#endif

struct AtriaHomeView: View {
    private static let connectionDiagnosisPersistenceDelay: TimeInterval = 15
    private static let connectionDiagnosisTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    private static let strainTargetGuidanceRefreshInterval: TimeInterval = 10 * 60
    private static let strainTargetGuidanceTimer = Timer.publish(every: strainTargetGuidanceRefreshInterval, on: .main, in: .common).autoconnect()
    private static let liveWidgetSnapshotMinimumInterval: TimeInterval = 45
    private static let liveWidgetSnapshotMeaningfulChangeInterval: TimeInterval = 15
    private static let liveWidgetSnapshotMeaningfulBPMDelta = 4
    private static let workoutPromptCooldown: TimeInterval = AtriaWorkoutPromptEvaluator.cooldown
    private static let workoutReviewSettleBPMOverRest = 20
    private static let workoutReviewRecentEndHoldSeconds: TimeInterval = 15 * 60
    private static let workoutReviewDismissedIDKey = "atria.workoutReview.dismissedID"
    private static let workoutReviewDismissedIDsKey = "atria.workoutReview.dismissedIDs"
    private static let workoutReviewDismissedIDsLimit = 24

    private struct AtriaWorkoutEndNotice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
    }

    private enum HomeTab: String, CaseIterable, Identifiable {
        case overview
        case vitals
        case journal
        case chat
        case collection

        var id: String { rawValue }

        var deepLinkPath: String {
            switch self {
            case .overview: return "overview"
            case .vitals: return "vitals"
            case .journal: return "journal"
            case .chat: return "chat"
            case .collection: return "strap"
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
            case "journal": return .journal
            case "chat": return .chat
            // Static handoff compatibility marker for the previous aliases:
            // case "data", "collection": return .collection
            case "strap", "data", "collection": return .collection
            default: return nil
            }
        }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .vitals: return "Vitals"
            case .journal: return "Journal"
            case .chat: return "Assistant"
            case .collection: return "Strap"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "house.fill"
            case .vitals: return "heart.text.square"
            case .journal: return "square.and.pencil"
            case .chat: return "bubble.left.and.bubble.right.fill"
            case .collection: return "applewatch.radiowaves.left.and.right"
            }
        }
    }

    fileprivate enum WorkoutReviewHoldState: Equatable {
        case waitingForSettle(bpmOverRest: Int)
        case possibleSignal(reason: String)

        var title: String {
            switch self {
            case .waitingForSettle:
                return "Still watching effort"
            case .possibleSignal:
                return "Possible effort saved"
            }
        }

        var detail: String {
            switch self {
            case .waitingForSettle(let bpmOverRest):
                return "HR is still +\(bpmOverRest) over rest. Atria waits before asking."
            case .possibleSignal:
                return "Saved as possible effort. Atria will ask when the strap signal is stronger."
            }
        }

        var accessibilityText: String {
            switch self {
            case .waitingForSettle(let bpmOverRest):
                return "Workout review held while heart rate settles. Current heart rate is \(bpmOverRest) beats per minute over rest."
            case .possibleSignal:
                return "Workout review held because the strap signal looks like possible effort, not a strong workout."
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
    @State private var showStrapScreen = false
    @State private var showShareSheet = false
    @State private var incomingFaceOff: AtriaFaceOffPayload?
    // Plain read, not @AppStorage: this key has dots, which is the exact
    // KVO-storm hazard documented above for persistentHeartRateBroadcastEnabled
    // and homeLayoutConfigStorage (~790 evals/sec self-invalidation, 0x8BADF00D
    // crash loop, 2026-07-03) — this app writes "atria.*"-prefixed diagnostics
    // keys constantly, and a dotted @AppStorage key path re-fires on ANY of
    // them. AtriaHomeView never writes this value (AtriaSettingsView's own
    // TextField is the sole writer), so a live UserDefaults read at the two
    // use sites below is equivalent with zero subscription overhead.
    private var faceOffDisplayName: String {
        UserDefaults.standard.string(forKey: "atria.faceoff.displayName") ?? ""
    }
    @State private var showCustomizeSheet = false
    @State private var showWidgetProofSheet = false
    @State private var widgetProofSnapshot: WidgetSnapshot?
    @State private var workoutSession: AtriaWorkoutSession?
    @State private var liveWorkoutLoggedSets: [LoggedSet] = []
    @State private var liveWorkoutExcludedIntervals: [ExcludedInterval] = []
    @State private var liveWorkoutMinimized = false
    @State private var workoutEndNotice: AtriaWorkoutEndNotice?
    @State private var showCoexistenceModal = false
    @State private var officialAppInstalled: Bool = {
        guard let url = URL(string: "whoop://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }()
    @State private var didApplyDebugUIScreenLaunchArgument = false
    // Static handoff compatibility marker for the old segment state:
    // @State private var debugInitialOverviewSegment: AtriaTodaySegment = .today
    // @State private var activeOverviewSegment: AtriaTodaySegment = .today
    // _activeOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)
    // private static func debugLaunchOverviewSegmentArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> AtriaTodaySegment?
    // return AtriaTodaySegment.debugLaunchValue(from: arguments[arguments.index(after: segmentIndex)])
    // onSegmentChange: { segment in
    // activeOverviewSegment = segment
    @State private var debugInitialOverviewSegment: AtriaLegacyOverviewDestination = .today
    @State private var debugShowsOverviewSegmentContent = false
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
    @StateObject private var heartRateBroadcaster = AtriaHeartRateBroadcaster()
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
    @State private var workoutReviewDraft: AtriaWorkoutReviewDraft?
    @State private var savedWorkoutReviewCandidate: WorkoutReviewCandidate?
    @State private var workoutReviewHoldState: WorkoutReviewHoldState?
    @State private var showConnectivityPill = false
    @State private var connectivityPillTask: Task<Void, Never>?
    @State private var showJournalSheet = false
    @State private var workoutHeartRateBroadcastEnabled = false
    // Plain @State, not @AppStorage, for the same dotted-key KVO storm reason
    // as persistentHeartRateBroadcastEnabled below — after that key was fixed,
    // this one became the next storm driver (validated with _printChanges).
    // This view is the only writer; saveHomeLayoutConfig persists explicitly.
    @State private var homeLayoutConfigStorage = UserDefaults.standard.string(forKey: AtriaHomeLayoutConfig.storageKey) ?? ""
    // Deliberately NOT @AppStorage: the key contains dots, and UserDefaults KVO
    // treats dotted keys as key paths, so the observation fires for writes to
    // ANY `atria.*` key. This app writes diagnostics keys constantly (including
    // from this body's own onReceive side effects), which turned the AppStorage
    // subscription into a ~790 evals/sec self-invalidation storm that blew the
    // scene-create watchdog whenever broadcast was enabled and HR was live
    // (0x8BADF00D crash loop, 2026-07-03). Plain @State + explicit persistence
    // keeps the same behavior without the KVO subscription.
    @State private var persistentHeartRateBroadcastEnabled = AtriaHeartRateBroadcastPreference.isEnabled

    init(ble: AtriaBLEManager, store: SessionStore) {
        self.ble = ble
        self.store = store
        let debugOverviewSegment = Self.debugLaunchOverviewSegmentArgument()
#if DEBUG
        let showsShowcaseFixture = AtriaScreenshotShowcase.isActive
#else
        let showsShowcaseFixture = false
#endif
        _debugInitialOverviewSegment = State(initialValue: debugOverviewSegment ?? .today)
        _debugShowsOverviewSegmentContent = State(initialValue: debugOverviewSegment != nil || showsShowcaseFixture)
        _model = State(initialValue: AtriaHomeModel(ble: ble, store: store))
    }

    var body: some View {
        homeShellCore
        .onAppear {
            // Run appear work AFTER the first frame commits. onAppear fires
            // mid-first-commit; mutating state here (content unlock, broadcast
            // setup) re-invalidates the graph before anything is on screen,
            // which under live BLE churn blew the 10-20s scene-create watchdog
            // (0x8BADF00D crash loop, 2026-07-03).
            Task { @MainActor in
                handleHomeAppear()
            }
        }
        .onChange(of: selectedTab) { _, tab in
            handleSelectedTabChange(tab)
        }
        .sensoryFeedback(.selection, trigger: selectedTab)
        .sensoryFeedback(trigger: workoutEndNotice) { _, notice in
            notice == nil ? nil : .success
        }
        .onChange(of: hasUnlockedSecondarySections) { _, unlocked in
            guard unlocked else { return }
            logSecondaryContentReadyIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            handleHomeScenePhaseChange(phase)
        }
        .onChange(of: hapticSettings) { _, settings in
            settings.save()
            updateHapticCoordinator()
        }
        .onChange(of: persistentHeartRateBroadcastEnabled) { _, _ in
            updateHeartRateBroadcastState(reason: "settings")
        }
        .onChange(of: workoutHeartRateBroadcastEnabled) { _, _ in
            updateHeartRateBroadcastState(reason: "workout_toggle")
        }
        .onChange(of: workoutSession == nil) { _, ended in
            if ended {
                workoutHeartRateBroadcastEnabled = false
            }
            updateHeartRateBroadcastState(reason: ended ? "workout_end" : "workout_start")
        }
        .onChange(of: aiCoachSettings) { _, settings in
            settings.save()
            refreshAICoachKeyState()
        }
        .onReceive(model.heroPulseStore.$state) { state in
            heartRateBroadcaster.publish(heartRate: state.heartRate)
        }
        .onReceive(heartRateBroadcaster.$isBroadcasting.removeDuplicates()) { active in
            model.setHeartRateBroadcastActive(active)
        }
        .onReceive(liveSideEffectUpdates) { _ in
            updateLiveActivity()
            updateHapticCoordinator()
            publishLiveWidgetSnapshotIfNeeded()
            updateWorkoutDetectionPrompt()
        }
        .onReceive(store.$dashboardRevision.throttle(for: .seconds(3), scheduler: RunLoop.main, latest: true)) { _ in
            refreshSavedWorkoutReviewCandidate(reason: "dashboard_revision")
            WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: "dashboard_revision")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in
            batteryState = UIDevice.current.batteryState
        }
        .onReceive(NotificationCenter.default.publisher(for: NotificationDeliveryLogger.deepLinkNotification)) { notification in
            guard let url = notification.object as? URL else { return }
            handleDeepLink(url)
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

    private var homeShellCore: some View {
        ZStack {
            AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            TabView(selection: $selectedTab) {
                tabNavigation(title: "Today", showsHero: false) {
                    if hasUnlockedPrimaryContent {
                        overviewContent
                    } else {
                        secondaryLoadingCard(title: "Preparing overview",
                                             subtitle: "")
                    }
                }
                .tabItem { Label(HomeTab.overview.title, systemImage: HomeTab.overview.systemImage) }
                .tag(HomeTab.overview)

                tabNavigation(title: "Vitals", showsHero: false) {
                    if hasUnlockedPrimaryContent {
                        vitalsContent
                    } else {
                        secondaryLoadingCard(title: "Preparing vitals",
                                             subtitle: "")
                    }
                }
                .tabItem { Label(HomeTab.vitals.title, systemImage: HomeTab.vitals.systemImage) }
                .tag(HomeTab.vitals)

                tabNavigation(title: "Journal", showsHero: false) {
                    if hasUnlockedPrimaryContent {
                        journalContent
                    } else {
                        secondaryLoadingCard(title: "Preparing journal",
                                             subtitle: "")
                    }
                }
                .tabItem { Label(HomeTab.journal.title, systemImage: HomeTab.journal.systemImage) }
                .tag(HomeTab.journal)

                tabNavigation(title: "Assistant", showsHero: false) {
                    chatComingSoonContent
                }
                .tabItem { Label(HomeTab.chat.title, systemImage: HomeTab.chat.systemImage) }
                .tag(HomeTab.chat)
            }
            .tabBarMinimizeBehavior(.onScrollDown)
            .tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory && (selectedTab != .overview || liveWorkoutMinimized)) {
                AtriaLiveTabAccessory(liveStore: model.coreLiveStore,
                                      pulseStore: model.pulseLiveStore,
                                      workoutStart: workoutSession?.start,
                                      strain: model.heroStore.state.strain,
                                      onOpenWorkout: reopenMinimizedWorkout)
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
            .presentationDetents([.fraction(0.62), .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            AtriaSettingsView(profile: model.profileStore.profile,
                              restingBaseline: store.baseline.restingInt,
                              strapName: ble.resolvedDeviceName,
                              strapModel: ble.strapModelLabel,
                              strapGenerationDetail: ble.strapGenerationDetail,
                              strapFirmware: ble.firmwareRevision,
                              onRenameStrap: { ble.setCustomDeviceName($0) },
                              onUpdateProfile: store.updateProfile,
                              hapticSettings: hapticSettings,
                              onUpdateHaptics: { hapticSettings = $0 },
                              heartRateBroadcastEnabled: persistentHeartRateBroadcastEnabled,
                              onUpdateHeartRateBroadcast: {
                                  persistentHeartRateBroadcastEnabled = $0
                                  AtriaHeartRateBroadcastPreference.setEnabled($0)
                              },
                              batterySaverEnabled: ble.standardHROnlyEnabled,
                              onUpdateBatterySaver: { ble.setStandardHROnlyEnabled($0) },
                              onCustomizeToday: {
                                  showSettings = false
                                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                      showCustomizeSheet = true
                                  }
                              },
                              maxHRSuggestion: debugMaxHRSuggestion ?? store.cachedMaxHRSuggestion,
                              onDismissMaxHRSuggestion: { observedPeak in
                                  store.dismissMaxHRSuggestion(observedPeak: observedPeak)
                              },
                              onExportHealth: { store.exportToHealthKit() },
                              buildResearchBundle: { await AtriaResearchBundleBuilder.build(store: store) },
                              onSyncMissedData: {
                                  _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "manual_user_request",
                                                                              force: true)
                              },
                              onNutritionHealthToggle: { store.requestNutritionReadAuthorizationIfEnabled() },
                              backupStatusProvider: { store.sessionBackupStatus() },
                              onWriteBackup: {
                                  _ = store.writeSessionBackup(label: "settings")
                                  return store.sessionBackupStatus()
                              },
                              onVerifyBackup: { store.verifyLatestSessionBackup() },
                              onRestoreBackup: { url in
                                  guard store.restoreSessionBackup(from: url) else { return nil }
                                  return store.sessionBackupStatus()
                              },
                              onForgetStrap: { ble.forgetSavedStrap(reason: "user_settings") },
                              researchValidationContent: developerModeEnabled ? AnyView(researchValidationContent) : nil)
        }
        .sheet(isPresented: $showShareSheet) {
            AtriaShareSheet(snapshot: makeTodayShareSnapshot(),
                            challengeURL: makeFaceOffChallengeURL())
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $incomingFaceOff) { payload in
            AtriaFaceOffView(friend: payload,
                             mine: AtriaFaceOff.makePayload(name: faceOffDisplayName,
                                                            history: store.dailyMetricHistory))
        }
        .sheet(isPresented: $showCustomizeSheet) {
            AtriaCustomizeSheet(initialConfig: currentHomeLayoutConfig) { config in
                saveHomeLayoutConfig(config)
            }
        }
        .sheet(isPresented: $showWidgetProofSheet) {
            AtriaWidgetProofSheet(snapshot: widgetProofSnapshot,
                                  layoutConfig: currentHomeLayoutConfig)
        }
        .fullScreenCover(isPresented: liveWorkoutPresentationBinding) {
            if let session = workoutSession {
                AtriaLiveWorkoutView(pulseStore: model.pulseLiveStore,
                                     heroStore: model.heroStore,
                                     liveStore: model.coreLiveStore,
                                     maxHR: store.profile.maxHR,
                                     strainTarget: model.heroStore.state.guidance.target,
                                     startDate: session.start,
                                     strengthHistorySessions: store.sessions,
                                     loggedSets: $liveWorkoutLoggedSets,
                                     excludedIntervals: $liveWorkoutExcludedIntervals,
                                     heartRateBroadcastEnabled: $workoutHeartRateBroadcastEnabled,
                                     broadcastPersistsAfterWorkout: persistentHeartRateBroadcastEnabled,
                                     onMinimize: { liveWorkoutMinimized = true },
                                     onStop: { endWorkoutSession(startedAt: session.start,
                                                                 strengthSets: liveWorkoutLoggedSets,
                                                                 excludedIntervals: liveWorkoutExcludedIntervals) })
            }
        }
        .sheet(item: $workoutReviewDraft) { draft in
            AtriaWorkoutReviewFlow(draft: draft) {
                workoutReviewDraft = nil
            } onSave: { result in
                saveWorkoutReview(result)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCoexistenceModal) {
            AtriaCoexistenceModal(context: connectionGuideContext) {
                acknowledgeCoexistenceModal(reason: "button")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showJournalSheet) {
            NavigationStack {
                ScrollView(showsIndicators: false) {
                    AtriaOverviewMorningJournalHost(snapshotStore: model.snapshotStore,
                                                    store: store)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
                }
                .scrollContentBackground(.hidden)
                .background {
                    AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                        .ignoresSafeArea()
                }
                .navigationTitle("Journal")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showJournalSheet = false
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showStrapScreen) {
            NavigationStack {
                ScrollView {
                    if hasUnlockedPrimaryContent {
                        collectionContent
                            .padding(.horizontal, 16)
                    } else {
                        secondaryLoadingCard(title: "Preparing strap",
                                             subtitle: "")
                    }
                }
                .scrollContentBackground(.hidden)
                .background {
                    AtriaBackdropLayer(isDark: isDark, reduceTransparency: reduceTransparency)
                        .ignoresSafeArea()
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            showStrapScreen = false
                        }
                    }
                }
            }
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
        .onReceive(connectionDiagnosisUpdates) { _ in
            updateConnectionDiagnosisVisibility(reason: "connection_trigger")
        }
        .onReceive(Self.connectionDiagnosisTimer) { _ in
            // Idle discipline: the 5 s tick does nothing unless the scene is
            // actually on screen — a backgrounded app must be quiescent.
            guard scenePhase == .active else { return }
            updateConnectionDiagnosisVisibility(reason: "timer")
        }
    }

    private func handleDeepLink(_ url: URL) {
        if let faceOff = AtriaFaceOff.payload(from: url) {
            AtriaDebugLog("ATRIADBG faceoff_link status=decoded name_len=%d days=%d avg_recovery=%@",
                          faceOff.name.count,
                          faceOff.days.count,
                          faceOff.averageRecovery.map(String.init) ?? "nil")
            incomingFaceOff = faceOff
            hasUnlockedPrimaryContent = true
            return
        }
        guard let tab = HomeTab.deepLinkDestination(for: url) else { return }
#if DEBUG
        if url.absoluteString.lowercased().contains("heart-rate-timeline") {
            UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)
        }
#endif
        if tab == .collection {
            showStrapScreen = true
        } else {
            selectedTab = tab
        }
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

    private func postDebugNotificationDeepLinkIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-notification-deeplink-overview"),
              let url = URL(string: "atria://overview") else { return }
        AtriaDebugLog("ATRIADBG notification_deeplink_fixture status=posted url=%@",
                      url.absoluteString)
        Task { @MainActor in
            NotificationCenter.default.post(name: NotificationDeliveryLogger.deepLinkNotification, object: url)
        }
#endif
    }

    private func enableDebugHeartRateBroadcastIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-hr-broadcast") else { return }
        persistentHeartRateBroadcastEnabled = true
        AtriaDebugLog("ATRIADBG hr_broadcast_fixture status=enabled persistent=1")
        updateHeartRateBroadcastState(reason: "debug_fixture")
#endif
    }

    private func triggerDebugStrainTargetHapticIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard arguments.contains("--atria-test-strain-target-haptic") else { return }
        AtriaDebugLog("ATRIADBG haptic_alert_fixture kind=strain_target status=requested")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            hapticCoordinator.update(AtriaHapticAlertCoordinator.Snapshot(status: .connected,
                                                                          isRecording: true,
                                                                          heartRate: 120,
                                                                          maxHR: 190,
                                                                          batteryLevel: 85,
                                                                          recoveryPercent: 68,
                                                                          strain: 12.4,
                                                                          strainTarget: 12.0,
                                                                          settings: AtriaHapticAlertSettings()))
        }
#endif
    }

    private var contentWidth: CGFloat {
        horizontalSizeClass == .regular ? 1120 : 720
    }

    private var shouldShowLiveAccessory: Bool {
#if DEBUG
        if Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments) {
            return true
        }
#endif
        return model.statusStore.state.status == .connected
            && model.coreLiveStore.state.status == .connected
    }

    private var liveWorkoutPresentationBinding: Binding<Bool> {
        Binding {
            workoutSession != nil && !liveWorkoutMinimized
        } set: { presented in
            if !presented, workoutSession != nil {
                liveWorkoutMinimized = true
            }
        }
    }

    private func reopenMinimizedWorkout() {
        guard workoutSession != nil else { return }
        liveWorkoutMinimized = false
    }

    /// Memoizes the merged side-effect publishers. Building them in a computed
    /// property recreated them on EVERY body evaluation, which tore down the
    /// onReceive subscription and reset the 750 ms throttle each time — under
    /// churny invalidation the throttle never gated and the side-effect work
    /// (Live Activity, widget snapshot, haptics) ran per-tick on main.
    private final class AtriaHomePublisherCache {
        var liveSideEffects: AnyPublisher<Void, Never>?
        var connectionDiagnosis: AnyPublisher<Void, Never>?
    }

    @State private var publisherCache = AtriaHomePublisherCache()

    private var liveSideEffectUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.liveSideEffects { return cached }
        let publisher = Publishers.MergeMany([
            model.coreLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.pulseLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.collectionLiveStore.$state.map { _ in () }.eraseToAnyPublisher(),
            model.heroStore.$state.map { _ in () }.eraseToAnyPublisher(),
            mediaController.$state.map { _ in () }.eraseToAnyPublisher(),
            Self.strainTargetGuidanceTimer.map { _ in () }.eraseToAnyPublisher()
        ])
        .throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)
        .eraseToAnyPublisher()
        publisherCache.liveSideEffects = publisher
        return publisher
    }

    private var connectionDiagnosisUpdates: AnyPublisher<Void, Never> {
        if let cached = publisherCache.connectionDiagnosis { return cached }
        let publisher = Publishers.CombineLatest(
            model.coreLiveStore.$state
                .map(AtriaConnectionDiagnosisLiveTrigger.init)
                .removeDuplicates(),
            model.pulseLiveStore.$state
                .map(AtriaConnectionDiagnosisPulseTrigger.init)
                .removeDuplicates()
        )
        .map { _ in () }
        .eraseToAnyPublisher()
        publisherCache.connectionDiagnosis = publisher
        return publisher
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
                case .journal:
                    selectedTab = .journal
                case .collection:
                    showStrapScreen = true
                }
            }
        case .capture(let command):
            if command == .start && !ble.isRecording {
                ble.toggleRecording()
            } else if command == .stop && ble.isRecording {
                ble.toggleRecording()
            }
            performMotionAwareUpdate {
                showStrapScreen = true
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
                showStrapScreen = true
            }
        }
    }

    private func applyDebugUIScreenLaunchArgumentIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
#if DEBUG
        guard !didApplyDebugUIScreenLaunchArgument else { return }
        let requestedScreen: String
        if arguments.contains("--atria-open-settings") {
            requestedScreen = "settings"
        } else if let debugScreen = Self.debugRequestedUIScreen(arguments: arguments) {
            requestedScreen = debugScreen
        } else {
            requestedScreen = "overview"
        }

        let requestedOverviewSegment = Self.debugLaunchOverviewSegmentArgument(arguments: arguments)
        let metricDetailFixtures = ["recovery-detail", "recovery-detail-nutrition", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"]
        let shouldOpenMetricDetailFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { metricDetailFixtures.contains($0) } ?? false
        let overviewContentFixtures = ["sleep-plan-bedtime", "north-star-highlights"]
        let shouldShowOverviewFixture = Self.debugLaunchFixtureValue(arguments: arguments).map { overviewContentFixtures.contains($0) } ?? false
        let shouldOpenShareSheet = arguments.contains("--atria-open-share-sheet")
        let shouldOpenCustomizeSheet = arguments.contains("--atria-open-customize")
        let shouldOpenWidgetProof = arguments.contains("--atria-open-widget-proof")
        let shouldOpenConnectionGuide = arguments.contains("--atria-open-connection-guide")
        let shouldOpenJournalSheet = arguments.contains("--atria-open-journal")
        let shouldStartWorkout = arguments.contains("--atria-start-workout")
        let shouldSeedCustomLayout = arguments.contains("--atria-seed-custom-layout")
        let shouldSeedStrengthWorkoutProof = arguments.contains("--atria-seed-strength-workout-proof")
        let shouldOpenHeartRateTimeline = Self.debugLaunchFixtureValue(arguments: arguments) == "heart-rate-timeline"
        let shouldShowConnectivityPillFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "refresh-connectivity-pill"
        guard requestedScreen != "overview"
                || requestedOverviewSegment != nil
                || shouldOpenMetricDetailFixture
                || shouldShowOverviewFixture
                || arguments.contains("--atria-open-settings")
                || shouldOpenShareSheet
                || shouldOpenCustomizeSheet
                || shouldOpenWidgetProof
                || shouldOpenConnectionGuide
                || shouldOpenJournalSheet
                || shouldStartWorkout
                || shouldSeedCustomLayout
                || shouldSeedStrengthWorkoutProof
                || shouldOpenHeartRateTimeline
                || shouldShowConnectivityPillFixture else {
            return
        }

        didApplyDebugUIScreenLaunchArgument = true
        hasUnlockedPrimaryContent = true
        hasUnlockedSecondarySections = true
        if shouldOpenHeartRateTimeline {
            UserDefaults.standard.set(true, forKey: AtriaHealthScreen.debugOpenHeartRateTimelineKey)
        }
        if shouldShowConnectivityPillFixture {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(800))
                await handleConnectivityRefresh()
            }
        }
        if shouldSeedCustomLayout {
            saveHomeLayoutConfig(Self.debugSeededHomeLayoutConfig())
            selectedTab = .overview
        }
        if shouldSeedStrengthWorkoutProof {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                store.seedDebugStrengthWorkoutProofIfRequested(arguments: arguments)
            }
        }
        if let requestedOverviewSegment {
            debugInitialOverviewSegment = requestedOverviewSegment
            debugShowsOverviewSegmentContent = true
        }
        if shouldOpenMetricDetailFixture {
            debugShowsOverviewSegmentContent = true
        }
        if shouldShowOverviewFixture {
            debugShowsOverviewSegmentContent = true
        }
        if shouldOpenShareSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showShareSheet = true
            }
            return
        }
        if shouldOpenCustomizeSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showCustomizeSheet = true
            }
            return
        }
        if shouldOpenWidgetProof {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                widgetProofSnapshot = WidgetSnapshotPublisher.publish(store: store,
                                                                      ble: ble,
                                                                      reason: "cd11_widget_proof")
                showWidgetProofSheet = true
            }
            return
        }
        if shouldOpenConnectionGuide {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showConnectionGuide = true
            }
        }
        if shouldOpenJournalSheet {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                showJournalSheet = true
            }
        }
        if shouldStartWorkout {
            selectedTab = .overview
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                liveWorkoutLoggedSets = []
                liveWorkoutExcludedIntervals = []
                liveWorkoutMinimized = false
                workoutSession = AtriaWorkoutSession(start: Date())
            }
        }
        switch requestedScreen {
        case "today", "overview":
            selectedTab = requestedOverviewSegment == .trends ? .vitals : .overview
        case "vitals":
            selectedTab = .vitals
        // Static handoff compatibility marker for the previous debug route:
        // case "data", "collection", "history":
        case "journal":
            selectedTab = .journal
        case "chat":
            selectedTab = .chat
        case "strap", "data", "collection", "history":
            showStrapScreen = true
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
            if requestedOverviewSegment == .trends {
                selectedTab = .vitals
            } else {
                selectedTab = .overview
            }
        }
#endif
    }

    private var debugMaxHRSuggestion: AtriaMaxHRSuggestion? {
#if DEBUG
        guard Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "max-hr-suggestion" else {
            return nil
        }
        return AtriaMaxHRSuggestion(observedPeak: 193, currentMaxHR: 190)
#else
        return nil
#endif
    }

    #if DEBUG
    private static func debugLaunchFixtureValue(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_FIXTURE"],
           !environmentValue.isEmpty {
            return environmentValue
        }
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex]
    }

    private static func debugWorkoutLoggedSets(arguments: [String]) -> [LoggedSet] {
        guard ["live-workout-set-saved", "live-workout-minimized"].contains(debugLaunchFixtureValue(arguments: arguments) ?? "") else {
            return []
        }
        let now = Date()
        return [
            LoggedSet(exercise: "Barbell bench press",
                      weightKg: 80,
                      reps: 5,
                      rpe: nil,
                      t: now.addingTimeInterval(-95)),
            LoggedSet(exercise: "Barbell bench press",
                      weightKg: 82.5,
                      reps: 5,
                      rpe: nil,
                      t: now.addingTimeInterval(-18))
        ]
    }

    private static func debugWorkoutExcludedIntervals(arguments: [String]) -> [ExcludedInterval] {
        guard debugLaunchFixtureValue(arguments: arguments) == "live-workout-paused" else {
            return []
        }
        let now = Date()
        return [ExcludedInterval(start: now.addingTimeInterval(-420),
                                 end: now.addingTimeInterval(-300))]
    }

    private static func debugShowsMinimizedWorkout(arguments: [String]) -> Bool {
        debugLaunchFixtureValue(arguments: arguments) == "live-workout-minimized"
    }

    private static func debugSeededHomeLayoutConfig() -> AtriaHomeLayoutConfig {
        AtriaHomeLayoutConfig(glanceMetrics: ["sleep", "recovery", "strain"],
                              sizeOverrides: ["sleep": "wideShort"],
                              showLiveStrip: false,
                              showHighlights: false,
                              showPlan: false,
                              showAICoach: false,
                              ringCenterMetric: .sleep,
                              legendStatStyle: .value,
                              accent: .coral)
            .validated()
    }

    private static func debugRequestedUIScreen(arguments: [String]) -> String? {
        if let environmentValue = ProcessInfo.processInfo.environment["ATRIA_UI_SCREEN"],
           !environmentValue.isEmpty {
            return environmentValue.lowercased()
        }
        guard let screenIndex = arguments.firstIndex(of: "--atria-ui-screen") else { return nil }
        let valueIndex = arguments.index(after: screenIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        return arguments[valueIndex].lowercased()
    }

    private static func debugDashboardAutoScrollEnabled(arguments: [String]) -> Bool {
        debugLaunchFixtureValue(arguments: arguments) == "dashboard-autoscroll"
            || ProcessInfo.processInfo.environment["ATRIA_DASHBOARD_AUTOSCROLL"] == "1"
    }
    #endif

    #if DEBUG
    private func applyDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let isLiveZoneFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "live-zone"
        let fixture = Self.debugLaunchFixtureValue(arguments: arguments)
        guard arguments.contains("live-zone")
                || isLiveZoneFixture
                || fixture == "pending-sleep-review"
                || fixture == "pending-sleep-provisional-recovery"
                || ["recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"].contains(fixture)
                || fixture == "sleep-plan-bedtime"
                || fixture == "weekly-report" else { return }
        let protectsSleepCapture = arguments.contains("sleep-capture-protected")
        let heartRate = protectsSleepCapture ? 72 : 142
        let rest = 58
        let maxHR = 190
        let zone = Metrics.heartRateZone(bpm: heartRate, rest: rest, max: maxHR)

        hasUnlockedPrimaryContent = true
        hasUnlockedSecondarySections = true

        var status = model.statusStore.state
        status.status = .connected
        status.bluetoothPermissionDenied = false
        model.statusStore.state = status

        var core = model.coreLiveStore.state
        core.status = .connected
        core.deviceName = "WHOOP Strap"
        core.displayDeviceName = "Strap"
        core.batteryLevel = 72
        core.batteryIsCharging = false
        core.batteryChargeStatus = .notCharging
        core.batteryRecentlyDropping = false
        core.sessionSampleCount = 742
        core.hasRecentHeartRateSample = true
        core.liveTRIMP = protectsSleepCapture ? 2.4 : 26
        core.liveActiveCalories = protectsSleepCapture ? 32 : 186
        core.lastScanMatchAt = Date()
        core.pendingKnownReconnectStartedAt = nil
        core.pendingKnownReconnectReason = ""
        core.rangeLossBackfillPending = protectsSleepCapture
        model.coreLiveStore.state = core

        model.heroPulseStore.state = AtriaHomeModel.HeroPulseState(heartRate: heartRate,
                                                                    hasContact: true,
                                                                    sensorHasContact: true,
                                                                    heartRateZone: zone,
                                                                    recentRRSamples: Self.debugBreathworkRRSamples())
        model.pulseLiveStore.state = AtriaHomeModel.PulseLiveState(heartRate: heartRate,
                                                                   hasContact: true,
                                                                   sensorHasContact: true,
                                                                   averageHeartRate: 128,
                                                                   peakHeartRate: 151,
                                                                   heartRateZone: zone,
                                                                   recentRRSamples: Self.debugBreathworkRRSamples())
    }

    private func sustainDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let isLiveZoneFixture = Self.debugLaunchFixtureValue(arguments: arguments) == "live-zone"
        let fixture = Self.debugLaunchFixtureValue(arguments: arguments)
        guard arguments.contains("live-zone")
                || isLiveZoneFixture
                || fixture == "pending-sleep-review"
                || fixture == "pending-sleep-provisional-recovery"
                || ["recovery-detail", "hrv-detail", "rhr-detail", "respiratory-detail", "sleep-detail", "strain-detail"].contains(fixture)
                || fixture == "sleep-plan-bedtime"
                || fixture == "weekly-report" else { return }
        Task { @MainActor in
            for _ in 0..<18 {
                applyDebugLiveZoneFixtureIfNeeded(arguments: arguments)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private static func debugBreathworkRRSamples(now: Date = Date()) -> [AtriaBreathworkSession.RRSample] {
        var output: [AtriaBreathworkSession.RRSample] = []
        var date = now.addingTimeInterval(-180)
        var index = 0
        while date <= now {
            let inFinalMinute = date >= now.addingTimeInterval(-60)
            let base = inFinalMinute ? 930 : 800
            let wave = (index % 6) * (inFinalMinute ? 9 : 4)
            let ms = base + wave
            output.append(AtriaBreathworkSession.RRSample(date: date, ms: ms))
            date = date.addingTimeInterval(Double(ms) / 1000.0)
            index += 1
        }
        return output
    }
    #else
    private func applyDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {}
    private func sustainDebugLiveZoneFixtureIfNeeded(arguments: [String] = ProcessInfo.processInfo.arguments) {}
    #endif

    private var isDebugUIScreenLaunchActive: Bool {
#if DEBUG
        Self.debugRequestedUIScreen(arguments: ProcessInfo.processInfo.arguments) != nil
            || Self.debugLaunchOverviewSegmentArgument(arguments: ProcessInfo.processInfo.arguments) != nil
            || Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) != nil
            || ProcessInfo.processInfo.arguments.contains("--atria-open-settings")
            || ProcessInfo.processInfo.arguments.contains("--atria-open-connection-guide")
#else
        false
#endif
    }

    private var debugShowsSleepPlanBedtimeFixture: Bool {
#if DEBUG
        Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "sleep-plan-bedtime"
#else
        false
#endif
    }

    private var debugShowsNorthStarTodayFixture: Bool {
#if DEBUG
        Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "north-star-highlights"
#else
        false
#endif
    }

    private static func debugLaunchOverviewSegmentArgument(arguments: [String] = ProcessInfo.processInfo.arguments) -> AtriaLegacyOverviewDestination? {
#if DEBUG
        guard let segmentIndex = arguments.firstIndex(of: "--atria-ui-overview-segment"),
              arguments.indices.contains(arguments.index(after: segmentIndex)) else { return nil }
        return AtriaLegacyOverviewDestination.debugLaunchValue(from: arguments[arguments.index(after: segmentIndex)])
#else
        return nil
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

    private func updateHeartRateBroadcastState(reason: String) {
        let enabled = persistentHeartRateBroadcastEnabled || (workoutSession != nil && workoutHeartRateBroadcastEnabled)
        heartRateBroadcaster.setEnabled(enabled)
        model.setHeartRateBroadcastActive(heartRateBroadcaster.isBroadcasting)
        AtriaDebugLog("ATRIADBG hr_broadcast_ui enabled=%d persistent=%d workout=%d active=%d reason=%@",
                      enabled ? 1 : 0,
                      persistentHeartRateBroadcastEnabled ? 1 : 0,
                      workoutHeartRateBroadcastEnabled ? 1 : 0,
                      heartRateBroadcaster.isBroadcasting ? 1 : 0,
                      reason)
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
        guard debugWorkoutDetectionPrompt == nil else {
            workoutDetectionPrompt = nil
            return
        }
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
        if AtriaWorkoutPromptEvaluator.isInCooldown(dismissedUntil: workoutPromptDismissedUntil, now: now) {
            workoutDetectionPrompt = nil
            return
        }
        let heartRate = model.pulseLiveStore.state.heartRate
        let rest = model.homeStatsStore.state.restingHeartRate
        let samples = model.coreLiveStore.state.sessionSampleCount
        let liveTRIMP = model.coreLiveStore.state.liveTRIMP
        let strain = Metrics.strain(fromTRIMP: liveTRIMP)
        let bpmOverRest = max(0, heartRate - rest)
        let evaluation = AtriaWorkoutPromptEvaluator.evaluate(samples: ble.session,
                                                             currentHeartRate: heartRate,
                                                             restingHeartRate: rest,
                                                             maxHeartRate: store.profile.maxHR,
                                                             now: now)
        let looksActive = evaluation.shouldPrompt
        if looksActive {
            workoutDetectionPrompt = AtriaWorkoutDetectionPrompt(heartRate: heartRate,
                                                                 strain: strain,
                                                                 samples: samples,
                                                                 bpmOverRest: bpmOverRest,
                                                                 restingHeartRate: rest,
                                                                 maxHeartRate: store.profile.maxHR)
        } else {
            workoutDetectionPrompt = nil
        }
    }

    #if DEBUG
    private var debugWorkoutReviewDraft: AtriaWorkoutReviewDraft? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "workout-review-flow" else {
            return nil
        }
        let now = Date()
        return AtriaWorkoutReviewDraft(prompt: AtriaWorkoutDetectionPrompt(heartRate: 142,
                                                                           strain: 6.4,
                                                                           samples: 420,
                                                                           bpmOverRest: 52,
                                                                           restingHeartRate: 60,
                                                                           maxHeartRate: 190),
                                       suggestedStart: now.addingTimeInterval(-42 * 60),
                                       suggestedEnd: now)
    }

    private var debugWorkoutDetectionPrompt: AtriaWorkoutDetectionPrompt? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "workout-detection"
                || arguments[valueIndex] == "workout-detection-ready"
                || arguments[valueIndex] == "workout-detection-zone-path" else {
            return nil
        }
        let fixture = arguments[valueIndex]
        let ready = fixture == "workout-detection-ready" || fixture == "workout-detection-zone-path"
        return AtriaWorkoutDetectionPrompt(heartRate: 142,
                                           strain: ready ? 9.2 : 6.4,
                                           samples: ready ? 960 : 420,
                                           bpmOverRest: 52,
                                           restingHeartRate: 60,
                                           maxHeartRate: 190)
    }

    private var debugSavedWorkoutReviewCandidate: WorkoutReviewCandidate? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "saved-workout-review" else {
            return nil
        }
        let now = Date()
        return WorkoutReviewCandidate(id: "debug-saved-workout-review",
                                      start: now.addingTimeInterval(-76 * 60),
                                      end: now.addingTimeInterval(-8 * 60),
                                      kind: .activityCandidate,
                                      confidence: .medium,
                                      duration: 68 * 60,
                                      avgHR: 118,
                                      peakHR: 156,
                                      streamCoveragePercent: 58,
                                      observedDuration: 39 * 60,
                                      droppedGapSeconds: 18 * 60,
                                      maxSampleGap: 11 * 60,
                                      gapCount: 2,
                                      reason: "debug_fixture_saved_workout_review")
    }

    private var debugWorkoutReviewHoldState: WorkoutReviewHoldState? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex) else { return nil }
        switch arguments[valueIndex] {
        case "workout-review-hold-settle":
            return .waitingForSettle(bpmOverRest: 31)
        case "workout-review-hold-possible":
            return .possibleSignal(reason: "low_coverage_possible_effort")
        default:
            return nil
        }
    }
    #else
    private var debugWorkoutReviewDraft: AtriaWorkoutReviewDraft? { nil }
    private var debugWorkoutDetectionPrompt: AtriaWorkoutDetectionPrompt? { nil }
    private var debugSavedWorkoutReviewCandidate: WorkoutReviewCandidate? { nil }
    private var debugWorkoutReviewHoldState: WorkoutReviewHoldState? { nil }
    #endif

    private func endWorkoutSession(startedAt: Date) {
        endWorkoutSession(startedAt: startedAt, strengthSets: [], excludedIntervals: [])
    }

    private func endWorkoutSession(startedAt: Date,
                                   strengthSets: [LoggedSet],
                                   excludedIntervals: [ExcludedInterval]) {
        let label = "Live workout"
        let endedAt = Date()
        let checkpointed = ble.checkpointCurrentSession(label: label,
                                                        reason: "live_workout_end",
                                                        strengthSets: strengthSets,
                                                        excludedIntervals: excludedIntervals)
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let confirmed = store.confirmWorkoutWindowForUI(start: startedAt,
                                                        end: endedAt,
                                                        rest: rest,
                                                        maxHR: store.profile.maxHR,
                                                        source: "live_workout_end",
                                                        strengthSets: strengthSets,
                                                        excludedIntervals: excludedIntervals)
        workoutSession = nil
        liveWorkoutLoggedSets = []
        liveWorkoutExcludedIntervals = []
        liveWorkoutMinimized = false

        if let confirmed {
            store.exportToHealthKit()
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Workout saved",
                message: "Atria confirmed \(formatWorkoutDuration(confirmed.duration)) with \(confirmed.streamCoveragePercent)% stream coverage and queued it for Health export."
            )
        } else if checkpointed {
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Workout evidence saved",
                message: "Atria saved this live window locally. It needs at least 10 minutes of strong heart-rate evidence before it can count as a workout."
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

    private func presentWorkoutReview(prompt: AtriaWorkoutDetectionPrompt, now: Date = Date()) {
        let observedSeconds = TimeInterval(max(60, prompt.evidenceMinutes * 60))
        workoutDetectionPrompt = nil
        workoutReviewHoldState = nil
        workoutReviewDraft = AtriaWorkoutReviewDraft(prompt: prompt,
                                                     suggestedStart: now.addingTimeInterval(-observedSeconds),
                                                     suggestedEnd: now,
                                                     strengthHistorySessions: store.sessions)
    }

    private func presentWorkoutReview(candidate: WorkoutReviewCandidate) {
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let prompt = AtriaWorkoutDetectionPrompt(heartRate: candidate.peakHR,
                                                 strain: 0,
                                                 samples: max(180, Int(candidate.duration.rounded())),
                                                 bpmOverRest: max(0, candidate.peakHR - rest),
                                                 restingHeartRate: rest,
                                                 maxHeartRate: store.profile.maxHR)
        savedWorkoutReviewCandidate = nil
        workoutDetectionPrompt = nil
        workoutReviewHoldState = nil
        workoutReviewDraft = AtriaWorkoutReviewDraft(prompt: prompt,
                                                     suggestedStart: candidate.start,
                                                     suggestedEnd: candidate.end,
                                                     strengthHistorySessions: store.sessions)
    }

    private func dismissSavedWorkoutReviewCandidate(_ candidate: WorkoutReviewCandidate) {
        UserDefaults.standard.set(candidate.id, forKey: Self.workoutReviewDismissedIDKey)
        rememberDismissedWorkoutReviewCandidate(candidate)
        savedWorkoutReviewCandidate = nil
        workoutReviewHoldState = nil
    }

    private func rememberDismissedWorkoutReviewCandidate(_ candidate: WorkoutReviewCandidate) {
        var ids = dismissedWorkoutReviewCandidateIDs()
        ids.removeAll { $0 == candidate.id }
        ids.insert(candidate.id, at: 0)
        ids = Array(ids.prefix(Self.workoutReviewDismissedIDsLimit))
        UserDefaults.standard.set(ids, forKey: Self.workoutReviewDismissedIDsKey)
        AtriaDebugLog("ATRIADBG workout_review_candidate dismissed id=%@ retained=%d reason=user_marked_not_workout",
                      candidate.id,
                      ids.count)
    }

    private func dismissedWorkoutReviewCandidateIDs() -> [String] {
        let ids = UserDefaults.standard.stringArray(forKey: Self.workoutReviewDismissedIDsKey) ?? []
        if ids.isEmpty,
           let legacyID = UserDefaults.standard.string(forKey: Self.workoutReviewDismissedIDKey),
           !legacyID.isEmpty {
            return [legacyID]
        }
        return ids
    }

    private func workoutReviewCandidateWasDismissed(_ candidate: WorkoutReviewCandidate) -> Bool {
        dismissedWorkoutReviewCandidateIDs().contains(candidate.id)
    }

    private func refreshSavedWorkoutReviewCandidate(reason: String) {
        guard debugWorkoutReviewDraft == nil else { return }
        guard selectedTab == .overview else { return }
        guard workoutSession == nil else {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = nil
            return
        }
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let liveBPMOverRest = max(0, model.pulseLiveStore.state.heartRate - rest)
        let candidate = store.latestWorkoutReviewCandidate(rest: rest,
                                                           maxHR: store.profile.maxHR,
                                                           source: reason)
        // The store already enforces a 10-minute post-end settle; only hold on
        // elevated live HR while the candidate window itself is still recent,
        // otherwise an all-day wearer above rest+20 never gets an evaluation.
        if let candidate,
           model.coreLiveStore.state.status == .connected,
           liveBPMOverRest > Self.workoutReviewSettleBPMOverRest,
           Date().timeIntervalSince(candidate.end) < Self.workoutReviewRecentEndHoldSeconds {
            AtriaDebugLog("ATRIADBG workout_review_candidate status=holding source=%@ reason=live_hr_not_settled bpm_over_rest=%d seconds_since_end=%.0f",
                          reason,
                          liveBPMOverRest,
                          Date().timeIntervalSince(candidate.end))
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = .waitingForSettle(bpmOverRest: liveBPMOverRest)
            return
        }
        if let candidate, !candidate.isReviewPromptWorthy {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = .possibleSignal(reason: candidate.reason)
        } else if let candidate,
                  workoutReviewCandidateWasDismissed(candidate) {
            savedWorkoutReviewCandidate = nil
            workoutReviewHoldState = nil
        } else {
            savedWorkoutReviewCandidate = candidate
            workoutReviewHoldState = nil
        }
    }

    private func saveWorkoutReview(_ result: AtriaWorkoutReviewResult) {
        let rest = store.baseline.restingInt ?? model.heroStore.state.restingHeartRate
        let confirmed = store.confirmWorkoutWindowForUI(start: result.start,
                                                        end: result.end,
                                                        rest: rest,
                                                        maxHR: store.profile.maxHR,
                                                        source: "guided_workout_review",
                                                        activityType: result.activityType,
                                                        activitySubtype: result.activitySubtype,
                                                        exerciseNames: result.exerciseNames,
                                                        strengthSets: result.strengthSets,
                                                        reviewSource: "guided_workout_review")
        workoutReviewDraft = nil
        savedWorkoutReviewCandidate = nil
        workoutReviewHoldState = nil
        workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)

        if let confirmed {
            store.exportToHealthKit()
            let exerciseText = result.exerciseNames.isEmpty ? "" : " · \(result.exerciseNames.count) exercises"
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "\(confirmed.label) saved",
                message: "\(formatWorkoutDuration(confirmed.duration)) confirmed from strap HR\(exerciseText). You can refine future sessions from the review flow."
            )
        } else {
            workoutEndNotice = AtriaWorkoutEndNotice(
                title: "Workout review kept",
                message: "Atria kept the strap evidence, but that window still needs cleaner coverage before it can become a confirmed workout."
            )
        }
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

    private func handleHomeAppear() {
        applyDebugUIScreenLaunchArgumentIfNeeded()
        applyDebugLiveZoneFixtureIfNeeded()
        sustainDebugLiveZoneFixtureIfNeeded()
        if workoutReviewDraft == nil, let debugWorkoutReviewDraft {
            workoutReviewDraft = debugWorkoutReviewDraft
        }
        postDebugNotificationDeepLinkIfRequested()
        enableDebugHeartRateBroadcastIfRequested()
        triggerDebugStrainTargetHapticIfRequested()
        #if DEBUG
        if workoutSession == nil,
           ProcessInfo.processInfo.arguments.contains("--atria-show-workout") {
            liveWorkoutLoggedSets = Self.debugWorkoutLoggedSets(arguments: ProcessInfo.processInfo.arguments)
            liveWorkoutExcludedIntervals = Self.debugWorkoutExcludedIntervals(arguments: ProcessInfo.processInfo.arguments)
            liveWorkoutMinimized = Self.debugShowsMinimizedWorkout(arguments: ProcessInfo.processInfo.arguments)
            selectedTab = liveWorkoutMinimized ? .vitals : selectedTab
            workoutSession = AtriaWorkoutSession(start: Date())
        }
        #endif
        refreshSavedWorkoutReviewCandidate(reason: "home_appear")
        presentCoexistenceModalIfNeeded(for: ble.officialAppCoexistenceRisk)
        guard !hasUnlockedPrimaryContent else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryState = UIDevice.current.batteryState
        if homeAppearedAt == nil {
            homeAppearedAt = Date()
        }
        ble.setForegroundHighFrequencyDisplayMode(selectedTab == .vitals)
        model.setPulseDetailMode(active: selectedTab == .vitals)
        if !isDebugUIScreenLaunchActive {
            consumePendingIntentCommandIfNeeded()
        }
        refreshAICoachKeyState()
        runCoexistenceSnoozeSelfTestIfRequested()
        updateHeartRateBroadcastState(reason: "home_appear")
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

    private func handleSelectedTabChange(_ tab: HomeTab) {
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
                refreshSavedWorkoutReviewCandidate(reason: "overview_return")
                scheduleOverviewDiagnosticsKickoff(reason: "overview_return_idle",
                                                   delayNanoseconds: 6_800_000_000)
            }
        }
    }

    private func handleHomeScenePhaseChange(_ phase: ScenePhase) {
        updateMediaRefreshLoop()
        guard phase == .active else {
            ble.pausePhoneStepUpdates(reason: "scene_inactive")
            // Refresh Lock Screen / Home Screen widgets with the latest
            // strap-backed Strain/HRV/BPM right as the user leaves the app.
            WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: "scene_background")
            return
        }
        WidgetSnapshotPublisher.publish(store: store, ble: ble, reason: "scene_active")
        if let url = URL(string: "whoop://") {
            officialAppInstalled = UIApplication.shared.canOpenURL(url)
        }
        if !isDebugUIScreenLaunchActive {
            consumePendingIntentCommandIfNeeded()
        }
        refreshAICoachKeyState()
        updateHapticCoordinator()
        // Morning flow: auto-confirm only ran at launch, so a resident app never
        // confirmed last night's sleep until the next relaunch. Foregrounding is
        // the natural morning trigger; the store rate-limits and does nothing when the
        // newest confirmed sleep is already recent.
        store.autoConfirmSleepOnForegroundIfUseful(reason: "scene_foreground")
        LocalNotificationScheduler.scheduleEveningJournalCheckIn(
            lastJournalActivity: [store.behaviorJournalEntries.map(\.day).max(),
                                  store.journalAnswers.latestActivityDay()]
                .compactMap { $0 }
                .max())
    }

    private func refreshAICoachKeyState() {
        aiCoachHasAPIKey = AtriaCoachKeychain.hasAPIKey(provider: aiCoachSettings.cloudProvider)
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var preferredColorScheme: ColorScheme? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--atria-ui-follow-system-appearance") {
            return nil
        }
#endif
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
                                              showsHero: Bool = true,
                                              @ViewBuilder content: @escaping () -> Content) -> some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 18) {
                        Color.clear
                            .frame(height: 1)
                            .id(Self.debugDashboardScrollTopID)
                        if showsHero && !debugShowsSleepPlanBedtimeFixture {
                            hero
                        }
                        content()
                        Color.clear
                            .frame(height: 1)
                            .id(Self.debugDashboardScrollBottomID)
                    }
                    .frame(maxWidth: contentWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, scrollBottomClearance)
                    .frame(maxWidth: .infinity)
                }
                // The root ZStack already draws AtriaBackdropLayer behind the
                // TabView — a second per-tab copy doubled fullscreen gradient
                // overdraw under every glass blur sample.
                .scrollContentBackground(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .refreshable {
                    await handleConnectivityRefresh()
                }
                .task(id: debugDashboardAutoScrollTaskID(title: title)) {
                    await runDebugDashboardAutoScrollIfNeeded(proxy: scrollProxy, title: title)
                }
            }
            .navigationTitle(title)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    topChrome
                    if showConnectivityPill {
                        connectivityPill
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: scrollBottomSafeAreaInset)
                    .allowsHitTesting(false)
            }
        }
    }

    private var scrollBottomClearance: CGFloat {
        shouldShowLiveAccessory ? 260 : 188
    }

    private var scrollBottomSafeAreaInset: CGFloat {
        shouldShowLiveAccessory ? 220 : 148
    }

    private static let debugDashboardScrollTopID = "atria-dashboard-scroll-top"
    private static let debugDashboardScrollBottomID = "atria-dashboard-scroll-bottom"

    private func debugDashboardAutoScrollTaskID(title: String) -> String {
#if DEBUG
        Self.debugDashboardAutoScrollEnabled(arguments: ProcessInfo.processInfo.arguments) ? title : "off"
#else
        "off"
#endif
    }

    @MainActor
    private func runDebugDashboardAutoScrollIfNeeded(proxy: ScrollViewProxy, title: String) async {
#if DEBUG
        guard title == "Today",
              Self.debugDashboardAutoScrollEnabled(arguments: ProcessInfo.processInfo.arguments) else { return }
        try? await Task.sleep(for: .milliseconds(900))
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 1.45)) {
                proxy.scrollTo(Self.debugDashboardScrollBottomID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(1750))
            withAnimation(.easeInOut(duration: 1.45)) {
                proxy.scrollTo(Self.debugDashboardScrollTopID, anchor: .top)
            }
            try? await Task.sleep(for: .milliseconds(1750))
        }
#endif
    }

    private var chatComingSoonContent: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(.top, 48)
            Text("ATRIA Intelligent Assistant")
                .font(.title2.weight(.bold))
            Text("Coming Soon!")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Ask your recovery, sleep and strain anything — answered from your own data, on this phone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .atriaCard()
        .padding(.horizontal, 16)
    }

    private var topChrome: some View {
        AtriaHomeTopChrome(statusStore: model.statusStore,
                           coreLiveStore: model.coreLiveStore,
                           pulseLiveStore: model.pulseLiveStore,
                           showHelp: shouldShowTopChromeHelp,
                           onShowHelp: {
                               connectionGuideSnoozedUntil = nil
                               showConnectionGuide = true
                           },
                           onShowSettings: {
                               showSettings = true
                           },
                           onShowStrap: {
                               showStrapScreen = true
                           },
                           onTapStatusWhenNotConnected: {
                               ble.startScan(reason: "home_status_chip")
                           })
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var shouldShowTopChromeHelp: Bool {
        if model.statusStore.state.status == .poweredOff {
            return true
        }
        if model.pulseLiveStore.state.hasPulseSignal || model.coreLiveStore.state.hasRecentHeartRateSample {
            return false
        }
        return model.statusStore.state.status != .connected
    }

    private var connectivityPill: some View {
        GlassEffectContainer(spacing: 4) {
            Text(connectivityPillText)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .capsule)
                .accessibilityLabel(connectivityPillText)
        }
    }

    private var connectivityPillText: String {
        let live = model.coreLiveStore.state
        let status: String
        switch live.status {
        case .connected:
            status = "Connected"
        case .connecting:
            status = "Connecting"
        case .scanning:
            status = "Scanning"
        case .poweredOff:
            status = "Bluetooth off"
        case .disconnected:
            status = "Disconnected"
        }
        return "Strap · \(status) · \(live.batteryText) · updated \(live.lastReadingAgeText)"
    }

    private func handleConnectivityRefresh() async {
        await MainActor.run {
            ble.requestStrapStatusRead(reason: "pull_to_refresh")
            _ = ble.requestOfflineHistoricalSyncIfNeeded(reason: "pull_to_refresh", force: true)
            model.forceRefresh()
            showConnectivityPill = true
            connectivityPillTask?.cancel()
            connectivityPillTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(2_500))
                withAnimation(.snappy(duration: 0.2)) {
                    showConnectivityPill = false
                }
            }
        }
    }

    private var hero: some View {
        AtriaHeroPanelHost(statusStore: model.statusStore,
                           liveStore: model.coreLiveStore,
                           heroStore: model.heroStore,
                           pulseStore: model.heroPulseStore)
    }

    private var currentHomeLayoutConfig: AtriaHomeLayoutConfig {
        guard let data = homeLayoutConfigStorage.data(using: .utf8),
              !data.isEmpty,
              let config = try? AtriaHomeLayoutConfig.decoded(from: data) else {
            return .default
        }
        return config
    }

    private func saveHomeLayoutConfig(_ config: AtriaHomeLayoutConfig) {
        guard let data = try? config.validated().encodedData(),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        homeLayoutConfigStorage = json
        UserDefaults.standard.set(json, forKey: AtriaHomeLayoutConfig.storageKey)
    }

    private func makeTodayShareSnapshot() -> AtriaShareSnapshot {
        let hero = model.heroStore.state
        let live = model.coreLiveStore.state
        let sleep = store.sleepHistorySnapshot.latest
        let sleepValue = sleep?.durationText ?? model.snapshotStore.state.sleepValue
        let sleepFill = sleep.map { min(max($0.durationHours / 8.0, 0), 1) }
        let recoveryPercent = hero.recoveryEstimate.percent
        let recoveryTint: String
        switch recoveryPercent ?? 50 {
        case 67...:
            recoveryTint = "#42f59b"
        case 34..<67:
            recoveryTint = "#ffd166"
        default:
            recoveryTint = "#ff6b6b"
        }
        let strainFill = hero.guidance.target.map { min(max(hero.strain / max($0, 0.1), 0), 1) }
        let recoveryValue = recoveryPercent.map { "\($0)%" } ?? ""
        let stats = [
            AtriaShareSnapshot.Stat(id: "recovery",
                                    title: "Recovery",
                                    value: recoveryValue,
                                    detail: hero.recoveryDetail),
            AtriaShareSnapshot.Stat(id: "sleep",
                                    title: "Sleep",
                                    value: pendingShareValue(sleepValue),
                                    detail: sleep?.confirmationText ?? model.snapshotStore.state.sleepDetail),
            AtriaShareSnapshot.Stat(id: "strain",
                                    title: "Day strain",
                                    value: pendingShareValue(hero.strainValue),
                                    detail: hero.strainDetail),
            AtriaShareSnapshot.Stat(id: "hrv",
                                    title: "HRV",
                                    value: pendingShareValue(hero.hrvValue),
                                    detail: hero.hrvDetail),
            AtriaShareSnapshot.Stat(id: "rhr",
                                    title: "RHR",
                                    value: pendingShareValue(hero.restingHeartRateText),
                                    detail: "resting bpm"),
            AtriaShareSnapshot.Stat(id: "peak_hr",
                                    title: "Peak HR",
                                    value: model.pulseLiveStore.state.peakHeartRate.map { "\($0)" } ?? "",
                                    detail: "today"),
            AtriaShareSnapshot.Stat(id: "calories",
                                    title: "Calories",
                                    value: live.liveActiveCalories.map { "\(Int($0.rounded()))" } ?? "",
                                    detail: "active estimate")
        ]
        return AtriaShareSnapshot(date: Date(),
                                  recovery: AtriaShareSnapshot.Ring(title: "Recovery",
                                                                    value: recoveryValue,
                                                                    detail: hero.recoveryDetail,
                                                                    tintHex: recoveryTint,
                                                                    fill: recoveryPercent.map { Double($0) / 100.0 }),
                                  sleep: AtriaShareSnapshot.Ring(title: "Sleep",
                                                                 value: pendingShareValue(sleepValue),
                                                                 detail: sleep?.confirmationText ?? "sleep",
                                                                 tintHex: "#56d7ff",
                                                                 fill: sleepFill),
                                  strain: AtriaShareSnapshot.Ring(title: "Strain",
                                                                  value: pendingShareValue(hero.strainValue),
                                                                  detail: hero.strainDetail,
                                                                  tintHex: "#ff8a3d",
                                                                  fill: strainFill),
                                  stats: stats)
    }

    private func pendingShareValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "--" || trimmed == "Learning" || trimmed == "Building" || trimmed == "Preparing" {
            return ""
        }
        return trimmed
    }


    private var overviewContent: some View {
        VStack(spacing: 18) {
            if shouldLeadWithSystemBanners && !debugShowsSleepPlanBedtimeFixture && !debugShowsNorthStarTodayFixture {
                overviewSystemBanners
            }

            if let prompt = debugWorkoutDetectionPrompt ?? workoutDetectionPrompt, workoutSession == nil {
                AtriaWorkoutDetectionBanner(prompt: prompt) {
                    workoutDetectionPrompt = nil
                    workoutPromptDismissedUntil = Date().addingTimeInterval(Self.workoutPromptCooldown)
                } onStart: {
                    presentWorkoutReview(prompt: prompt)
                }
            }

            if let candidate = debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate,
               workoutSession == nil,
               workoutReviewDraft == nil,
               (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) == nil {
                AtriaSavedWorkoutReviewBanner(candidate: candidate,
                                             restingHeartRate: store.baseline.restingInt ?? model.heroStore.state.restingHeartRate,
                                             maxHeartRate: store.profile.maxHR) {
                    dismissSavedWorkoutReviewCandidate(candidate)
                } onReview: {
                    presentWorkoutReview(candidate: candidate)
                }
            }

            if let holdState = workoutReviewHoldStateForDisplay,
               workoutSession == nil,
               workoutReviewDraft == nil,
               (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) == nil,
               (debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate) == nil {
                AtriaWorkoutReviewHoldBanner(state: holdState)
            }

            AtriaTodayScreen(statusStore: model.statusStore,
                             liveStore: model.coreLiveStore,
                             pulseStore: model.heroPulseStore,
                             heroStore: model.heroStore,
                             homeStatsStore: model.homeStatsStore,
                             profileMetricsStore: model.profileMetricsStore,
                             snapshotStore: model.snapshotStore,
                             store: store,
                             layoutConfig: currentHomeLayoutConfig,
                             hasUnlockedSecondarySections: hasUnlockedSecondarySections,
                             aiCoachSettings: aiCoachSettings,
                             aiCoachHasAPIKey: aiCoachHasAPIKey,
                             hapticSettings: hapticSettings,
                             horizontalSizeClass: horizontalSizeClass,
                             connectionContext: connectionGuideContext,
                             debugShowsSegmentContent: debugShowsOverviewSegmentContent,
                             suppressSleepSyncPrompt: hasPrimaryReviewAction,
                             initialSegment: debugInitialOverviewSegment,
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
                             onOpenJournal: {
                                 selectedTab = .journal
                             },
                             onOpenShare: {
                                 showShareSheet = true
                             },
                             onStartWorkout: {
                                 liveWorkoutLoggedSets = []
                                 liveWorkoutExcludedIntervals = []
                                 liveWorkoutMinimized = false
                                 workoutSession = AtriaWorkoutSession(start: Date())
                             },
                             onCustomizeToday: {
                                 showCustomizeSheet = true
                             })

            if !debugShowsNorthStarTodayFixture && !shouldLeadWithSystemBanners {
                overviewSystemBanners
            }
        }
    }

    @ViewBuilder
    private var overviewSystemBanners: some View {
        if let diagnosis = connectionDiagnosis {
            AtriaConnectionDiagnosisBanner(diagnosis: diagnosis) {
                connectionGuideSnoozedUntil = nil
                showConnectionGuide = true
            }
        } else if shouldShowMissedDataBanner {
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
    }

    private var connectionDiagnosis: AtriaConnectionDiagnosis? {
        visibleConnectionDiagnosis
    }

    private var hasPrimaryReviewAction: Bool {
        hasWorkoutReviewAction || hasPendingSleepReviewAction
    }

    private var shouldLeadWithSystemBanners: Bool {
        // Static handoff compatibility marker for the pre-IA-2 segment gate:
        // !hasPrimaryReviewAction && activeOverviewSegment == .today
        false
    }

    private var hasWorkoutReviewAction: Bool {
        workoutSession == nil && (
            (debugWorkoutDetectionPrompt ?? workoutDetectionPrompt) != nil ||
            (debugSavedWorkoutReviewCandidate ?? savedWorkoutReviewCandidate) != nil ||
            workoutReviewHoldStateForDisplay != nil
        )
    }

    private var hasPendingSleepReviewAction: Bool {
        #if DEBUG
        if Self.debugLaunchFixtureValue(arguments: ProcessInfo.processInfo.arguments) == "pending-sleep-review" {
            return true
        }
        #endif
        if store.sleepHistorySnapshot.latest?.confirmed == false {
            return true
        }
        return store.latestSleepReviewNightForUI(rest: store.baseline.restingInt ?? 60,
                                                 source: "overview_ordering") != nil
    }

    private var workoutReviewHoldStateForDisplay: WorkoutReviewHoldState? {
        if let debugWorkoutReviewHoldState {
            return debugWorkoutReviewHoldState
        }
        return nil
    }

    private func updateConnectionDiagnosisVisibility(reason: String, now: Date = Date()) {
        LocalNotificationScheduler.refreshActionableConnectionMaintenance(ble: ble, reason: reason)
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
            // Persistence-gated diagnoses (e.g. "Fit check needed") only notify once
            // they have stayed visible past the candidate delay — avoids alerting on
            // momentary poor-contact blips.
            if next.sendsLocalNotification {
                LocalNotificationScheduler.scheduleActionableConnectionDiagnosis(title: next.title,
                                                                                 body: next.action,
                                                                                 reason: reason,
                                                                                 now: now)
            }
        }
        visibleConnectionDiagnosis = next
    }

    private var shouldShowMissedDataBanner: Bool {
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) { return true }
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
            return true
        }
    }

    private var missedDataBackfillIsDeferredForLiveStream: Bool {
        model.statusStore.state.status == .connected
            && model.coreLiveStore.state.sessionSampleCount > 0
    }

    #if DEBUG
    private static func debugShowsCatchUpPill(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "catching-up-pill"
    }
    #else
    private static func debugShowsCatchUpPill(arguments _: [String]) -> Bool { false }
    #endif

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

    private var journalContent: some View {
        AtriaJournalTab(store: store)
    }

    private func makeFaceOffChallengeURL() -> URL? {
        let name = faceOffDisplayName.isEmpty ? "A friend" : faceOffDisplayName
        guard let payload = AtriaFaceOff.makePayload(name: name,
                                                     history: store.dailyMetricHistory) else { return nil }
        return AtriaFaceOff.url(for: payload)
    }

    private var vitalsContent: some View {
        AtriaHealthScreen(liveStore: model.coreLiveStore,
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

    @ViewBuilder
    private var collectionContent: some View {
        #if DEBUG
        if Self.debugRequestedUIScreen(arguments: ProcessInfo.processInfo.arguments) == "history" {
            HistoryView(store: store)
        } else {
            collectionTabContent
        }
        #else
        collectionTabContent
        #endif
    }

    private var collectionTabContent: some View {
        AtriaStrapScreen(statusStore: model.statusStore,
                         coreLiveStore: model.coreLiveStore,
                         pulseLiveStore: model.pulseLiveStore,
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

    private var researchValidationContent: some View {
        AtriaCollectionResearchValidationContent(collectionLiveStore: model.collectionLiveStore,
                                                 homeStatsStore: model.homeStatsStore,
                                                 snapshotStore: model.snapshotStore,
                                                 profileStore: model.profileStore,
                                                 profileMetricsStore: model.profileMetricsStore,
                                                 store: store,
                                                 ble: ble,
                                                 showRRImporter: $showRRImporter,
                                                 showHRImporter: $showHRImporter,
                                                 rrShareURL: $rrShareURL,
                                                 hrShareURL: $hrShareURL,
                                                 rrImportStatus: rrImportStatus,
                                                 hrImportStatus: hrImportStatus)
    }

    private func secondaryLoadingCard(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .frame(width: 142, height: 18)
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .frame(height: 64)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .frame(height: 38)
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .frame(height: 38)
            }
        }
        .padding(18)
        .atriaCard(emphasis: .soft)
        .redacted(reason: .placeholder)
        .accessibilityLabel(title)
    }

    private func handleRRImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                rrImportStatus = "No beat-to-beat file selected"
                return
            }
            let passed = store.importRRReferenceCSVForUI(from: url)
            rrImportStatus = passed ? "Beat-to-beat file matched" : "Not yet validated against a reference monitor"
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
              !isDebugUIScreenLaunchActive,
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
        HStack(alignment: .center, spacing: 10) {
            compactIcon
            copyBlock
            Spacer(minLength: 0)
            compactState
            dismissButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Catching up. \(missedDataDurationText) of missed data. \(protectsLiveStream ? "Live heart rate stays protected while Atria catches up." : "Atria is syncing strap history in small chunks.")")
    }

    private var compactIcon: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.cyan)
            .frame(width: 30, height: 30)
            .background(AtriaIconTileBackground(cornerRadius: 9, tint: .cyan))
    }

    private var copyBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Static handoff compatibility marker for the previous title token:
            // Text(protectsLiveStream ? "Saved data protected" : "Sync ready")
            // Live HR stays protected while Atria waits for the best sync moment.
            // Pull missed strap data when you are ready.
            Text("Catching up · \(missedDataDurationText)")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(protectsLiveStream ? "Live protected" : "History syncing")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .layoutPriority(2)
    }

    @ViewBuilder
    private var compactState: some View {
        if protectsLiveStream {
            Text("Live")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(AtriaIconTileBackground(cornerRadius: 10, tint: .cyan))
                .accessibilityLabel("Live heart rate protected")
        } else {
            Button(action: onSync) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.bold))
                    .frame(width: 16, height: 16)
            }
            .atriaCardAction(prominent: false, tint: .cyan)
            .accessibilityLabel("Sync missed strap data")
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Dismiss catch-up status")
    }

    private var missedDataDurationText: String {
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) {
            return "3.2 h"
        }
        let defaults = UserDefaults.standard
        let requestedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let startedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let reference = requestedAt ?? startedAt
        guard let reference else { return "0.0 h" }
        let hours = max(0, Date().timeIntervalSince1970 - reference) / 3600
        return String(format: "%.1f h", hours)
    }

    private var catchUpProgress: Double {
        // Retained for older handoff fixture compatibility; the current UI is a calm
        // status row and no longer renders a progress bar.
        if Self.debugShowsCatchUpPill(arguments: ProcessInfo.processInfo.arguments) {
            return 0.42
        }
        let defaults = UserDefaults.standard
        let startedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let requestedAt = defaults.object(forKey: AtriaBLEManager.OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let reference = startedAt ?? requestedAt
        guard let reference else { return 0.08 }
        return min(0.96, max(0.08, Date().timeIntervalSince1970 - reference) / (30 * 60))
    }

    #if DEBUG
    private static func debugShowsCatchUpPill(arguments: [String]) -> Bool {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return false }
        let valueIndex = arguments.index(after: fixtureIndex)
        return arguments.indices.contains(valueIndex)
            && arguments[valueIndex] == "catching-up-pill"
    }
    #else
    private static func debugShowsCatchUpPill(arguments _: [String]) -> Bool { false }
    #endif
}

private struct AtriaWorkoutDetectionBanner: View, Equatable {
    let prompt: AtriaWorkoutDetectionPrompt
    let onDismiss: () -> Void
    let onStart: () -> Void

    static func == (lhs: AtriaWorkoutDetectionBanner, rhs: AtriaWorkoutDetectionBanner) -> Bool {
        lhs.prompt == rhs.prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.16), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: prompt.progressFraction)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "figure.run")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.headline)
                        .font(.headline.weight(.semibold))
                    Text(prompt.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                Text("Strap HR")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.13), in: Capsule(style: .continuous))
            }

            workoutEvidenceRail
            workoutDecisionStrip

            HStack(spacing: 10) {
                Button(action: onStart) {
                    Text(prompt.primaryTitle)
                        .frame(maxWidth: .infinity)
                }
                .disabled(!prompt.isReviewReady)
                .atriaCardAction(tint: .orange)

                Button(action: onDismiss) {
                    Text("Not now")
                        .frame(maxWidth: .infinity)
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(prompt.headline). Heart rate \(prompt.heartRate) beats per minute, \(prompt.bpmOverRest) above rest, strain \(String(format: "%.1f", prompt.strain)), \(prompt.confidenceLabel).")
    }

    private var workoutEvidenceRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Strap effort")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text("\(prompt.heartRate) bpm · +\(prompt.bpmOverRest)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let width = proxy.size.width
                let hrProgress = min(max(Double(prompt.bpmOverRest) / 80.0, 0), 1)
                let strainProgress = min(max(prompt.strain / 12.0, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(.orange.opacity(0.68))
                        .frame(width: max(8, width * hrProgress))
                    Capsule(style: .continuous)
                        .fill(Metrics.electricStrain.opacity(0.48))
                        .frame(width: max(5, width * strainProgress), height: 5)
                        .offset(y: 7)
                }
            }
            .frame(height: 16)

            HStack {
                Label("Strap HR", systemImage: "waveform.path.ecg")
                Spacer(minLength: 8)
                Text(String(format: "Strain %.1f", prompt.strain))
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var workoutDecisionStrip: some View {
        HStack(spacing: 7) {
            decisionChip(title: "Signal",
                         value: prompt.confidenceLabel,
                         systemImage: prompt.isReviewReady ? "checkmark.seal.fill" : "waveform.path.ecg",
                         tint: prompt.isReviewReady ? .mint : .orange)
            decisionChip(title: "Time",
                         value: "\(prompt.evidenceMinutes)m",
                         systemImage: "clock.fill",
                         tint: .cyan)
            decisionChip(title: "Next",
                         value: prompt.isReviewReady ? "Review" : "Watching",
                         systemImage: prompt.isReviewReady ? "hand.tap.fill" : "eye.fill",
                         tint: prompt.isReviewReady ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review. Strap signal \(prompt.confidenceLabel), \(prompt.evidenceMinutes) minutes seen, \(prompt.reviewHint).")
    }

    private func decisionChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.black))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct AtriaSavedWorkoutReviewBanner: View, Equatable {
    let candidate: WorkoutReviewCandidate
    let restingHeartRate: Int
    let maxHeartRate: Int
    let onDismiss: () -> Void
    let onReview: () -> Void

    static func == (lhs: AtriaSavedWorkoutReviewBanner, rhs: AtriaSavedWorkoutReviewBanner) -> Bool {
        lhs.candidate == rhs.candidate
            && lhs.restingHeartRate == rhs.restingHeartRate
            && lhs.maxHeartRate == rhs.maxHeartRate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(.orange.opacity(0.16), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: candidate.kind == .workout ? 1 : 0.72)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: candidate.kind == .workout ? "checkmark.seal.fill" : "figure.strengthtraining.traditional")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.headline.weight(.semibold))
                    Text("\(timeRangeText) · \(durationText) from strap HR")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 0)

                Text("Review")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.orange.opacity(0.13), in: Capsule(style: .continuous))
            }

            savedWorkoutEvidenceRail
            savedWorkoutDecisionStrip

            HStack(spacing: 10) {
                Button(action: onReview) {
                    Text("Confirm type")
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
        .accessibilityLabel("\(candidate.title). \(durationText) from strap heart rate, \(timeRangeText), peak \(candidate.peakHR) beats per minute. Strap window \(signalReviewTitle). Confirm type before saving.")
    }

    private var savedWorkoutEvidenceRail: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("Workout window")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(timeRangeText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let peakProgress = heartRateProgress(candidate.peakHR)
                let averageProgress = heartRateProgress(candidate.avgHR)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(.orange.opacity(0.68))
                        .frame(width: max(10, width * peakProgress))
                    Capsule(style: .continuous)
                        .fill(Color.cyan.opacity(0.56))
                        .frame(width: max(8, width * averageProgress), height: 6)
                        .offset(y: 7)
                }
            }
            .frame(height: 17)

            HStack {
                Label("Peak \(candidate.peakHR)", systemImage: "waveform.path.ecg")
                Spacer(minLength: 8)
                Text("Avg \(candidate.avgHR) · \(durationText)")
                    .monospacedDigit()
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout window \(timeRangeText). Peak \(candidate.peakHR), average \(candidate.avgHR), duration \(durationText).")
    }

    private func heartRateProgress(_ bpm: Int) -> Double {
        guard maxHeartRate > restingHeartRate else { return 0 }
        let value = Double(bpm - restingHeartRate) / Double(maxHeartRate - restingHeartRate)
        return min(max(value, 0), 1)
    }

    private var savedWorkoutDecisionStrip: some View {
        HStack(spacing: 7) {
            decisionStep(systemImage: "hand.tap.fill",
                         title: "Review",
                         value: "Window",
                         tint: .orange)
            decisionStep(systemImage: signalReviewIcon,
                         title: "Strap",
                         value: signalReviewTitle,
                         tint: signalReviewTint)
            decisionStep(systemImage: "arrow.triangle.2.circlepath",
                         title: "Save",
                         value: "After type",
                         tint: .mint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review path. Review the window, strap window \(signalReviewTitle), then save after confirming type.")
    }

    private func decisionStep(systemImage: String, title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .atriaInsetCard(tint: tint)
    }

    private var reviewPathStrip: some View {
        HStack(spacing: 7) {
            pathStep("1", "Window", tint: .cyan)
            pathStep("2", "Type", tint: .orange)
            pathStep("3", "Exercises", tint: .mint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review path: adjust window, choose type, add exercises.")
    }

    private func pathStep(_ number: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var durationText: String {
        let minutes = candidate.durationMinutes
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private var timeRangeText: String {
        let startText = candidate.start.formatted(date: .omitted, time: .shortened)
        let endText = candidate.end.formatted(date: .omitted, time: .shortened)
        return "\(startText)-\(endText)"
    }

    private var signalReviewTitle: String {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 {
            return "Ready"
        }
        if candidate.streamCoveragePercent >= 60 {
            return "Review"
        }
        return "Check time"
    }

    private var signalReviewTint: Color {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 { return .mint }
        if candidate.streamCoveragePercent >= 60 { return .cyan }
        return .orange
    }

    private var signalReviewIcon: String {
        if candidate.streamCoveragePercent >= 75, candidate.gapCount == 0 { return "checkmark.seal.fill" }
        if candidate.streamCoveragePercent >= 60 { return "waveform.path.badge.plus" }
        return "exclamationmark.triangle.fill"
    }

}

private struct AtriaWorkoutReviewHoldBanner: View, Equatable {
    let state: AtriaHomeView.WorkoutReviewHoldState

    static func == (lhs: AtriaWorkoutReviewHoldBanner, rhs: AtriaWorkoutReviewHoldBanner) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            holdMark

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(state.title)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                    Text("Strap HR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.orange.opacity(0.12), in: Capsule(style: .continuous))
                }

                Text(state.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                holdPathStrip
            }
        }
        .padding(14)
        .atriaCard(emphasis: .soft)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.accessibilityText)
    }

    private var holdMark: some View {
        ZStack {
            Circle()
                .stroke(.orange.opacity(0.16), lineWidth: 7)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: symbolName)
                .font(.headline.weight(.bold))
                .foregroundStyle(.orange)
        }
        .frame(width: 54, height: 54)
        .accessibilityHidden(true)
    }

    private var progress: Double {
        switch state {
        case .waitingForSettle(let bpmOverRest):
            return min(max(Double(bpmOverRest) / 70.0, 0.22), 0.88)
        case .possibleSignal:
            return 0.42
        }
    }

    private var symbolName: String {
        switch state {
        case .waitingForSettle:
            return "heart.fill"
        case .possibleSignal:
            return "waveform.path.ecg"
        }
    }

    private var holdPathStrip: some View {
        HStack(spacing: 7) {
            holdStep("1", "Observe", tint: .orange)
            holdStep("2", "Settle", tint: .cyan)
            holdStep("3", "Ask", tint: .secondary)
        }
        .accessibilityHidden(true)
    }

    private func holdStep(_ number: String, _ title: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(number)
                .font(.caption2.weight(.black).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct AtriaWorkoutSignalMark: View, Equatable {
    let progress: Double
    let heartRate: Int
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.14), lineWidth: 7)
                .frame(width: 66, height: 66)

            Circle()
                .trim(from: 0, to: min(max(progress, 0.16), 1))
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 66, height: 66)

            VStack(spacing: 1) {
                Text("\(heartRate)")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 76)
        .accessibilityLabel("Strap HR peak \(heartRate) beats per minute")
    }
}

private struct AtriaWorkoutZoneEvidenceStrip: View, Equatable {
    let zone: Metrics.HeartRateZone

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(Metrics.heartRateZoneTint(index).opacity(index == zone.index ? 0.92 : 0.20))
                        .frame(maxWidth: .infinity)
                        .frame(height: index == zone.index ? 10 : 6)
                }
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(zone.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(zone.tint)
                Text(zone.name)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(zone.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(zone.tint.opacity(0.14), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate evidence \(zone.title), \(zone.name)")
    }
}

private struct AtriaWorkoutReviewFlow: View {
    let draft: AtriaWorkoutReviewDraft
    let onCancel: () -> Void
    let onSave: (AtriaWorkoutReviewResult) -> Void

    @State private var step: AtriaWorkoutReviewStep = .time
    @State private var start: Date
    @State private var end: Date
    @State private var selectedType: AtriaWorkoutActivityType = .strength
    @State private var selectedSubtype: String?
    @State private var selectedExercises = Set<String>()
    @State private var exerciseSearch = ""
    @State private var showsAllWorkoutTypes = false
    @State private var showWorkoutShareSheet = false

    init(draft: AtriaWorkoutReviewDraft,
         onCancel: @escaping () -> Void,
         onSave: @escaping (AtriaWorkoutReviewResult) -> Void) {
        self.draft = draft
        self.onCancel = onCancel
        self.onSave = onSave
        _start = State(initialValue: draft.suggestedStart)
        _end = State(initialValue: draft.suggestedEnd)
        _selectedType = State(initialValue: draft.prompt.suggestedActivityType)
        let suggestedType = draft.prompt.suggestedActivityType
        _selectedSubtype = State(initialValue: suggestedType.subtypeOptions.first)
        _step = State(initialValue: Self.debugInitialStep(arguments: ProcessInfo.processInfo.arguments))
    }

    private var visibleSteps: [AtriaWorkoutReviewStep] {
        selectedType.supportsExerciseSelection ? AtriaWorkoutReviewStep.allCases : [.time, .type, .summary]
    }

    private var visibleWorkoutTypes: [AtriaWorkoutActivityType] {
        guard !showsAllWorkoutTypes else { return AtriaWorkoutActivityType.allCases }
        var types = draft.prompt.suggestedActivityTypes
        if !types.contains(selectedType) {
            types.append(selectedType)
        }
        return types
    }

    private var hiddenWorkoutTypeCount: Int {
        max(AtriaWorkoutActivityType.allCases.count - visibleWorkoutTypes.count, 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtriaDashboardBackdrop()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            header
                            stepIndicator
                            currentStep
                        }
                        .padding(20)
                        .padding(.bottom, 28)
                    }
                    footer
                }
            }
            .navigationTitle("Review workout")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showWorkoutShareSheet) {
                AtriaWorkoutShareSheet(snapshot: makeWorkoutShareSnapshot())
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                AtriaWorkoutSignalMark(progress: draft.prompt.progressFraction,
                                       heartRate: draft.prompt.heartRate,
                                       tint: .orange)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Workout found")
                        .font(.title3.weight(.bold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                    Text("Check time, type, then save.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 7) {
                        headerChip("Peak \(draft.prompt.heartRate)", tint: .orange)
                        headerChip("\(draft.prompt.evidenceMinutes)m", tint: .cyan)
                        if let zone = draft.prompt.heartRateZone {
                            headerChip(zone.shortLabel, tint: zone.tint)
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 22, height: 22)
                }
                .atriaGlassIconAction(tint: .secondary, size: 38)
                .accessibilityLabel("Cancel workout review")
            }

            workoutReceiptBoard
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var workoutReceiptBoard: some View {
        HStack(spacing: 8) {
            workoutReceiptTile(title: "Time",
                               value: durationText,
                               detail: "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))",
                               systemImage: "clock.fill",
                               tint: .cyan)
            workoutReceiptTile(title: "Peak",
                               value: "\(draft.prompt.heartRate)",
                               detail: draft.prompt.heartRateZone?.shortLabel ?? "bpm",
                               systemImage: "waveform.path.ecg",
                               tint: draft.prompt.heartRateZone?.tint ?? .orange)
            workoutReceiptTile(title: "Type",
                               value: selectedType.rawValue,
                               detail: selectedSubtype ?? "Tap type",
                               systemImage: selectedType.icon,
                               tint: .orange)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout receipt. Time \(durationText). Peak \(draft.prompt.heartRate). Type \(selectedType.rawValue).")
    }

    private func workoutReceiptTile(title: String,
                                    value: String,
                                    detail: String,
                                    systemImage: String,
                                    tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: Circle())

            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.black).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }

    private var captureEvidenceStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("What Atria saw", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Text(draft.prompt.isReviewReady ? "Ready for you" : "Check timing")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(draft.prompt.isReviewReady ? .mint : .orange)
            }

            HStack(spacing: 8) {
                captureTile(title: "Time seen",
                            value: "\(draft.prompt.evidenceMinutes)m",
                            progress: min(max(Double(draft.prompt.evidenceMinutes) / 45.0, 0.08), 1),
                            tint: .cyan)
                captureTile(title: "Signal",
                            value: draft.prompt.confidenceLabel,
                            progress: draft.prompt.progressFraction,
                            tint: .orange)
                captureTile(title: "Next",
                            value: draft.prompt.isReviewReady ? "Confirm" : "Wait",
                            progress: draft.prompt.isReviewReady ? 1 : 0.58,
                            tint: draft.prompt.isReviewReady ? .mint : .secondary)
            }
        }
        .padding(12)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("What Atria saw. \(draft.prompt.evidenceMinutes) minutes of strap heart rate. Signal \(draft.prompt.confidenceLabel). Next \(draft.prompt.isReviewReady ? "confirm workout" : "wait or adjust timing").")
    }

    private func captureTile(title: String, value: String, progress: Double, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(value)
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.11))
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.72))
                        .frame(width: max(7, width * min(max(progress, 0), 1)))
                }
            }
            .frame(height: 7)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var reviewDecisionLens: some View {
        HStack(spacing: 8) {
            reviewDecisionMetric(title: "Confirm",
                                 value: "Looks right",
                                 systemImage: "checkmark.seal.fill",
                                 tint: .mint)
            reviewDecisionMetric(title: "Adjust",
                                 value: "Move time",
                                 systemImage: "slider.horizontal.3",
                                 tint: .cyan)
            reviewDecisionMetric(title: "Dismiss",
                                 value: "Not workout",
                                 systemImage: "xmark.circle.fill",
                                 tint: .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review choices. Confirm type, adjust time, or dismiss.")
    }

    private func reviewDecisionMetric(title: String, value: String, systemImage: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: Circle())
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .atriaInsetCard(tint: tint)
    }

    private var stepIndicator: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(visibleSteps, id: \.self) { candidate in
                    VStack(spacing: 7) {
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(candidate.rawValue <= step.rawValue ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.07))
                            Text(candidate.title)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(candidate == step ? .orange : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(height: 30)

                        Capsule(style: .continuous)
                            .fill(candidate.rawValue <= step.rawValue ? Color.orange : Color.secondary.opacity(0.18))
                            .frame(height: candidate == step ? 4 : 2)
                    }
                }
            }

            Text(stepSubtitle)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout review step \(step.title). \(stepContextAccessibilityText)")
    }

    private var stepSubtitle: String {
        switch step {
        case .time:
            return "Confirm time."
        case .type:
            return "Choose type."
        case .exercises:
            return "Add remembered moves."
        case .summary:
            return "Save workout."
        }
    }

    private var currentStepIndex: Int {
        visibleSteps.firstIndex(of: step).map { $0 + 1 } ?? 1
    }

    private var nextStepTitle: String {
        guard let index = visibleSteps.firstIndex(of: step) else { return "Save" }
        let nextIndex = visibleSteps.index(after: index)
        guard visibleSteps.indices.contains(nextIndex) else { return "Save" }
        return visibleSteps[nextIndex].title
    }

    private var stepContextAccessibilityText: String {
        "Now \(step.title), step \(currentStepIndex) of \(visibleSteps.count). Next \(nextStepTitle)."
    }

    private var stepContextRail: some View {
        HStack(spacing: 8) {
            stepContextChip(title: "Now",
                            value: step.title,
                            detail: "\(currentStepIndex)/\(visibleSteps.count)",
                            systemImage: "location.fill",
                            tint: .orange)
            stepContextChip(title: "Next",
                            value: nextStepTitle,
                            detail: selectedType.supportsExerciseSelection ? "Moves next" : "Type only",
                            systemImage: "arrow.forward.circle.fill",
                            tint: step == visibleSteps.last ? .mint : .cyan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stepContextAccessibilityText)
    }

    private func stepContextChip(title: String,
                                 value: String,
                                 detail: String,
                                 systemImage: String,
                                 tint: Color) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)

            Text(detail)
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(tint.opacity(0.12), lineWidth: 1)
        }
    }

    private func headerChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.10), in: Capsule(style: .continuous))
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .time:
            timeStep
        case .type:
            typeStep
        case .exercises:
            exerciseStep
        case .summary:
            summaryStep
        }
    }

    private var timeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Confirm time", subtitle: "Move start or end only if needed.")
            captureEvidenceStrip
            DatePicker("Start", selection: $start, displayedComponents: [.hourAndMinute, .date])
            DatePicker("End", selection: $end, displayedComponents: [.hourAndMinute, .date])
            reviewDecisionLens
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var typeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            stepTitle("What type was it?", subtitle: "Pick what you want saved.")
            suggestedTypeRunway
            selectedTypeLens
            typeRevealHeader
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                ForEach(visibleWorkoutTypes) { type in
                    Button {
                        applyWorkoutType(type)
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: type.icon)
                                .font(.caption.weight(.semibold))
                            Text(type.rawValue)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .atriaCardAction(prominent: selectedType == type, tint: selectedType == type ? .orange : .secondary)
                }
            }
            .animation(.snappy(duration: 0.2), value: showsAllWorkoutTypes)

            if !selectedType.subtypeOptions.isEmpty {
                chipSection(title: "Style", values: selectedType.subtypeOptions, selected: selectedSubtype) { value in
                    selectedSubtype = value
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var typeRevealHeader: some View {
        HStack(spacing: 10) {
            Label(showsAllWorkoutTypes ? "All activity types" : "Best matches first",
                  systemImage: showsAllWorkoutTypes ? "square.grid.3x3.fill" : "scope")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    showsAllWorkoutTypes.toggle()
                }
            } label: {
                Text(showsAllWorkoutTypes ? "Less" : "+\(hiddenWorkoutTypeCount)")
                    .font(.caption.weight(.black).monospacedDigit())
                    .foregroundStyle(.orange)
                    .frame(minWidth: 40)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
            }
            .atriaCardAction(prominent: false, tint: .orange)
            .accessibilityLabel(showsAllWorkoutTypes ? "Show fewer workout types" : "Show \(hiddenWorkoutTypeCount) more workout types")
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .contain)
    }

    private var suggestedTypeRunway: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested from strap HR", systemImage: "figure.strengthtraining.traditional")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Tap to choose")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                ForEach(draft.prompt.suggestedActivityTypes) { type in
                    Button {
                        applyWorkoutType(type)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: type.icon)
                                .font(.headline.weight(.bold))
                                .foregroundStyle(selectedType == type ? .orange : .secondary)
                                .frame(width: 30, height: 30)
                                .background((selectedType == type ? Color.orange : Color.secondary).opacity(0.12),
                                            in: Circle())
                            Text(type.rawValue)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(selectedType == type ? .orange : .primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Text(type.supportsExerciseSelection ? "Exercises next" : "Type only")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.70)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background((selectedType == type ? Color.orange : Color.secondary).opacity(selectedType == type ? 0.12 : 0.055),
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .stroke((selectedType == type ? Color.orange : Color.secondary).opacity(selectedType == type ? 0.20 : 0.10), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suggested activity \(type.rawValue). \(type.supportsExerciseSelection ? "Exercises next" : "Type only").")
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    private var selectedTypeLens: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.14))
                Image(systemName: selectedType.icon)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                Label("Selected type", systemImage: selectedType.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(selectedType.rawValue)
                    .font(.headline.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(selectedSubtype ?? (selectedType.supportsExerciseSelection ? "Exercises next" : "No exercise step"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                Text(selectedType.supportsExerciseSelection ? "3 steps" : "2 steps")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(selectedType.supportsExerciseSelection ? .mint : .secondary)
                Text(selectedType.supportsExerciseSelection ? "Exercises" : "Type only")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected type \(selectedType.rawValue). \(selectedSubtype ?? (selectedType.supportsExerciseSelection ? "Exercises next" : "No exercise step")).")
    }

    private var exerciseStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Add exercises", subtitle: "Pick remembered movements. Skip anything uncertain.")
            if exerciseQuery.isEmpty {
                exerciseQuickAddStrip
            }

            exerciseSearchPrompt

            TextField("Search exercises", text: $exerciseSearch)
                .textInputAutocapitalization(.words)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if !selectedExercises.isEmpty {
                chipSection(title: "Selected", values: selectedExerciseNames, selected: nil) { value in
                    selectedExercises.remove(value)
                }
            }

            if exerciseQuery.isEmpty {
                exerciseCatalogPreview
            } else {
                ForEach(AtriaWorkoutExerciseCatalog.filteredGroups(search: exerciseSearch)) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                            ForEach(group.exercises, id: \.self) { exercise in
                                exerciseChip(exercise)
                            }
                        }
                    }
                }
                if shouldOfferCustomExercise {
                    addCustomExerciseButton(exerciseQuery)
                }
            }
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var exerciseQuickAddStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Likely moves", systemImage: "plus.circle.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(selectedSuggestedExerciseCount)/\(promptExerciseSuggestions.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.orange)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                ForEach(promptExerciseSuggestions, id: \.self) { exercise in
                    quickExerciseButton(exercise)
                }
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .contain)
    }

    private var exerciseSearchPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Search only if needed")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                Text("Skip exercises if you are unsure.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search only if needed. Skip exercises if you are unsure.")
    }

    private var exerciseCatalogPreview: some View {
        HStack(spacing: 10) {
            Image(systemName: "books.vertical.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.cyan)
                .frame(width: 28, height: 28)
                .background(Color.cyan.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Search full catalog")
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text("\(AtriaWorkoutExerciseCatalog.groups.count) groups ready when needed")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .atriaInsetCard(tint: .cyan)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Search full exercise catalog. \(AtriaWorkoutExerciseCatalog.groups.count) groups ready when needed.")
    }

    private func quickExerciseButton(_ exercise: String) -> some View {
        let selected = selectedExercises.contains(exercise)
        return Button {
            toggleExercise(exercise)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(selected ? .mint : .orange)
                Text(exercise)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(selected ? .mint : .primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background((selected ? Color.mint : Color.orange).opacity(selected ? 0.12 : 0.08),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke((selected ? Color.mint : Color.orange).opacity(selected ? 0.18 : 0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected ? "Remove" : "Add") \(exercise)")
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            stepTitle("Save to Atria", subtitle: "Check what gets remembered.")
            summaryReceiptLens
        }
        .padding(16)
        .atriaCard(emphasis: .soft)
    }

    private var summaryReceiptLens: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.orange.opacity(0.14), lineWidth: 7)
                    Circle()
                        .trim(from: 0, to: min(max(draft.prompt.progressFraction, 0.12), 1))
                        .stroke(Color.orange.opacity(0.88),
                                style: StrokeStyle(lineWidth: 7, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: selectedType.icon)
                        .font(.headline.weight(.black))
                        .foregroundStyle(.orange)
                }
                .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedType.rawValue)
                        .font(.title3.weight(.black))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                    Text(selectedSubtype ?? "Reviewed workout")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(durationText)
                        .font(.title2.weight(.black).monospacedDigit())
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText())
                    Text("Strap HR")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange.opacity(0.12), in: Capsule(style: .continuous))
                }
            }

            HStack(spacing: 8) {
                summaryReceiptMetric(title: "Time",
                                     value: durationText,
                                     detail: summaryTimeRangeText,
                                     tint: .cyan)
                summaryReceiptMetric(title: "Type",
                                     value: selectedType.rawValue,
                                     detail: selectedSubtype ?? "Activity",
                                     tint: .orange)
                summaryReceiptMetric(title: "Moves",
                                     value: selectedExercises.isEmpty ? "0" : "\(selectedExercises.count)",
                                     detail: selectedExercises.isEmpty ? "Optional" : "Selected",
                                     tint: .mint)
            }

            summaryMemoryRail
            summaryExerciseHistorySection

            if let zone = draft.prompt.heartRateZone {
                AtriaWorkoutZoneEvidenceStrip(zone: zone)
            }

            Button {
                showWorkoutShareSheet = true
            } label: {
                Label("Share workout", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)

            if !selectedExercises.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Movements saved locally", systemImage: "checkmark.seal.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(selectedExerciseNames.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(12)
        .atriaInsetCard(tint: .orange)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workout save receipt. Window \(summaryTimeRangeText), \(durationText). Type \(selectedType.rawValue). Exercises \(selectedExercises.count). Save to history and learn from this label. Source strap heart rate.")
    }

    @ViewBuilder
    private var summaryExerciseHistorySection: some View {
        let rows = summaryExerciseHistoryRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Exercise history", systemImage: "chart.xyaxis.line")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Text("\(rows.count)")
                        .font(.caption2.monospacedDigit().weight(.black))
                        .foregroundStyle(.orange)
                }

                ForEach(rows) { row in
                    summaryExerciseHistoryRow(row)
                }
            }
            .padding(10)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.orange.opacity(0.10), lineWidth: 1)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Exercise history from saved sessions. \(rows.count) movements.")
        }
    }

    private var summaryExerciseHistoryRows: [AtriaWorkoutSummaryExerciseHistory] {
        let exercises = summaryExerciseHistoryNames
        return exercises.map { exercise in
            let history = AtriaStrengthLog.history(for: exercise, in: draft.strengthHistorySessions)
            let records = AtriaStrengthLog.personalRecords(for: exercise, in: draft.strengthHistorySessions)
            let currentBest = draft.strengthSets
                .filter { normalizedExercise($0.exercise) == normalizedExercise(exercise) }
                .max(by: { strengthShareScore($0) < strengthShareScore($1) })
            let isPR = currentBest.map { AtriaStrengthLog.isPR($0, against: records) } ?? false
            let sparkline = history.map { strengthShareScore($0.best) }
            return AtriaWorkoutSummaryExerciseHistory(exercise: exercise,
                                                      days: history.count,
                                                      bestSet: history.last?.best,
                                                      maxE1RM: records.maxE1RM,
                                                      maxWeightKg: records.maxWeightKg,
                                                      sparklineValues: sparkline,
                                                      currentPRSet: isPR ? currentBest : nil)
        }
    }

    private var summaryExerciseHistoryNames: [String] {
        var names: [String] = []
        for name in selectedExerciseNames + draft.strengthSets.map(\.exercise) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !names.contains(where: { normalizedExercise($0) == normalizedExercise(trimmed) }) else {
                continue
            }
            names.append(trimmed)
        }
        return Array(names.prefix(4))
    }

    private func summaryExerciseHistoryRow(_ row: AtriaWorkoutSummaryExerciseHistory) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.exercise)
                    .font(.caption.weight(.black))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Spacer(minLength: 8)

                Text(row.days == 0 ? "New" : "\(row.days)d")
                    .font(.caption2.monospacedDigit().weight(.black))
                    .foregroundStyle(row.days == 0 ? .mint : .orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((row.days == 0 ? Color.mint : Color.orange).opacity(0.12),
                                in: Capsule(style: .continuous))

                if row.currentPRSet != nil {
                    Label("PR", systemImage: "trophy.fill")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.yellow.opacity(0.12), in: Capsule(style: .continuous))
                }
            }

            AtriaWorkoutSummarySparkline(values: row.sparklineValues, tint: .orange)
                .frame(height: 32)

            HStack(spacing: 8) {
                summaryExerciseMetric("Best", row.bestSet.map(strengthSetShareText) ?? "--")
                summaryExerciseMetric("e1RM", row.maxE1RM.map { Self.formatShareWeightKg($0) } ?? "--")
                summaryExerciseMetric("Max", row.maxWeightKg.map { Self.formatShareWeightKg($0) } ?? "--")
            }
        }
        .padding(10)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exercise history \(row.exercise). \(row.days) saved days. Best \(row.bestSet.map(strengthSetShareText) ?? "none"). \(row.currentPRSet == nil ? "" : "New PR.")")
    }

    private func summaryExerciseMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryMemoryRail: some View {
        HStack(spacing: 8) {
            summaryMemoryNode(title: "Save",
                              value: "Workout",
                              systemImage: "checkmark.seal.fill",
                              tint: .mint)
            summaryMemoryNode(title: "History",
                              value: selectedType.rawValue,
                              systemImage: "clock.arrow.circlepath",
                              tint: .orange)
            summaryMemoryNode(title: "Remember",
                              value: selectedExercises.isEmpty ? "Label" : "\(selectedExercises.count) moves",
                              systemImage: "arrow.triangle.2.circlepath",
                              tint: .cyan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("After save, Atria adds the workout to history and remembers the selected label.")
    }

    private func summaryMemoryNode(title: String, value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.11), lineWidth: 1)
        }
    }

    private func summaryReceiptMetric(title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(detail)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != visibleSteps.first {
                Button("Back") {
                    moveBack()
                }
                .atriaCardAction(prominent: false, tint: .secondary)
            }

            Button(primaryActionTitle) {
                primaryAction()
            }
            .disabled(end <= start)
            .atriaCardAction(tint: .orange)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .atriaInsetCard(cornerRadius: 28, tint: .orange)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var primaryActionTitle: String {
        step == .summary ? "Save workout" : "Continue"
    }

    private var durationText: String {
        let minutes = max(1, Int(end.timeIntervalSince(start) / 60))
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }

    private var summaryTimeRangeText: String {
        "\(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))"
    }

    private func makeWorkoutShareSnapshot() -> AtriaWorkoutShareSnapshot {
        AtriaWorkoutShareSnapshot(date: end,
                                  activity: selectedType.rawValue,
                                  duration: durationText,
                                  strain: String(format: "%.1f", draft.prompt.strain),
                                  peakHeartRate: "\(draft.prompt.heartRate)",
                                  zoneMinutes: workoutShareZoneMinutes(),
                                  personalRecord: workoutSharePersonalRecord())
    }

    private func workoutSharePersonalRecord() -> AtriaWorkoutShareSnapshot.PersonalRecord? {
        let currentPRs = draft.strengthSets.filter { set in
            AtriaStrengthLog.isPR(set,
                                  against: AtriaStrengthLog.personalRecords(for: set.exercise,
                                                                            in: draft.strengthHistorySessions))
        }
        guard let best = currentPRs.max(by: { strengthShareScore($0) < strengthShareScore($1) }) else {
            return nil
        }
        return AtriaWorkoutShareSnapshot.PersonalRecord(exercise: best.exercise,
                                                        set: strengthSetShareText(best),
                                                        badge: "PR")
    }

    private func strengthShareScore(_ set: LoggedSet) -> Double {
        AtriaStrengthLog.estimatedOneRepMax(weightKg: set.weightKg, reps: set.reps)
            ?? set.weightKg
            ?? Double(set.reps ?? 0)
    }

    private func normalizedExercise(_ exercise: String) -> String {
        exercise.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func strengthSetShareText(_ set: LoggedSet) -> String {
        let weightText = set.weightKg.map { Self.formatShareWeightKg($0) }
        let repsText = set.reps.map { "\($0)" }
        switch (weightText, repsText) {
        case let (weight?, reps?):
            return "\(weight) x \(reps)"
        case let (weight?, nil):
            return weight
        case let (nil, reps?):
            return "\(reps) reps"
        default:
            return "New best"
        }
    }

    private static func formatShareWeightKg(_ weightKg: Double) -> String {
        let rounded = weightKg.rounded()
        if abs(weightKg - rounded) < 0.01 {
            return "\(Int(rounded)) kg"
        }
        return String(format: "%.1f kg", weightKg)
    }

    private func workoutShareZoneMinutes() -> [AtriaWorkoutShareSnapshot.ZoneMinute] {
        let activeZone = draft.prompt.heartRateZone?.index
        let activeMinutes = draft.prompt.evidenceMinutes
        return (1...5).map { index in
            AtriaWorkoutShareSnapshot.ZoneMinute(id: index,
                                                label: "Z\(index)",
                                                minutes: activeZone == index ? activeMinutes : 0,
                                                tintHex: workoutShareZoneTintHex(index))
        }
    }

    private func workoutShareZoneTintHex(_ index: Int) -> String {
        switch index {
        case 1: return "#56d7ff"
        case 2: return "#42f59b"
        case 3: return "#f5d142"
        case 4: return "#ff8a3d"
        default: return "#ff4f7b"
        }
    }

    private var selectedExerciseNames: [String] {
        Array(selectedExercises).sorted()
    }

    private var exerciseQuery: String {
        exerciseSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldOfferCustomExercise: Bool {
        guard !exerciseQuery.isEmpty else { return false }
        let existing = AtriaWorkoutExerciseCatalog.allGroups()
            .flatMap(\.exercises)
            .contains { $0.compare(exerciseQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        return !existing
    }

    private var promptExerciseSuggestions: [String] {
        draft.prompt.exerciseSuggestions.flatMap { suggestion in
            AtriaWorkoutExerciseCatalog.suggestedExercises(for: suggestion)
        }
    }

    private var selectedSuggestedExerciseCount: Int {
        promptExerciseSuggestions.filter { selectedExercises.contains($0) }.count
    }

    private func stepTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline.weight(.bold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func reviewMetricRow(_ values: [(String, String)]) -> some View {
        HStack(spacing: 8) {
            ForEach(values, id: \.0) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                    Text(item.1)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func chipSection(title: String,
                             values: [String],
                             selected: String?,
                             onTap: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(values, id: \.self) { value in
                    Button(value) { onTap(value) }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background((selected == value ? Color.orange : Color.secondary).opacity(0.12),
                                    in: Capsule(style: .continuous))
                        .foregroundStyle(selected == value ? Color.orange : Color.secondary)
                }
            }
        }
    }

    private func exerciseChip(_ exercise: String) -> some View {
        let selected = selectedExercises.contains(exercise)
        return Button {
            toggleExercise(exercise)
        } label: {
            Text(exercise)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background((selected ? Color.orange : Color.secondary).opacity(selected ? 0.14 : 0.08),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(selected ? Color.orange : Color.primary)
    }

    private func addCustomExerciseButton(_ exercise: String) -> some View {
        Button {
            AtriaWorkoutExerciseCatalog.addCustomExercise(exercise)
            selectedExercises.insert(exercise)
            exerciseSearch = ""
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add \"\(exercise)\"")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("Save as a custom exercise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color.mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.mint.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add custom exercise \(exercise)")
    }

    private func toggleExercise(_ exercise: String) {
        if selectedExercises.contains(exercise) {
            selectedExercises.remove(exercise)
        } else {
            selectedExercises.insert(exercise)
        }
    }

    private func primaryAction() {
        if step == .summary {
            onSave(AtriaWorkoutReviewResult(start: start,
                                            end: end,
                                            activityType: selectedType.rawValue,
                                            activitySubtype: selectedSubtype,
                                            exerciseNames: selectedExerciseNames,
                                            strengthSets: draft.strengthSets))
            return
        }
        if step == .type, !selectedType.supportsExerciseSelection {
            step = .summary
            return
        }
        if let index = visibleSteps.firstIndex(of: step),
           visibleSteps.indices.contains(visibleSteps.index(after: index)) {
            step = visibleSteps[visibleSteps.index(after: index)]
        }
    }

    private func applyWorkoutType(_ type: AtriaWorkoutActivityType) {
        selectedType = type
        if selectedType.subtypeOptions.isEmpty {
            selectedSubtype = nil
        } else {
            selectedSubtype = selectedType.subtypeOptions.first
        }
        if !selectedType.supportsExerciseSelection {
            selectedExercises.removeAll()
        }
    }

    private func moveBack() {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return }
        step = visibleSteps[index - 1]
    }

    #if DEBUG
    private static func debugInitialStep(arguments: [String]) -> AtriaWorkoutReviewStep {
        if arguments.contains("--atria-workout-review-type-step") { return .type }
        if arguments.contains("--atria-workout-review-exercises-step") { return .exercises }
        if arguments.contains("--atria-workout-review-summary-step") { return .summary }
        return .time
    }
    #else
    private static func debugInitialStep(arguments: [String]) -> AtriaWorkoutReviewStep { .time }
    #endif
}

private struct AtriaWorkoutSummaryExerciseHistory: Identifiable {
    let id = UUID()
    let exercise: String
    let days: Int
    let bestSet: LoggedSet?
    let maxE1RM: Double?
    let maxWeightKg: Double?
    let sparklineValues: [Double]
    let currentPRSet: LoggedSet?
}

private struct AtriaWorkoutSummarySparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let normalized = normalizedValues
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            let step = normalized.count > 1 ? width / CGFloat(normalized.count - 1) : width
            Path { path in
                guard let first = normalized.first else { return }
                path.move(to: CGPoint(x: 0, y: height - (height * first)))
                for index in normalized.indices.dropFirst() {
                    path.addLine(to: CGPoint(x: CGFloat(index) * step,
                                             y: height - (height * normalized[index])))
                }
            }
            .stroke(tint.opacity(normalized.count > 1 ? 0.90 : 0.28),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

            if normalized.isEmpty {
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.16))
                    .frame(height: 3)
                    .position(x: width / 2, y: height / 2)
            }
        }
        .accessibilityHidden(true)
    }

    private var normalizedValues: [CGFloat] {
        guard let minValue = values.min(),
              let maxValue = values.max(),
              maxValue > 0 else {
            return []
        }
        let spread = max(maxValue - minValue, 1)
        return values.map { value in
            CGFloat(0.16 + (0.78 * ((value - minValue) / spread)))
        }
    }
}

private struct AtriaLiveTabAccessory: View {
    @ObservedObject var liveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseStore: AtriaHomeModel.PulseLiveStore
    let workoutStart: Date?
    let strain: Double
    let onOpenWorkout: () -> Void
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    private var isInline: Bool {
        placement == .inline
    }

    var body: some View {
        Button {
            if workoutStart != nil {
                onOpenWorkout()
            }
        } label: {
            // Live bar: strap battery by default; during a minimized workout it
            // becomes the return handle with elapsed time, live HR, and strain.
            HStack(spacing: isInline ? 8 : 10) {
                Image(systemName: workoutStart == nil ? "heart.fill" : "figure.run.circle.fill")
                    .font(isInline ? .caption.weight(.bold) : .subheadline.weight(.bold))
                    .foregroundStyle(workoutStart == nil ? .red : Metrics.electricStrain)

                if let workoutStart {
                    TimelineView(.periodic(from: workoutStart, by: 1)) { context in
                        Text(elapsedText(context.date, since: workoutStart))
                            .font((isInline ? Font.caption : Font.subheadline).weight(.bold))
                            .monospacedDigit()
                    }

                    Text(pulseStore.state.heartRate > 0 ? "\(pulseStore.state.heartRate) bpm" : "-- bpm")
                        .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                        .monospacedDigit()

                    Text(String(format: "%.1f strain", strain))
                        .font((isInline ? Font.caption2 : Font.caption).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                } else {
                    Image(systemName: liveStore.state.batterySymbol)
                        .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(liveStore.state.batteryShowsPowered ? Color.green : .secondary)

                    Text(liveStore.state.batteryText)
                        .font((isInline ? Font.caption : Font.subheadline).weight(.semibold))
                        .monospacedDigit()

                    Text(isInline ? liveStore.state.batteryChargeCompactText : liveStore.state.batteryChargeText)
                        .font((isInline ? Font.caption2 : Font.caption).weight(.semibold))
                        .foregroundStyle(liveStore.state.batteryShowsPowered ? .green : .secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }

                if !isInline { Spacer(minLength: 0) }
            }
            .padding(.horizontal, isInline ? 8 : 12)
            .padding(.vertical, isInline ? 4 : 8)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if workoutStart != nil {
            return "Live workout minimized. Tap to return. Heart rate \(pulseStore.state.heartRate), strain \(String(format: "%.1f", strain))."
        }
        return "Live strap, \(liveStore.state.batteryAccessibilityText)"
    }

    private func elapsedText(_ date: Date, since start: Date) -> String {
        let total = max(0, Int(date.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
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
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.3), value: pulseLiveStore.state.heartRate)
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
                                       detail: heroStore.state.recoveryDetail,
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
        static let liveRecoveryGraceInterval: TimeInterval = 45

        var status: AtriaBLEManager.Status
        var bluetoothPermissionDenied: Bool
        var deviceName: String
        var displayDeviceName: String
        var batteryLevel: Int
        var batteryIsCharging: Bool
        var batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus
        var batteryRecentlyDropping: Bool
        var strapStreamState: AtriaBLEManager.StrapStreamState
        var rrContinuityState: String
        var hrvSDNN: Double?
        var hrvPNN50: Double?
        var sessionSampleCount: Int
        var hasRecentHeartRateSample: Bool
        var lastReadingAt: Date?
        var liveTRIMP: Double
        var liveActiveCalories: Double?
        var officialAppCoexistenceRisk: AtriaBLEManager.OfficialAppCoexistenceRisk
        var lastScanRequestedAt: Date?
        var lastScanMatchAt: Date?
        var pendingKnownReconnectStartedAt: Date?
        var pendingKnownReconnectReason: String
        var rangeLossBackfillPending: Bool

        var batteryText: String { batteryLevel >= 0 ? "\(batteryLevel)%" : "Pending" }
        var batteryChargeText: String {
            guard batteryLevel >= 0 else { return "Waiting for strap battery" }
            switch batteryChargeStatus {
            case .levelOnly: return "Charger unknown"
            case .charging: return "Strap charging"
            case .notCharging: return "Strap not charging"
            case .full: return "Strap full"
            }
        }
        private var hasActiveChargingEvidence: Bool {
            batteryIsCharging && batteryChargeStatus == .charging && !batteryRecentlyDropping
        }
        var batteryShowsPowered: Bool { hasActiveChargingEvidence }
        var batteryChargeCompactText: String {
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "Strap state pending"
            }
            switch batteryChargeStatus {
            case .levelOnly: return "Strap state pending"
            case .charging: return "Strap charging"
            case .notCharging: return "Strap not charging"
            case .full: return "Strap full"
            }
        }
        var batteryHeaderChargeText: String {
            guard batteryLevel >= 0 else { return "--" }
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "--"
            }
            switch batteryChargeStatus {
            case .levelOnly: return "--"
            case .charging: return "Strap charging"
            case .notCharging: return "Strap not charging"
            case .full: return "Strap full"
            }
        }
        var batteryHeaderAccessoryText: String? {
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return nil
            }
            switch batteryChargeStatus {
            case .charging: return "Charging"
            case .full: return "Full"
            case .levelOnly, .notCharging: return nil
            }
        }
        var batteryAccessibilityChargeText: String {
            guard batteryLevel >= 0 else { return "waiting for strap battery" }
            return batteryHeaderChargeText == "--" ? batteryChargeText : batteryHeaderChargeText
        }
        var batteryAccessibilityText: String {
            guard batteryLevel >= 0 else { return "Strap battery pending." }
            return "Strap battery \(batteryText), \(batteryAccessibilityChargeText)."
        }
        var batteryStatusSummaryText: String {
            guard batteryLevel >= 0 else { return "Battery pending" }
            return "\(batteryText) · \(batteryChargeCompactText)"
        }
        var lastReadingAgeText: String {
            guard let lastReadingAt else { return "recently" }
            let age = max(0, Date().timeIntervalSince(lastReadingAt))
            if age < 2 { return "just now" }
            if age < 60 { return "\(Int(age.rounded())) s ago" }
            if age < 3_600 { return "\(Int((age / 60).rounded())) min ago" }
            return "\(Int((age / 3_600).rounded())) hr ago"
        }
        var batteryDetailText: String {
            guard batteryLevel >= 0 else { return "Waiting for strap battery" }
            if batteryChargeStatus == .charging && !hasActiveChargingEvidence {
                return "Strap battery level is live; waiting for fresh charger evidence"
            }
            return batteryChargeStatus == .levelOnly ? "Strap battery level is live; waiting for strap charger-state signal" : batteryHeaderChargeText
        }
        var rrContinuityText: String { rrContinuityState.replacingOccurrences(of: "_", with: " ") }
        var hrvSDNNText: String { hrvSDNN.map { "\(Int($0.rounded()))" } ?? "--" }
        var hrvPNN50Text: String { hrvPNN50.map { "\(Int($0.rounded()))%" } ?? "--" }
        var needsRRQualityCoach: Bool { rrContinuityState == "poor_contact" }
        func pendingKnownReconnectAge(now: Date = Date()) -> TimeInterval? {
            pendingKnownReconnectStartedAt.map { now.timeIntervalSince($0) }
        }
        func isInRecentLiveRecovery(now: Date = Date()) -> Bool {
            guard !hasRecentHeartRateSample, status != .poweredOff else { return false }
            if let reconnectAge = pendingKnownReconnectAge(now: now),
               reconnectAge >= 0,
               reconnectAge <= Self.liveRecoveryGraceInterval {
                return true
            }
            guard rangeLossBackfillPending else { return false }
            if let matchAt = lastScanMatchAt,
               now.timeIntervalSince(matchAt) <= Self.liveRecoveryGraceInterval {
                return true
            }
            if let requestedAt = lastScanRequestedAt,
               now.timeIntervalSince(requestedAt) <= Self.liveRecoveryGraceInterval {
                return status == .connecting || status == .scanning
            }
            return false
        }
        var liveActiveCaloriesText: String { liveActiveCalories.map { "\(Int($0.rounded()))" } ?? "--" }
        var isLowBatteryBroadcastShutoff: Bool { strapStreamState == .lowBatteryShutoff }
        var isLowBatteryLiveLimited: Bool {
            strapStreamState == .lowBatteryShutoff || strapStreamState == .lowBatteryReducedDetail
        }
        var strapStreamConnectionLabel: String {
            switch strapStreamState {
            case .live:
                return "Live"
            case .lowBatteryShutoff:
                return "Charge strap"
            case .lowBatteryReducedDetail:
                return "Low battery"
            case .silentUnknown:
                return "No signal"
            case .warming:
                return "Waiting"
            case .unknown:
                return hasRecentHeartRateSample ? "Live" : "Pending"
            }
        }
        var strapStreamConnectionDetail: String {
            switch strapStreamState {
            case .live:
                return "Live heart rate is arriving"
            case .lowBatteryShutoff:
                return "Strap battery too low for live heart rate. Charge to resume."
            case .lowBatteryReducedDetail:
                return "Low-battery mode. Reduced detail until charged."
            case .silentUnknown:
                return "Strap connected, but live heart rate is not arriving"
            case .warming:
                return "Waiting for live heart rate"
            case .unknown:
                return hasRecentHeartRateSample ? "Live heart rate is arriving" : "Strap stream state pending"
            }
        }
        var strapStreamConnectionSymbol: String {
            switch strapStreamState {
            case .live:
                return "bolt.heart.fill"
            case .lowBatteryShutoff, .lowBatteryReducedDetail:
                return "battery.25percent"
            case .silentUnknown:
                return "heart.slash"
            case .warming:
                return "waveform.path.ecg"
            case .unknown:
                return hasRecentHeartRateSample ? "bolt.heart.fill" : "antenna.radiowaves.left.and.right"
            }
        }

        /// SF Symbol matching the level, with the bolt overlay while charging.
        var batterySymbol: String {
            guard batteryLevel >= 0 else { return "battery.0percent" }
            if batteryShowsPowered { return "battery.100percent.bolt" }
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
        var heartRateZone: Metrics.HeartRateZone?
        var recentRRSamples: [AtriaBreathworkSession.RRSample] = []

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
        var heartRateZone: Metrics.HeartRateZone?
        var heartRateBroadcastActive: Bool = false
        var recentRRSamples: [AtriaBreathworkSession.RRSample] = []

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
            longWearModeEnabled ? "All-day wear" : collectionProfile.label
        }
        var coexistenceStatusText: String { officialAppCoexistenceRisk.label }
    }

    struct HeroSnapshot: Equatable {
        let recoveryEstimate: Metrics.RecoveryEstimate
        let recoveryIsProvisional: Bool
        let recoveryLiftedAfterNap: Bool
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
            let base = recoveryIsProvisional
                ? "\(recoveryEstimate.confidence.rawValue) · provisional"
                : recoveryEstimate.confidence.rawValue
            return recoveryLiftedAfterNap ? "\(base) · ↑ after nap" : base
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
                && lhs.recoveryIsProvisional == rhs.recoveryIsProvisional
                && lhs.recoveryLiftedAfterNap == rhs.recoveryLiftedAfterNap
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
    #if DEBUG
    private let debugHeroFixture: HeroSnapshot?
    #endif

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
        let initialHeroPulse = Self.makeHeroPulseState(ble: ble,
                                                       rest: initialLiveSessionDerived.rest,
                                                       maxHR: initialLiveSessionDerived.maxHR)
        let initialPulseLive = Self.makePulseLiveState(ble: ble,
                                                       rest: initialLiveSessionDerived.rest,
                                                       maxHR: initialLiveSessionDerived.maxHR)
        let initialPulseSparkline = Self.makePulseSparklineState(ble: ble)
        let initialCollectionLive = Self.makeCollectionLiveState(ble: ble)
        let initialHero = Self.makeHeroSnapshot(ble: ble,
                                                store: store,
                                                live: initialCoreLive,
                                                savedAggregate: self.savedAggregate,
                                                deferredDetails: nil)
        let initialHeroState: HeroSnapshot
        #if DEBUG
        let debugHeroFixture = Self.debugFixtureProvisionalRecoveryHeroSnapshot(arguments: ProcessInfo.processInfo.arguments)
        self.debugHeroFixture = debugHeroFixture
        initialHeroState = debugHeroFixture ?? initialHero
        if let debugHeroFixture {
            AtriaDebugLog("ATRIADBG slp3_fixture status=provisional_recovery percent=%d detail=%@ provisional=%d",
                          debugHeroFixture.recoveryEstimate.percent ?? 0,
                          debugHeroFixture.recoveryDetail.replacingOccurrences(of: " ", with: "_"),
                          debugHeroFixture.recoveryIsProvisional ? 1 : 0)
        }
        #else
        initialHeroState = initialHero
        #endif
        let initialHomeStats = Self.makeHomeStatsState(hero: initialHero)
        let initialProfileMetrics = Self.makeProfileMetricsState(store: store,
                                                                 liveSessionDerived: initialLiveSessionDerived)
        self.liveSessionDerived = initialLiveSessionDerived
        self.heroStore = HeroStore(state: initialHeroState)
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
            ble.$strapStreamState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rrContinuityState.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$sessionSampleCount.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$officialAppCoexistenceRisk.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanRequestedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$lastScanMatchAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectStartedAt.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$pendingKnownReconnectReason.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
            ble.$rangeLossBackfillPending.removeDuplicates().map { _ in () }.eraseToAnyPublisher()
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
        refreshLiveSessionDerivedIfNeeded()
        var next = Self.makeHeroPulseState(ble: ble,
                                           rest: liveSessionDerived.rest,
                                           maxHR: liveSessionDerived.maxHR)
        next.heartRateBroadcastActive = heroPulseStore.state.heartRateBroadcastActive
        // RR intervals arrive several times a second and the array is only read
        // by the breathwork pacer: refreshing it at most 1 Hz stops per-beat
        // array churn from defeating this dedupe and invalidating every
        // hero/pulse consumer per heartbeat. No RR data is lost — the window
        // array carries all recent beats when it does refresh. Each publisher
        // owns its own stamp so call order cannot phase-lock one of them stale.
        if Date().timeIntervalSince(lastHeroRRRefreshAt) < 1.0 {
            next.recentRRSamples = heroPulseStore.state.recentRRSamples
        } else {
            lastHeroRRRefreshAt = Date()
        }
        guard next != heroPulseStore.state else { return }
        heroPulseStore.state = next
    }

    func setHeartRateBroadcastActive(_ active: Bool) {
        guard heroPulseStore.state.heartRateBroadcastActive != active else { return }
        heroPulseStore.state.heartRateBroadcastActive = active
    }

    private func publishPulseLive() {
        refreshLiveSessionDerivedIfNeeded()
        var next = Self.makePulseLiveState(ble: ble,
                                           rest: liveSessionDerived.rest,
                                           maxHR: liveSessionDerived.maxHR)
        // Same 1 Hz RR refresh policy as publishHeroPulse (see comment there).
        if Date().timeIntervalSince(lastPulseRRRefreshAt) < 1.0 {
            next.recentRRSamples = pulseLiveStore.state.recentRRSamples
        } else {
            lastPulseRRRefreshAt = Date()
        }
        guard next != pulseLiveStore.state else { return }
        pulseLiveStore.state = next
    }

    private func publishPulseSparkline() {
        let next = Self.makePulseSparklineState(ble: ble)
        guard next != pulseSparklineStore.state else { return }
        // The chart buckets per second, but RR/HR arrive several times a second —
        // publishing each beat re-merged and re-laid-out the Swift Charts
        // timeline per heartbeat. 1 Hz is the chart's native resolution; the
        // hero BPM digit stays on the un-gated pulseLiveStore so perceived
        // liveness is unchanged. Staleness is bounded: the next beat after the
        // window publishes.
        let now = Date()
        guard now.timeIntervalSince(lastPulseSparklinePublishAt) >= 1.0 else { return }
        lastPulseSparklinePublishAt = now
        pulseSparklineStore.state = next
    }

    private var lastPulseSparklinePublishAt = Date.distantPast
    private var lastHeroRRRefreshAt = Date.distantPast
    private var lastPulseRRRefreshAt = Date.distantPast

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
        #if DEBUG
        if let debugHeroFixture {
            publishHeroSnapshotIfNeeded(debugHeroFixture)
            return
        }
        #endif
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
                let nextHero: HeroSnapshot
                #if DEBUG
                if let debugHeroFixture = self.debugHeroFixture {
                    nextHero = debugHeroFixture
                } else {
                    nextHero = Self.makeHeroSnapshot(ble: self.ble,
                                                     store: self.store,
                                                     live: self.coreLiveStore.state,
                                                     savedAggregate: self.savedAggregate,
                                                     deferredDetails: details)
                }
                #else
                nextHero = Self.makeHeroSnapshot(ble: self.ble,
                                                 store: self.store,
                                                 live: self.coreLiveStore.state,
                                                 savedAggregate: self.savedAggregate,
                                                 deferredDetails: details)
                #endif
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
                             strapStreamState: ble.strapStreamState,
                             rrContinuityState: ble.rrContinuityState,
                             hrvSDNN: ble.hrvSnapshot?.sdnn,
                             hrvPNN50: ble.hrvSnapshot?.pnn50,
                             sessionSampleCount: liveSessionDerived.sampleCount,
                             hasRecentHeartRateSample: hasRecentHeartRateSample(ble: ble),
                             lastReadingAt: liveSessionDerived.lastTimestamp,
                             liveTRIMP: liveSessionDerived.trimp,
                             liveActiveCalories: liveSessionDerived.activeCalories,
                             officialAppCoexistenceRisk: ble.officialAppCoexistenceRisk,
                             lastScanRequestedAt: ble.lastScanRequestedAt,
                             lastScanMatchAt: ble.lastScanMatchAt,
                             pendingKnownReconnectStartedAt: ble.pendingKnownReconnectStartedAt,
                             pendingKnownReconnectReason: ble.pendingKnownReconnectReason,
                             rangeLossBackfillPending: ble.rangeLossBackfillPending)
    }

    private static func makePulseLiveState(ble: AtriaBLEManager, rest: Int, maxHR: Int) -> PulseLiveState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return PulseLiveState(heartRate: reconciledHeartRate,
                              hasContact: ble.hasContact || reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact,
                              averageHeartRate: ble.liveHeartWindow.average,
                              peakHeartRate: ble.liveHeartWindow.peak,
                              heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,
                                                                    rest: rest,
                                                                    max: maxHR),
                              recentRRSamples: ble.recentBreathworkRRSamples())
    }

    private static func makeHeroPulseState(ble: AtriaBLEManager, rest: Int, maxHR: Int) -> HeroPulseState {
        let reconciledHeartRate = liveHeartRate(ble: ble)
        return HeroPulseState(heartRate: reconciledHeartRate,
                              hasContact: ble.hasContact || reconciledHeartRate > 0,
                              sensorHasContact: ble.hasContact,
                              heartRateZone: Metrics.heartRateZone(bpm: reconciledHeartRate,
                                                                    rest: rest,
                                                                    max: maxHR),
                              recentRRSamples: ble.recentBreathworkRRSamples())
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

    private static func hasRecentHeartRateSample(ble: AtriaBLEManager, now: Date = Date()) -> Bool {
        if ble.heartRate > 0 { return true }
        if let latest = ble.session.last, latest.bpm > 0,
           now.timeIntervalSince(latest.t) <= 180 {
            return true
        }
        return ble.status == .connected
            && (ble.liveHeartWindow.sparkline.contains { $0 > 0 } || (ble.liveHeartWindow.average ?? 0) > 0)
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
        let recoveryIsProvisional = latestSleep?.confirmed == false
        let baseRecovery = Metrics.recoveryV2(hrvSnapshot: ble.recoveryHRVSnapshot,
                                              fallbackRMSSD: validatedHRV ?? store.latestLocalRMSSD,
                                              restingNow: ble.restingHR ?? store.sessions.first?.restingStable,
                                              baseline: store.baseline,
                                              hrvReferenceValidated: validatedHRV != nil,
                                              sleepEfficiency: latestSleep?.sleepEfficiency,
                                              sleepDurationHours: latestSleep?.durationHours,
                                              respiratoryRate: latestSleep?.respiratoryRate,
                                              respiratoryBaseline: store.sleepHistorySnapshot.respiratoryBaselineStats)
        let napAdjustedRecovery = store.sleepHistorySnapshot.napAdjustedRecovery(morningRecovery: baseRecovery.percent,
                                                                                 for: latestSleep)
        let recovery = napAdjustedRecovery.percent == baseRecovery.percent
            ? baseRecovery
            : Metrics.RecoveryEstimate(percent: napAdjustedRecovery.percent,
                                       confidence: baseRecovery.confidence,
                                       usesHRV: baseRecovery.usesHRV,
                                       detail: "\(baseRecovery.detail) · nap_lift",
                                       contributors: baseRecovery.contributors)
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
                            recoveryIsProvisional: recoveryIsProvisional,
                            recoveryLiftedAfterNap: napAdjustedRecovery.lifted,
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

    #if DEBUG
    static func debugFixtureProvisionalRecoveryHeroSnapshot(arguments: [String]) -> HeroSnapshot? {
        guard let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture") else { return nil }
        let valueIndex = arguments.index(after: fixtureIndex)
        guard arguments.indices.contains(valueIndex),
              arguments[valueIndex] == "pending-sleep-provisional-recovery" else {
            return nil
        }

        let now = Date()
        var baseline = PersonalBaseline()
        for index in 0..<PersonalBaseline.trustedMinimumSamples {
            let observedAt = now.addingTimeInterval(-Double(index + 1) * 86_400)
            baseline.learn(fromResting: 60 + (index % 3),
                           hrv: 64 + (index % 5),
                           at: observedAt,
                           overnight: true)
        }

        let end = Calendar.current.date(bySettingHour: 7, minute: 24, second: 0, of: now) ?? now
        let start = end.addingTimeInterval(-8 * 60 * 60)
        let night = SleepHistorySnapshot.Night(id: "debug-ui-fixture-provisional-recovery-night",
                                               day: Calendar.current.startOfDay(for: end),
                                               start: start,
                                               end: end,
                                               duration: end.timeIntervalSince(start),
                                               restingHR: 59,
                                               hrv: 70,
                                               respiratoryRate: 14.8,
                                               sleepEfficiency: 0.92,
                                               confidence: "debug_fixture_pending_sleep",
                                               source: "sleep_window",
                                               confirmed: false,
                                               stageSegments: [])
        let recovery = Metrics.recoveryV2(hrvSnapshot: nil,
                                          fallbackRMSSD: night.hrv,
                                          restingNow: night.restingHR,
                                          baseline: baseline,
                                          hrvReferenceValidated: false,
                                          sleepEfficiency: night.sleepEfficiency,
                                          sleepDurationHours: night.durationHours,
                                          respiratoryRate: night.respiratoryRate,
                                          respiratoryBaseline: nil)
        let strain = 4.2
        let guidance = Coach.guide(recovery: recovery, strain: strain, load: .learning)
        return HeroSnapshot(recoveryEstimate: recovery,
                            recoveryIsProvisional: !night.confirmed,
                            recoveryLiftedAfterNap: false,
                            strain: strain,
                            strainConfidence: "local",
                            guidance: guidance,
                            hrvValue: night.hrvText,
                            hrvDetail: "personal baseline",
                            hrvNarrative: "Debug fixture: pending sleep uses the normal recovery model before confirmation.",
                            stressValue: "0/3",
                            stressDetail: "personal baseline",
                            stressNarrative: "Debug fixture stress is neutral while provisional recovery is shown.",
                            rrPackageText: "Personal",
                            nextAction: "Confirming sleep will reconcile this recovery without a modal.",
                            headline: "Provisional recovery is ready.",
                            sessionsCount: PersonalBaseline.trustedMinimumSamples,
                            baselineSamples: PersonalBaseline.trustedMinimumSamples,
                            backupValue: "Ready",
                            backupDetail: "debug fixture",
                            restingHeartRate: night.restingHR ?? 0,
                            restingHeartRateText: night.restingHRText,
                            strainNarrative: "Debug fixture strain is fixed so the recovery ring proof is stable.",
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
    #endif

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
                               detail: "\(baseline.freshHRVSampleCount())/3 fresh baseline",
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
        let hasTrustedBaseline = stats.count >= PersonalBaseline.trustedMinimumSamples
        let badge = hasTrustedBaseline ? "personal baseline" : "unverified"
        let comparisonLabel = hasTrustedBaseline ? "your baseline" : "an early unverified HRV average"
        return StressState(value: "\(index)/3",
                           detail: badge,
                           narrative: String(format: "Live lnRMSSD is %.1f SD from %@.", z, comparisonLabel))
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
            narrative = "Atria keeps beat-to-beat recording light while the connection settles."
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
                                                                       detail: "learning: reconnecting",
                                                                       contributors: []),
                            recoveryIsProvisional: false,
                            recoveryLiftedAfterNap: false,
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
                              baselineSamples: store.baseline.freshHRVSampleCount(),
                              confirmedWorkouts: store.confirmedWorkouts.count,
                              confirmedSleeps: store.confirmedSleeps.count)
    }

    private static func makeDeferredDetails(ble: AtriaBLEManager, store: SessionStore) -> DeferredDetails {
        let diagnostics = store.homeDashboardDiagnostics()
        let validatedHRV = store.latestReferenceValidatedHRV
        let latestSleep = store.sleepHistorySnapshot.latest
        let recovery = Metrics.recoveryV2(hrvSnapshot: ble.recoveryHRVSnapshot,
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

        let referenceText = baselineMaturityText(sampleCount: store.baseline.freshHRVSampleCount())

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
    let showHelp: Bool
    let onShowHelp: () -> Void
    let onShowSettings: () -> Void
    let onShowStrap: () -> Void
    let onTapStatusWhenNotConnected: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            AtriaTopStatusChip(statusStore: statusStore,
                               coreLiveStore: coreLiveStore,
                               pulseLiveStore: pulseLiveStore,
                               onTapWhenNotConnected: onTapStatusWhenNotConnected)

            Spacer(minLength: 8)

            Button(action: onShowStrap) {
                AtriaToolbarIcon(symbol: "applewatch.radiowaves.left.and.right")
            }
            .buttonStyle(AtriaHeaderActionButtonStyle())
            .accessibilityLabel("Strap")

            Button(action: showHelp ? onShowHelp : onShowSettings) {
                AtriaToolbarIcon(symbol: showHelp ? "questionmark.circle" : "gearshape")
            }
            .buttonStyle(AtriaHeaderActionButtonStyle())
            .accessibilityLabel(showHelp ? "Connection help" : "Settings")
        }
        .frame(maxWidth: .infinity,
               minHeight: AtriaHeaderControlMetrics.height,
               maxHeight: AtriaHeaderControlMetrics.height,
               alignment: .center)
        // No .clipped() here: the status chip already draws its own bounded
        // capsule background, so nothing overflows that needs clipping — and
        // clipping this HStack at an exact 44pt height cropped the header
        // buttons' Liquid Glass press/glow effect (AtriaGlassIconButtonStyle),
        // which paints slightly outside its own frame when pressed.
    }
}

private enum AtriaHeaderControlMetrics {
    static let height: CGFloat = 44
    static let statusMinWidth: CGFloat = 96
    static let iconSpacing: CGFloat = 8
}

/// The top-left connection chip. A dedicated subview so it OBSERVES both stores,
/// but keeps short known-reconnect gaps calm before escalating to fit guidance.
private struct AtriaTopStatusChip: View {
    @ObservedObject var statusStore: AtriaHomeModel.StatusStore
    @ObservedObject var coreLiveStore: AtriaHomeModel.CoreLiveStore
    @ObservedObject var pulseLiveStore: AtriaHomeModel.PulseLiveStore
    let onTapWhenNotConnected: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var status: AtriaBLEManager.Status { statusStore.state.status }
    private var bluetoothPermissionDenied: Bool { statusStore.state.bluetoothPermissionDenied }
    private var hasPulseSignal: Bool {
        pulseLiveStore.state.hasPulseSignal || coreLiveStore.state.hasRecentHeartRateSample
    }
    private var isRecoveringLiveSignal: Bool {
        coreLiveStore.state.isInRecentLiveRecovery()
    }
    private var displayStatus: AtriaBLEManager.Status {
        if isRecoveringLiveSignal {
            switch status {
            case .poweredOff: return .poweredOff
            case .connected, .connecting, .scanning, .disconnected:
                return .connecting
            }
        }
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
        .padding(.horizontal, 12)
        .frame(minWidth: AtriaHeaderControlMetrics.statusMinWidth,
               maxWidth: 172,
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
        if displayStatus == .connected {
            return coreLiveStore.state.strapStreamConnectionLabel
        }
        switch displayStatus {
        case .connected:
            // "Live" must mean actually reading your pulse, not just a BLE link.
            return hasPulseSignal ? "Live" : "No signal"
        case .connecting: return isRecoveringLiveSignal ? "Reading…" : "Connecting"
        case .scanning: return "Searching"
        case .poweredOff: return bluetoothPermissionDenied ? "Permission" : "Bluetooth off"
        case .disconnected:
            return UserDefaults.standard.integer(forKey: AtriaBLEManager.LinkDefaults.successes) > 0
                ? "Reconnecting…"
                : "Disconnected"
        }
    }

    private var symbol: String {
        if displayStatus == .connected {
            return coreLiveStore.state.strapStreamConnectionSymbol
        }
        switch displayStatus {
        case .connected: return hasPulseSignal ? "bolt.heart.fill" : "heart.slash"
        case .connecting: return isRecoveringLiveSignal ? "waveform.path.ecg" : "dot.radiowaves.left.and.right"
        case .scanning: return "dot.radiowaves.left.and.right"
        case .poweredOff: return bluetoothPermissionDenied ? "hand.raised.fill" : "bolt.slash.fill"
        case .disconnected: return "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        if displayStatus == .connected {
            switch coreLiveStore.state.strapStreamState {
            case .live:
                return .green
            case .lowBatteryShutoff, .lowBatteryReducedDetail:
                return .yellow
            case .silentUnknown:
                return .orange
            case .warming, .unknown:
                return .cyan
            }
        }
        switch displayStatus {
        case .connected: return hasPulseSignal ? .green : .orange
        case .connecting: return isRecoveringLiveSignal ? .cyan : .yellow
        case .scanning: return .cyan
        case .poweredOff: return .red
        case .disconnected: return .blue
        }
    }

    private var foreground: Color {
        if displayStatus == .connected {
            return tint
        }
        switch displayStatus {
        case .connected: return hasPulseSignal ? .green : .orange
        case .connecting: return isRecoveringLiveSignal ? .cyan : .yellow
        case .scanning: return .cyan
        case .poweredOff: return .red
        case .disconnected: return .blue
        }
    }
}

private struct AtriaConnectionDiagnosis: Equatable {
    private static let lowBatteryThreshold = 25
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
            || title == "Strap battery too low"
            || title == "Strap battery low"
    }

    var sendsLocalNotification: Bool {
        title == "Bluetooth is off"
            || title == "Strap battery too low"
            || title == "Strap battery low"
            // Fit check is deliberately NOT in showsImmediately, so it only notifies
            // after persisting through the candidate delay — no blip-triggered alerts.
            || title == "Fit check needed"
    }

    static func derive(live: AtriaHomeModel.CoreLiveState,
                       pulse: AtriaHomeModel.PulseLiveState,
                       officialAppInstalled: Bool) -> AtriaConnectionDiagnosis? {
        let officialAppRiskActive = officialAppInstalled && live.officialAppCoexistenceRisk != .cleared
        let stalePairingSuspected = !officialAppInstalled && live.officialAppCoexistenceRisk == .suspected
        let pendingKnownReconnectAge = live.pendingKnownReconnectAge() ?? 0
        let pendingKnownReconnectActive = pendingKnownReconnectAge >= Self.pendingKnownReconnectActionAge
        let hasLivePulseSignal = pulse.hasPulseSignal || live.hasRecentHeartRateSample
        let isRecoveringLiveSignal = live.isInRecentLiveRecovery()
        let needsContactCoach = pulse.needsContactCoach
            && !live.hasRecentHeartRateSample
            && !isRecoveringLiveSignal

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
        case .connected where live.isLowBatteryLiveLimited:
            return AtriaConnectionDiagnosis(title: "Strap battery too low",
                                            action: "Charge your strap to resume live heart rate.",
                                            systemImage: "battery.25percent",
                                            tint: .yellow)
        case .connected where needsContactCoach:
            return AtriaConnectionDiagnosis(title: "Fit check needed",
                                            action: "Tighten the strap fit so Atria can read pulse.",
                                            systemImage: "heart.slash",
                                            tint: .orange)
        case .connected where live.needsRRQualityCoach && !hasLivePulseSignal:
            return AtriaConnectionDiagnosis(title: "Beat-to-beat waiting",
                                            action: "Atria needs pulse before it can build HRV and Recovery.",
                                            systemImage: "waveform.path.ecg",
                                            tint: .orange)
        case .connected where live.needsRRQualityCoach && hasLivePulseSignal:
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
            return AtriaConnectionDiagnosis(title: "WHOOP app watch",
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: diagnosis.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(diagnosis.tint)
                .frame(width: 30, height: 30)
                .background(AtriaIconTileBackground(cornerRadius: 9, tint: diagnosis.tint))

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
                    .font(.caption.weight(.bold))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .foregroundStyle(diagnosis.tint)
            .accessibilityLabel("Connection help")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(diagnosis.title). \(diagnosis.action)")
    }
}
