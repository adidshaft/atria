import Foundation
import CoreBluetooth
import UIKit

/// One-shot owner for an obsolete CoreBluetooth restoration namespace. It
/// never scans or connects; it only cancels peripherals restored from the
/// contaminated v1 stream-5 trial so they cannot compete with production v2.
private final class AtriaLegacyBLECentralCleaner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!

    init(restoreIdentifier: String) {
        super.init()
        central = CBCentralManager(delegate: self,
                                   queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for peripheral in peripherals {
            central.cancelPeripheralConnection(peripheral)
        }
        AtriaDebugLog("ATRIADBG ble_restore status=cleanup_obsolete_namespace peripherals=%d", peripherals.count)
    }
}

@MainActor
private final class PowerThermalGovernor {
    enum Mode: String {
        case nominal
        case fair
        case serious
        case critical
    }

    private(set) var mode: Mode = .nominal
    private var observers: [NSObjectProtocol] = []
    var onChange: ((Mode) -> Void)?

    init() {
        refresh(notify: false)
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh(notify: true) }
        })
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var cadenceMultiplier: Double {
        switch mode {
        case .nominal:
            return 1
        case .fair:
            return 1.5
        case .serious:
            return 2.5
        case .critical:
            return 4
        }
    }

    var shouldSuspendNonEssentialWork: Bool {
        mode == .critical
    }

    var shouldDeferNonEssentialAnalysis: Bool {
        mode == .serious || mode == .critical
    }

    private func refresh(notify: Bool) {
        let next = Self.mode(thermalState: ProcessInfo.processInfo.thermalState,
                             lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        guard next != mode else { return }
        mode = next
        if notify {
            onChange?(next)
        }
    }

    private static func mode(thermalState: ProcessInfo.ThermalState, lowPower: Bool) -> Mode {
        if thermalState == .critical {
            return .critical
        }
        if thermalState == .serious || lowPower {
            return .serious
        }
        if thermalState == .fair {
            return .fair
        }
        return .nominal
    }
}

/// Connects to the strap over BLE and publishes the reliable, relevant data:
/// live heart rate, battery level, connection state — plus a raw log of the
/// proprietary stream for later protocol decoding.
@MainActor
final class AtriaBLEManager: NSObject, ObservableObject {
    struct ResearchAggregates: Equatable, Sendable {
        let sensorProbeFrames: Int
        let spo2CandidateFrames: Int
        let skinTempCandidateFrames: Int
        let skinTempCandidateValueSum: Int
        let skinTempCandidateValueCount: Int
        let strapSteps: Int
        let strapRawSteps: Int
        let strapStepState: String?

        init(sensorProbeFrames: Int,
             spo2CandidateFrames: Int,
             skinTempCandidateFrames: Int,
             skinTempCandidateValueSum: Int,
             skinTempCandidateValueCount: Int,
             strapSteps: Int = 0,
             strapRawSteps: Int = 0,
             strapStepState: String? = nil) {
            self.sensorProbeFrames = sensorProbeFrames
            self.spo2CandidateFrames = spo2CandidateFrames
            self.skinTempCandidateFrames = skinTempCandidateFrames
            self.skinTempCandidateValueSum = skinTempCandidateValueSum
            self.skinTempCandidateValueCount = skinTempCandidateValueCount
            self.strapSteps = strapSteps
            self.strapRawSteps = strapRawSteps
            self.strapStepState = strapStepState
        }

        static let zero = ResearchAggregates(sensorProbeFrames: 0,
                                             spo2CandidateFrames: 0,
                                             skinTempCandidateFrames: 0,
                                             skinTempCandidateValueSum: 0,
                                             skinTempCandidateValueCount: 0)
    }

    nonisolated static func validatedResearchAggregates(
        from record: ActiveSessionJournalRecord
    ) -> ResearchAggregates? {
        let sensorFrames = record.sensorResearchProbeFrames ?? 0
        let spo2Frames = record.spo2ResearchCandidateFrames ?? 0
        let skinTempFrames = record.skinTempResearchCandidateFrames ?? 0
        guard sensorFrames >= 0, spo2Frames >= 0, skinTempFrames >= 0 else { return nil }

        let strap: (steps: Int, raw: Int, state: String?)
        switch (record.strapStepResearchCount, record.strapStepResearchRawCount) {
        case (nil, nil):
            strap = (0, 0, nil)
        case let (steps?, raw?) where steps >= 0 && raw >= 0:
            strap = (steps, raw, record.strapStepResearchState)
        default:
            return nil
        }

        let temperatureValues: (sum: Int, count: Int)
        switch (record.skinTempResearchCandidateValueSum,
                record.skinTempResearchCandidateValueCount) {
        case (nil, nil):
            temperatureValues = (0, 0)
        case let (sum?, count?) where sum >= 0 && count >= 0 && (count > 0 || sum == 0):
            temperatureValues = (sum, count)
        default:
            return nil
        }
        return ResearchAggregates(sensorProbeFrames: sensorFrames,
                                  spo2CandidateFrames: spo2Frames,
                                  skinTempCandidateFrames: skinTempFrames,
                                  skinTempCandidateValueSum: temperatureValues.sum,
                                  skinTempCandidateValueCount: temperatureValues.count,
                                  strapSteps: strap.steps,
                                  strapRawSteps: strap.raw,
                                  strapStepState: strap.state)
    }

    /// Fully prepared restore output produced away from the MainActor. The
    /// carrier is immutable; `@unchecked` is limited to legacy value types
    /// (`HRSample`, `RRInterval`, and `SavedSession`) that predate Sendable
    /// annotations but contain no shared mutable reference state here.
    struct ActiveSessionRestorePreparation: @unchecked Sendable {
        struct JournalIdentity: Equatable, Sendable {
            let id: UUID
            let updatedAt: Date
            let schema: Int
            let sampleCount: Int
            let rrSampleCount: Int
        }

        enum TerminalDisposition: Equatable, Sendable {
            case absent
            case schemaMismatch(identity: JournalIdentity)
            case stale(age: TimeInterval, identity: JournalIdentity)
            case insufficientSamples(identity: JournalIdentity)
        }

        struct HeartRateStats: Equatable, Sendable {
            let minimum: Int?
            let maximum: Int?
            let total: Int
            let count: Int
            let mean: Double
            let m2: Double
        }

        struct LivePayload: @unchecked Sendable {
            let record: ActiveSessionJournalRecord
            let now: Date
            let age: TimeInterval
            let session: [HRSample]
            let sessionPoints: [SavedSession.Point]
            let stats: HeartRateStats
            let lastHeartRates: [Int]
            let recentValid: [Int]
            let displayHeartRate: Int
            let rrArchive: [RRInterval]
            let rrPoints: [SavedSession.RRPoint]
            let recentRRBeatTimes: [Date]
            let researchAggregates: ResearchAggregates?
        }

        struct StaleSegmentPayload: @unchecked Sendable {
            let savedSession: SavedSession
            let now: Date
            let age: TimeInterval
            let researchAggregatesWereMalformed: Bool
        }

        enum Payload: @unchecked Sendable {
            case terminal(TerminalDisposition)
            case staleSegment(StaleSegmentPayload)
            case live(LivePayload)
        }

        let payload: Payload
    }

    private let debugForceUnknownStrapGeneration: Bool
    static let thermalJournalCheckpointInterval: TimeInterval = 60

    struct LiveHeartWindow: Equatable {
        var sparkline: [Int]
        var average: Int?
        var peak: Int?

        static let empty = LiveHeartWindow(sparkline: [], average: nil, peak: nil)
    }

    private struct ParsedRealtimePacket {
        let realtimeUnix: UInt32
        let hr: Int
        let rrValues: [Int]
        let truncated: Bool
        let frameTime: Date
    }

    private struct ParsedHeartRatePacket {
        let hr: Int
        let rrValues: [Int]
        let truncated: Bool
        let frameTime: Date
    }

    private struct PendingHeartRateUpdate {
        let packet: ParsedHeartRatePacket?
        let rawData: Data
    }

    private struct LongWearSupervisorConfig: Equatable {
        let label: String
        let rest: Int
        let maxHR: Int
        let checkpointInterval: TimeInterval
        let diagnosticInterval: TimeInterval
        let autoSaveInterval: TimeInterval
        let noDataTimeout: TimeInterval
        let noDataCheckInterval: TimeInterval
        let hrContinuityTimeout: TimeInterval
        let rrPresenceTimeout: TimeInterval
        let acceptedHRTimeout: TimeInterval

        var baseTickInterval: TimeInterval {
            max(3, min(noDataCheckInterval, diagnosticInterval, autoSaveInterval, hrContinuityTimeout / 2, 60))
        }
    }

    enum CollectionProfile: String, CaseIterable, Identifiable {
        case batterySaver
        case balanced
        case maxCoverage

        var id: String { rawValue }

        var label: String {
            switch self {
            case .batterySaver: return "Saver"
            case .balanced: return "Balanced"
            case .maxCoverage: return "Coverage"
            }
        }

        var detail: String {
            switch self {
            case .batterySaver: return "Cooler cadence, slower recovery"
            case .balanced: return "Default overnight profile"
            case .maxCoverage: return "Fastest stale-data response"
            }
        }

        fileprivate var cadenceMultiplier: Double {
            switch self {
            case .batterySaver: return 1.75
            case .balanced: return 1.0
            case .maxCoverage: return 0.75
            }
        }

        fileprivate var staleTimeoutMultiplier: Double {
            switch self {
            case .batterySaver: return 1.4
            case .balanced: return 1.0
            case .maxCoverage: return 0.85
            }
        }

        fileprivate static func load(defaults: UserDefaults = .standard) -> CollectionProfile {
            guard let raw = defaults.string(forKey: CollectionProfileDefaults.profile),
                  let profile = CollectionProfile(rawValue: raw) else {
                return .balanced
            }
            return profile
        }
    }

    enum AutomaticRecoveryIntent: Int, Equatable {
        case repairPipeline
        case rebuildConnection
    }

    enum RecoveryBackoffResetEvidence: Equatable {
        case connected
        case characteristicValue
    }

    nonisolated static func mergedRecoveryIntent(_ current: AutomaticRecoveryIntent,
                                                 _ requested: AutomaticRecoveryIntent) -> AutomaticRecoveryIntent {
        current.rawValue >= requested.rawValue ? current : requested
    }

    nonisolated static func shouldBeginStalledStreamRepair(lastRepairAt: Date?,
                                                           now: Date,
                                                           cooldown: TimeInterval = stalledStreamRepairCooldown) -> Bool {
        guard let lastRepairAt else { return true }
        return now.timeIntervalSince(lastRepairAt) >= cooldown
    }

    nonisolated static func shouldResetRecoveryBackoff(for evidence: RecoveryBackoffResetEvidence) -> Bool {
        evidence == .characteristicValue
    }

    nonisolated static func shouldEnableNotifications(isNotifying: Bool) -> Bool {
        !isNotifying
    }

    nonisolated static func hrvRefreshMinimumInterval(isRecording: Bool,
                                                      foregroundInteractive: Bool) -> TimeInterval {
        if isRecording { return captureHRVRefreshMinimumInterval }
        return foregroundInteractive
            ? foregroundLiveHRVRefreshMinimumInterval
            : backgroundLiveHRVRefreshMinimumInterval
    }

    nonisolated static func shouldRefreshHRVAnalysis(now: Date,
                                                     lastAnalysisAt: Date?,
                                                     isRecording: Bool,
                                                     foregroundInteractive: Bool) -> Bool {
        guard let lastAnalysisAt else { return true }
        let age = now.timeIntervalSince(lastAnalysisAt)
        // Wall-clock changes must not strand the persisted cadence marker in
        // the future. Fail open once, then the successful analysis persists a
        // new marker in the current clock domain. This mirrors the live-session
        // checkpoint gate and keeps both normal wear and explicit captures
        // recoverable after travel/manual clock correction.
        guard age >= 0 else { return true }
        return age >= hrvRefreshMinimumInterval(
            isRecording: isRecording,
            foregroundInteractive: foregroundInteractive
        )
    }

    nonisolated static func shouldAttemptHRVAnalysis(now: Date,
                                                     lastReadyAnalysisAt: Date?,
                                                     lastAttemptAt: Date?,
                                                     isRecording: Bool,
                                                     hasReadySnapshot: Bool,
                                                     cleanWindowSeconds: TimeInterval,
                                                     foregroundInteractive: Bool) -> Bool {
        if isRecording {
            return shouldRefreshHRVAnalysis(now: now,
                                            lastAnalysisAt: lastAttemptAt,
                                            isRecording: true,
                                            foregroundInteractive: foregroundInteractive)
        }
        if let lastReadyAnalysisAt,
           !shouldRefreshHRVAnalysis(now: now,
                                     lastAnalysisAt: lastReadyAnalysisAt,
                                     isRecording: false,
                                     foregroundInteractive: foregroundInteractive) {
            return false
        }
        if hasReadySnapshot {
            return shouldRefreshHRVAnalysis(now: now,
                                            lastAnalysisAt: lastAttemptAt,
                                            isRecording: false,
                                            foregroundInteractive: foregroundInteractive)
        }
        guard cleanWindowSeconds >= 300 else { return false }
        guard let lastAttemptAt else { return true }
        let attemptAge = now.timeIntervalSince(lastAttemptAt)
        // A failed automatic attempt is persisted across reconnects and
        // relaunches. Treat a
        // future marker as invalid instead of waiting for the wall clock to
        // catch up before trying another qualified window.
        return attemptAge < 0 || attemptAge >= normalWearHRVAnalysisAttemptInterval
    }

    nonisolated static func encodedReadyHRVSnapshot(_ snapshot: HRVSnapshot) -> Data? {
        guard snapshot.isReady else { return nil }
        return try? JSONEncoder().encode(snapshot)
    }

    nonisolated static func decodedReadyHRVSnapshot(_ data: Data?,
                                                    now: Date,
                                                    maxAge: TimeInterval = maxPersistedReadyHRVAge) -> HRVSnapshot? {
        guard let data,
              let snapshot = try? JSONDecoder().decode(HRVSnapshot.self, from: data),
              snapshot.isReady else {
            return nil
        }
        let age = now.timeIntervalSince(snapshot.analyzedAt)
        guard age >= -300, age <= maxAge else { return nil }
        return snapshot
    }

    enum BatteryChargeStatus: String, Equatable {
        case levelOnly
        case charging
        case notCharging
        case full

        var label: String {
            switch self {
            case .levelOnly: return "Charger unknown"
            case .charging: return "Charging"
            case .notCharging: return "Not charging"
            case .full: return "Full"
            }
        }
    }

    private enum ParsedProprietaryUpdate {
        case realtime(ParsedRealtimePacket)
        case commandResponse(AtriaFrame)
        case historyMetadata([UInt8])
        case historical([UInt8])
        case unknown(payload: [UInt8], fullFrame: [UInt8])
    }

    private enum PendingProprietaryMainActorWork {
        case r10Metadata(payloadLength: Int)
        case frame(Data, parsedUpdate: ParsedProprietaryUpdate?, storedFrame: AtriaFrame?)
    }

    private struct RRWindowSummary {
        let frames: Int
        let rrFrames: Int
        let fraction: Double
        let span: TimeInterval
        let frameMaxGap: TimeInterval
        let sourceLabel: String
        let firstTimestamp: Date?
    }

    private struct RRBatchAppendPayload {
        let intervals: [RRInterval]
        let beatTimes: [Date]
        let rrPoints: [SavedSession.RRPoint]
    }

    private struct RecentBreathworkRRSampleCache {
        let archiveRevision: UInt64
        let maxAge: TimeInterval
        let nowBucket: Int
        let samples: [AtriaBreathworkSession.RRSample]
    }

    private struct LongWearSessionAnalysis {
        let snapshot: SavedSession?
        let readiness: WorkoutReadiness?
    }

    private struct SampleDiagnosticsSnapshot {
        var rawNotifications: Int
        var acceptedSamples: Int
        var zeroSamples: Int
        var heldArtifacts: Int
        var droppedArtifacts: Int
        var rawGaps: Int
        var acceptedGaps: Int
        var maxRawGap: TimeInterval
        var maxAcceptedGap: TimeInterval
        var lastStatus: String
        var lastReason: String

        static let empty = SampleDiagnosticsSnapshot(rawNotifications: 0,
                                                     acceptedSamples: 0,
                                                     zeroSamples: 0,
                                                     heldArtifacts: 0,
                                                     droppedArtifacts: 0,
                                                     rawGaps: 0,
                                                     acceptedGaps: 0,
                                                     maxRawGap: 0,
                                                     maxAcceptedGap: 0,
                                                     lastStatus: "none",
                                                     lastReason: "none")

        static func load() -> SampleDiagnosticsSnapshot {
            let defaults = UserDefaults.standard
            return SampleDiagnosticsSnapshot(rawNotifications: defaults.integer(forKey: SampleDefaults.rawNotifications),
                                             acceptedSamples: defaults.integer(forKey: SampleDefaults.acceptedSamples),
                                             zeroSamples: defaults.integer(forKey: SampleDefaults.zeroSamples),
                                             heldArtifacts: defaults.integer(forKey: SampleDefaults.heldArtifacts),
                                             droppedArtifacts: defaults.integer(forKey: SampleDefaults.droppedArtifacts),
                                             rawGaps: defaults.integer(forKey: SampleDefaults.rawGaps),
                                             acceptedGaps: defaults.integer(forKey: SampleDefaults.acceptedGaps),
                                             maxRawGap: defaults.double(forKey: SampleDefaults.maxRawGap),
                                             maxAcceptedGap: defaults.double(forKey: SampleDefaults.maxAcceptedGap),
                                             lastStatus: defaults.string(forKey: SampleDefaults.lastStatus) ?? "none",
                                             lastReason: defaults.string(forKey: SampleDefaults.lastReason) ?? "none")
        }
    }

    private struct HistoricalArchiveComputation {
        enum Payload {
            case record(HistoricalArchive.Record)
            case undecodable(payload: [UInt8], reason: String)
        }

        let logMessage: String
        let payload: Payload
    }

    private struct HistoricalArchivePersistenceResult {
        let succeeded: Bool
        let archivedUndecodable: Bool
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let reason: String?
        let persistedPath: String
        let errorDescription: String?
        let effectiveUnix: UInt32?
    }

    private func assignIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AtriaBLEManager, Value>,
                                                   _ newValue: Value) {
        if self[keyPath: keyPath] != newValue {
            self[keyPath: keyPath] = newValue
        }
    }

    // MARK: GATT identifiers (discovered from the device)
    enum UUIDs {
        // Standard services
        static let heartRateService   = CBUUID(string: "180D")
        static let heartRateMeasure   = CBUUID(string: "2A37")
        static let batteryService     = CBUUID(string: "180F")
        static let batteryLevel       = CBUUID(string: "2A19")
        static let batteryLevelStatus = CBUUID(string: "2A1B")
        static let deviceInfoService  = CBUUID(string: "180A")
        static let manufacturerName   = CBUUID(string: "2A29")
        static let modelNumber        = CBUUID(string: "2A24")
        static let firmwareRevision   = CBUUID(string: "2A26")
        static let hardwareRevision   = CBUUID(string: "2A27")

        // strap proprietary service + characteristics
        static let strapService = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
        static let strapTX      = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // write (commands)
        static let strapRX      = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (responses)
        static let strapStream4 = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)
        static let strapStream5 = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)
        static let strapStream7 = CBUUID(string: "61080007-8d6d-82b8-614a-1c8cb0f8dcc6") // notify (data)

        static let allNotify = [strapRX, strapStream4, strapStream5, strapStream7]
        static let scanServices = [strapService, heartRateService]
        static let discoveryServices = [heartRateService, batteryService, deviceInfoService, strapService]
    }

    // MARK: Published state for the UI
    enum Status: String { case poweredOff = "Bluetooth off", scanning = "Scanning…",
        connecting = "Connecting…", connected = "Connected", disconnected = "Disconnected" }

    enum OfficialAppCoexistenceRisk: String {
        case advisory
        case suspected
        case cleared

        fileprivate static func load(defaults: UserDefaults = .standard) -> OfficialAppCoexistenceRisk {
            guard let raw = defaults.string(forKey: LinkDefaults.officialAppCoexistenceRisk),
                  let value = OfficialAppCoexistenceRisk(rawValue: raw) else {
                return .advisory
            }
            return value
        }

        var label: String {
            switch self {
            case .advisory:
                return "Strap check"
            case .suspected:
                return "Another app may interfere"
            case .cleared:
                return "Atria owns strap"
            }
        }
    }

    enum AtriaStrapModel: String {
        case unknown
        case strap3
        case strap4
        case strap4Class
        case strap5
        case strapMG

        var supportsSpO2: Bool {
            switch self {
            case .strap4, .strap4Class, .strap5, .strapMG: return true
            case .unknown, .strap3: return false
            }
        }

        var supportsSkinTemp: Bool {
            switch self {
            case .strap4, .strap4Class, .strap5, .strapMG: return true
            case .unknown, .strap3: return false
            }
        }

        var supportsGenerationSpecificDecode: Bool {
            switch self {
            case .strap4, .strap5, .strapMG: return true
            case .unknown, .strap3, .strap4Class: return false
            }
        }

        var supportsECG: Bool { self == .strapMG }
        var supportsBloodPressure: Bool { self == .strapMG }
    }

    struct HistoryDrainGate: Equatable {
        var generation: UInt64 = 0
        var pendingPersistence = 0
        var batchFailed = false
        var endReceived = false
        var terminalReceived = false
        var durableFlushCompleted = false
        var ackWriteInFlight = false
        var ackWriteCompleted = false

        mutating func begin(generation: UInt64) {
            self = HistoryDrainGate(generation: generation)
        }

        mutating func enqueueFrame(generation: UInt64) -> Bool {
            guard generation == self.generation else { return false }
            pendingPersistence += 1
            durableFlushCompleted = false
            return true
        }

        mutating func finishPersistence(generation: UInt64, succeeded: Bool) -> Bool {
            guard generation == self.generation, pendingPersistence > 0 else { return false }
            pendingPersistence -= 1
            batchFailed = batchFailed || !succeeded
            return true
        }

        var mayFlush: Bool {
            endReceived && pendingPersistence == 0 && !batchFailed
                && !durableFlushCompleted && !ackWriteInFlight && !ackWriteCompleted
        }

        var maySendACK: Bool {
            endReceived && pendingPersistence == 0 && !batchFailed
                && durableFlushCompleted && !ackWriteInFlight && !ackWriteCompleted
        }

        var mayFinishTerminal: Bool {
            terminalReceived && pendingPersistence == 0
                && (!endReceived || ackWriteCompleted) && !ackWriteInFlight
        }
    }

    nonisolated static func supportsVerifiedHistoricalRecovery(model: AtriaStrapModel,
                                                                previouslyVerified: Bool) -> Bool {
        previouslyVerified || model == .strap4 || model == .strap4Class
    }

    /// Raw WHOOP 4-class history transport and metric recovery are deliberately
    /// separate capabilities. A successful offload proves only that raw frames
    /// can be archived. It must not be advertised or scheduled as HR/step gap
    /// repair until a fixed historical layout has passed reference validation.
    nonisolated static func supportsVerifiedHistoricalMetricRecovery(
        model: AtriaStrapModel,
        previouslyVerified: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout
    ) -> Bool {
        supportsVerifiedHistoricalRecovery(model: model,
                                           previouslyVerified: previouslyVerified)
            && hasValidatedMetricLayout
    }

    nonisolated static func historicalSyncCompletionStatus(
        newRows: Int,
        requestedWindowMetricProgress: Bool,
        ledgerCoverageResolved: Bool,
        hasValidatedMetricLayout: Bool = HistoricalArchive.hasValidatedMetricLayout
    ) -> String {
        guard newRows > 0 else { return "no_rows" }
        if ledgerCoverageResolved { return "gap_recovered" }
        if requestedWindowMetricProgress { return "metric_progress" }
        return hasValidatedMetricLayout
            ? "archived_gap_unresolved"
            : "raw_archived_metric_unverified"
    }

    /// The displayed connection status. NEVER written ad-hoc — it is recomputed as a
    /// pure function of CoreBluetooth ground truth via `recomputeConnectionStatus`.
    @Published private(set) var status: Status = .disconnected
    @Published private(set) var bluetoothPermissionDenied = false
    /// True while an active scan is in progress with no peripheral yet (first-time
    /// setup). Feeds the derived status so it shows "Searching" only when truly scanning.
    private var isActivelyScanning = false
    @Published private(set) var officialAppCoexistenceRisk: OfficialAppCoexistenceRisk = OfficialAppCoexistenceRisk.load()
    @Published private(set) var rangeLossBackfillPending = UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)
    @Published var deviceName: String = "—"
    @Published var heartRate: Int = 0
    @Published var batteryLevel: Int = -1
    /// Best-effort: the strap exposes Battery Level (2A19), not a direct charge
    /// flag. Keep unknown separate from not-charging so the UI never silently hides
    /// that limitation.
    @Published var batteryIsCharging: Bool = false
    @Published var batteryChargeStatus: BatteryChargeStatus = .levelOnly
    @Published private(set) var batteryRecentlyDropping: Bool = false
    @Published private(set) var batteryReadingIsRecentBaseline = false
    @Published private(set) var batteryProjectionRevision: UInt64 = 0
    /// The recent-baseline display gate becomes true only after the first
    /// accepted HR packet from this process' connection epoch. That transition
    /// does not otherwise mutate a battery property, so publish it exactly once
    /// to keep the age-labelled in-app status from remaining on "Battery
    /// pending" until the next integer 2A19 change. Widgets fail closed because
    /// they cannot display the baseline's original verification age.
    private var recentReconnectBatteryBaselineProjectionPublished = false
    /// Sensor-lifecycle owner for explicit workout zone coaching. This remains
    /// alive while the workout UI is minimized or the app is backgrounded.
    private var workoutZoneHapticLifecycle = AtriaWorkoutZoneHapticLifecycle()
    /// Scoped to the current 2A19 notification subscription, not the whole BLE
    /// link. A failed subscription can be replaced without poisoning the next
    /// change-driven notification lease for the rest of the connection.
    private var batteryNotificationEpochHadRejectedCallback = false
    /// True only when CoreBluetooth restores the already-connected saved strap
    /// without issuing didConnect in this process. That exact path may retain a
    /// bounded persisted CCCD confirmation from the same link epoch.
    private var batteryConnectionRestoredSamePeripheral = false
    /// CoreBluetooth state restoration can resume an already-connected
    /// peripheral without calling didConnect in this process. This process-local
    /// epoch still lets a post-launch accepted HR packet prove the restored link.
    private var batteryBaselineValidationStartedAt = Date()
    @Published private(set) var strapStreamState: StrapStreamState = .unknown
    private(set) var manufacturer: String = "—"
    // Device Information (0x180A) identity, read on connect. Raw strings as the
    // strap reports them; `strapModelLabel` maps known values to a friendly name
    // and falls back to the raw model string (never a guess).
    @Published private(set) var modelNumber: String = ""
    @Published private(set) var firmwareRevision: String = ""
    @Published private(set) var hardwareRevision: String = ""
    @Published private(set) var strapModel: AtriaStrapModel = .unknown

    /// Best-effort friendly model name. These straps do not populate the standard
    /// Device Information model string, so this usually falls back; the generation
    /// decode lives in the proprietary metadata frame (see docs/18).
    var strapModelLabel: String {
        switch strapModel {
        case .strapMG: return "Strap MG"
        case .strap5: return "Strap 5.0"
        case .strap4: return "Strap 4.0"
        case .strap4Class: return "Strap"
        case .strap3: return "Strap 3.0"
        case .unknown: break
        }
        let haystack = "\(modelNumber) \(hardwareRevision)".lowercased()
        if haystack.contains("mg") { return "WHOOP MG" }
        if haystack.contains("5") && haystack.contains("4") == false { return "Strap 5.0" }
        if haystack.contains("4") { return "Strap 4.0" }
        if haystack.contains("3") { return "Strap 3.0" }
        let model = modelNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "Strap" : model
    }

    var strapGenerationDetail: String {
        switch strapModel {
        case .strapMG:
            return "Generation: WHOOP MG, explicit metadata"
        case .strap5:
            return "Generation: WHOOP 5.0, explicit metadata"
        case .strap4:
            return "Generation: WHOOP 4.0, explicit metadata"
        case .strap4Class:
            return "Generation: unverified; 4.0-class protocol"
        case .strap3:
            return "Generation: WHOOP 3.0, explicit metadata"
        case .unknown:
            return "Generation: unknown; heart rate only until layout is checked"
        }
    }

    var supportsSpO2Probe: Bool { strapModel.supportsSpO2 }
    var supportsSkinTempProbe: Bool { strapModel.supportsSkinTemp }
    var supportsGenerationSpecificDecode: Bool { strapModel.supportsGenerationSpecificDecode }
    var supportsECG: Bool { strapModel.supportsECG }
    var supportsBloodPressure: Bool { strapModel.supportsBloodPressure }

    // User-set strap name, persisted locally. Takes precedence over the BLE
    // peripheral name (which the strap seeds from the owner's account, e.g.
    // "Adidshaft's WHOOP"). Empty == use the peripheral name.
    @Published var customDeviceName: String =
        UserDefaults.standard.string(forKey: "atriaCustomDeviceName") ?? ""

    /// The name to show everywhere: custom name if set, else the strap's own BLE
    /// name, else a generic fallback. Never collapses a real name to "Strap".
    var resolvedDeviceName: String {
        let custom = customDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let ble = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ble.isEmpty && ble != "—" { return ble }
        return "Strap"
    }

    func setCustomDeviceName(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard trimmed != customDeviceName else { return }
        customDeviceName = trimmed
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: "atriaCustomDeviceName")
        } else {
            UserDefaults.standard.set(trimmed, forKey: "atriaCustomDeviceName")
        }
    }
    private(set) var frames: [AtriaFrame] = []        // decoded proprietary frames (append-only ring buffer)
    private(set) var lastHeartRates: [Int] = []       // small rolling window for a sparkline
    @Published private(set) var liveHeartWindow = LiveHeartWindow.empty
    private var lastHeartRatesTotal = 0
    private var lastHeartRatesPositiveCount = 0
    private var lastHeartRatesPeak: Int?
    private var lastLiveHeartDisplayPublishAt: Date?
    // Keep the live dashboard responsive without redrawing on every accepted HR
    // sample. A slightly slower cadence smooths the UI on-device and reduces
    // unnecessary main-thread work while the BLE stream is active.
    private static let liveHeartDisplayMinimumInterval: TimeInterval = 0.70
    private static let reducedForegroundLiveHeartDisplayMinimumInterval: TimeInterval = 1.35
    private static let backgroundLiveHeartDisplayMinimumInterval: TimeInterval = 6.0

    // HR session: every BPM sample since connection, for stats + chart.
    private(set) var session: [HRSample] = []
    @Published private(set) var sessionSampleCount = 0
    private var lastSessionSampleCountPublishedAt: Date?
    static let sessionSampleCountPublishMinimumInterval: TimeInterval = 5
    static let sessionSampleCountPublishMinimumDelta = 10
    static let liveSessionSampleCountSemanticThresholds: [Int] = [1, 60, 720, 900]
    private var sessionOriginTime: Date?
    private var sessionPointsCache: [SavedSession.Point] = []
    private var rrPointsCache: [SavedSession.RRPoint] = []
    private struct SessionActiveCaloriesCache {
        var sessionID: UUID
        var origin: Date
        var sampleCount: Int
        var lastTimestamp: Date
        var restingHeartRate: Int
        var profile: AthleteProfile
        var calories: Double?
    }
    private var sessionActiveCaloriesCache: SessionActiveCaloriesCache?
    @Published var hasContact = false                  // sensor reporting a live pulse?
    private var recentValid: [Int] = []                // window for smoothing + artifact rejection
    private var pendingHRJump: (rate: Int, at: Date)?
    private var lastAcceptedHRAt: Date?
    var lastAcceptedHeartRateAt: Date? { lastAcceptedHRAt }
    private var sessionAwaitingUnexpectedReconnect = false
    private nonisolated static let workoutHRArtifactJumpBPM = 50
    private nonisolated static let workoutHRArtifactConfirmBPM = 15
    private nonisolated static let workoutHRArtifactConfirmSeconds: TimeInterval = 10
    private nonisolated static let workoutHRArtifactStaleMedianSeconds: TimeInterval = 5

    nonisolated static func heartRateHardUpperBound(profileMaxHR: Int) -> Int {
        let sanitizedMax = min(max(profileMaxHR, 120), 220)
        return min(240, max(220, Int(ceil(Double(sanitizedMax) * 1.10))))
    }

    nonisolated static func heartRateIsPhysiologicallyPlausible(_ rate: Int,
                                                               profileMaxHR: Int) -> Bool {
        rate == 0 || (20...heartRateHardUpperBound(profileMaxHR: profileMaxHR)).contains(rate)
    }

    // Realtime command channel → HRV (RR intervals from REALTIME_DATA packets).
    private(set) var realtimeOn = false
    private(set) var hrv: Int = 0                      // RMSSD in ms
    private(set) var rrSamples = 0
    @Published var hrvSnapshot: HRVSnapshot?
    private var latestReadyHRVSnapshot: HRVSnapshot?

    /// The newest ready snapshot measured during today's morning window. Eligibility
    /// follows the measurement timestamp, not the hour when this property is read,
    /// so opening Atria later cannot discard or accidentally promote an HRV value.
    var recoveryHRVSnapshot: HRVSnapshot? {
        let candidates = [latestReadyHRVSnapshot, hrvSnapshot]
            .compactMap { $0 }
            .filter(\.isReady)
        if morningHRVForce {
            return candidates.max { $0.measurementEnd < $1.measurementEnd }
        }
        let now = Date()
        return candidates
            .filter { $0.isRecoveryEligible(on: now) }
            .max { $0.measurementEnd < $1.measurementEnd }
    }

    private(set) var tachogram: [RRSample] = []
    @Published var hrvQuality = "waiting for beat-to-beat samples"
    @Published var rrContinuityState = "learning"
    private(set) var rrContinuityDetail = "RR continuity waiting"
    private(set) var rrContinuityFraction = 0.0
    private(set) var rrContinuityMaxGapSeconds = 0.0
    private(set) var rrContinuityFrames = 0
    private(set) var rrContinuityRRFrames = 0
    @Published private(set) var lastScanRequestedAt: Date?
    @Published private(set) var lastScanMatchAt: Date?
    @Published private(set) var pendingKnownReconnectStartedAt: Date?
    @Published private(set) var pendingKnownReconnectReason = ""
    /// True only while CBCentralManager.state == .poweredOn. Lets the UI tell
    /// "radio not up yet" (.unknown/.resetting, abstracted into .connecting by
    /// recomputeConnectionStatus when a strap is saved) apart from a real
    /// pending-connect attempt, without inventing a new connection Status case.
    @Published private(set) var isBluetoothReady = false
    private var lastScanRequestMode = "filtered"
    private static let scanRequestDedupWindow: TimeInterval = 1.5
    private(set) var sleepMotionHintCount = 0
    private(set) var sleepMotionHintKinds = "none"
    private(set) var sleepMotionSource = "unavailable"
    private var sleepMotionHintKindCounts: [String: Int] = [:]
    private var sleepMotionShortValues: [Double] = []
    private let motionShortAuditThreshold = 1.0

    // Diagnostics (shown on-screen to pinpoint the realtime issue)
    private(set) var dbgTxReady = false
    private(set) var dbgCmdSends = 0
    private(set) var dbgPropFrames = 0
    private(set) var dbgRealtimeFrames = 0
    private(set) var dbgSubsReq = 0
    private(set) var dbgSubsActive = 0
    private(set) var dbgLast = "—"
    private(set) var dbgWrite = "—"
    private(set) var dbgWriteMode = "—"
    private(set) var dbgMTU = 0
    private var dbgTypeSet = Set<String>()
    private var txCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var cmdSeq: UInt8 = 0
    private var rrBuffer: [RRInterval] = []  // recent RR intervals for RMSSD
    private var rrBufferHead = 0
    private var rrArchive: [RRInterval] = [] // real RR intervals persisted with session snapshots
    private var rrArchiveRevision: UInt64 = 0
    private var recentBreathworkRRSampleCache: RecentBreathworkRRSampleCache?
    private var recentRRBeatTimes: [Date] = []
    nonisolated private static let recentRRBeatWindowSeconds: TimeInterval = 10 * 60
    private static let recentBreathworkRRCacheBucketSeconds: TimeInterval = 1
    private var lastRecentRRBeatPruneAt: Date?
    private static let recentRRBeatPruneMinimumInterval: TimeInterval = 2
    private var lastRealtimeZeroRRQualityUpdateAt: Date?
    private var lastRealtimeZeroRRAutoCaptureUpdateAt: Date?
    private static let zeroRRTrackingMinimumInterval: TimeInterval = 0.5
    private var hrvLiveRefreshTask: Task<Void, Never>?
    private var archiveSeedTask: Task<Void, Never>?
    private var pendingLiveHRVRefreshRequest: (now: Date, logKind: String, shouldLogConsole: Bool)?
    private var hrvLiveRefreshGeneration: UInt64 = 0
    private var contactStableSince: Date?
    private var hrvGateWasOpen = false
    private nonisolated static let foregroundLiveHRVRefreshMinimumInterval: TimeInterval = 4 * 60 * 60
    private nonisolated static let backgroundLiveHRVRefreshMinimumInterval: TimeInterval = 4 * 60 * 60
    private nonisolated static let captureHRVRefreshMinimumInterval: TimeInterval = 1.5
    private nonisolated static let normalWearHRVAnalysisAttemptInterval: TimeInterval = 4 * 60 * 60
    nonisolated static let maxPersistedReadyHRVAge: TimeInterval = 36 * 60 * 60
    private static let liveRRContinuityPublishMinimumInterval: TimeInterval = 1.25
    private static let backgroundRRContinuityPublishMinimumInterval: TimeInterval = 10
    private var standardHRFrames = 0
    private var decodedRealtimeRRValues = 0
    private var usedRealtimeRRValues = 0
    private var decodedStandardRRValues = 0
    private var lastStandardRRAt: Date?
    private var lastRRPresenceRefreshAt: Date?
    private var lastRealtimeUnix: UInt32?
    private nonisolated let heartRatePacketQueueLock = NSLock()
    private nonisolated(unsafe) var pendingHeartRateUpdates: [PendingHeartRateUpdate] = []
    private nonisolated(unsafe) var pendingHeartRateUpdateHead = 0
    private nonisolated(unsafe) var heartRatePacketDrainScheduled = false
    // Keep per-packet work off the callback queue, but avoid tiny main-actor
    // batches that spend more time handing off than applying data.
    nonisolated private static let heartRatePacketBatchSize = 12
    nonisolated private static let pendingHeartRateUpdateLimit = 4_096
    private nonisolated let realtimePacketQueueLock = NSLock()
    private nonisolated(unsafe) var pendingRealtimePackets: [ParsedRealtimePacket] = []
    private nonisolated(unsafe) var pendingRealtimePacketHead = 0
    private nonisolated(unsafe) var realtimePacketDrainScheduled = false
    nonisolated private static let realtimePacketBatchSize = 12
    nonisolated private static let pendingRealtimePacketLimit = 4_096
    private var liveSessionID = UUID()
    private var liveSessionEventTimeZoneIdentifier = TimeZone.current.identifier
    var currentLiveSessionID: UUID { liveSessionID }
    enum CheckpointDefaults {
        static let armed = "atria.checkpoint.armed"
        static let interval = "atria.checkpoint.interval"
        static let label = "atria.checkpoint.label"
        static let source = "atria.checkpoint.source"
        static let lastStatus = "atria.checkpoint.lastStatus"
        static let lastIndex = "atria.checkpoint.lastIndex"
        static let lastSamples = "atria.checkpoint.lastSamples"
        static let lastDuration = "atria.checkpoint.lastDuration"
    }
    enum LinkDefaults {
        static let attempts = "atria.link.attempts"
        static let disconnects = "atria.link.disconnects"
        static let successes = "atria.link.successes"
        static let failures = "atria.link.failures"
        static let lastStatus = "atria.link.lastStatus"
        static let lastReason = "atria.link.lastReason"
        static let lastError = "atria.link.lastError"
        static let lastAutoSaveStatus = "atria.link.lastAutoSaveStatus"
        static let lastAutoSaveSamples = "atria.link.lastAutoSaveSamples"
        static let lastAutoSaveDuration = "atria.link.lastAutoSaveDuration"
        static let officialAppCoexistenceRisk = "atria.link.officialAppCoexistenceRisk"
        static let officialAppCoexistenceReason = "atria.link.officialAppCoexistenceReason"
        /// The CoreBluetooth identifier of the strap the user paired with. Once set,
        /// Atria maintains a standing pending connection to it forever (reconnects
        /// across range loss + app relaunch) until the user explicitly forgets it.
        static let savedPeripheralUUID = "atria.link.savedPeripheralUUID"
    }

    static func officialAppCoexistenceRisk(defaults: UserDefaults = .standard) -> OfficialAppCoexistenceRisk {
        OfficialAppCoexistenceRisk.load(defaults: defaults)
    }
    enum SampleDefaults {
        static let rawNotifications = "atria.sample.rawNotifications"
        static let acceptedSamples = "atria.sample.acceptedSamples"
        static let zeroSamples = "atria.sample.zeroSamples"
        static let heldArtifacts = "atria.sample.heldArtifacts"
        static let droppedArtifacts = "atria.sample.droppedArtifacts"
        static let rawGaps = "atria.sample.rawGaps"
        static let acceptedGaps = "atria.sample.acceptedGaps"
        static let maxRawGap = "atria.sample.maxRawGap"
        static let maxAcceptedGap = "atria.sample.maxAcceptedGap"
        static let lastStatus = "atria.sample.lastStatus"
        static let lastReason = "atria.sample.lastReason"
        static let lastRawNotificationAt = "atria.sample.lastRawNotificationAt"
    }
    enum StrapStreamState: String {
        case unknown
        case live
        case warming
        case lowBatteryShutoff = "low_battery_shutoff"
        case lowBatteryReducedDetail = "low_battery_reduced_detail"
        case silentUnknown = "silent_unknown"
    }
    enum StrapStreamDefaults {
        static let state = "atria.strapStream.state"
        static let reason = "atria.strapStream.reason"
        static let packetAge = "atria.strapStream.packetAge"
        static let batteryLevel = "atria.strapStream.batteryLevel"
        static let notifying = "atria.strapStream.notifying"
        static let gattReadsOK = "atria.strapStream.gattReadsOK"
        static let updatedAt = "atria.strapStream.updatedAt"
        static let lowBatteryReconnectSuppressed = "atria.strapStream.lowBatteryReconnectSuppressed"
        static let lowBatteryReconnectSuppressedAt = "atria.strapStream.lowBatteryReconnectSuppressedAt"
        static let lowBatteryReconnectSuppressionReason = "atria.strapStream.lowBatteryReconnectSuppressionReason"
        static let lowBatteryReconnectSuppressionCount = "atria.strapStream.lowBatteryReconnectSuppressionCount"
        static let lowBatteryReconnectRearmedAt = "atria.strapStream.lowBatteryReconnectRearmedAt"
        static let accessibilityLabel = "atria.strapStream.accessibilityLabel"
    }
    // Straps keep broadcasting valid HR well below 15%, and forfeiting capture
    // that high loses hours of overnight sleep data. Only enter the shutoff /
    // reconnect-suppression path near true depletion so a strap still emitting
    // HR at 6-14% keeps getting reconnected. Reduced-detail UI messaging still
    // starts at lowBatteryWarningThreshold (25%).
    nonisolated private static let lowBatteryBroadcastShutoffThreshold = 5
    nonisolated private static let lowBatteryWarningThreshold = 25
    private static let staleHeartRatePacketThreshold: TimeInterval = 120
    enum HRContinuityDefaults {
        static let status = "atria.hrContinuity.status"
        static let action = "atria.hrContinuity.action"
        static let rawGap = "atria.hrContinuity.rawGap"
        static let acceptedGap = "atria.hrContinuity.acceptedGap"
        static let timeout = "atria.hrContinuity.timeout"
        static let samples = "atria.hrContinuity.samples"
        static let label = "atria.hrContinuity.label"
        static let notifying = "atria.hrContinuity.notifying"
        static let at = "atria.hrContinuity.at"
    }
    enum RRPresenceDefaults {
        static let status = "atria.rrPresence.status"
        static let action = "atria.rrPresence.action"
        static let rrGap = "atria.rrPresence.rrGap"
        static let acceptedGap = "atria.rrPresence.acceptedGap"
        static let timeout = "atria.rrPresence.timeout"
        static let samples = "atria.rrPresence.samples"
        static let rrValues = "atria.rrPresence.rrValues"
        static let consecutive = "atria.rrPresence.consecutive"
        static let label = "atria.rrPresence.label"
        static let at = "atria.rrPresence.at"
    }
    enum WatchdogRecoveryDefaults {
        static let noDataCount = "atria.watchdog.noDataCount"
        static let hrContinuityCount = "atria.watchdog.hrContinuityCount"
        static let acceptedHRCount = "atria.watchdog.acceptedHRCount"
        static let rrPresenceCount = "atria.watchdog.rrPresenceCount"
        static let lastStatus = "atria.watchdog.lastStatus"
        static let lastSource = "atria.watchdog.lastSource"
        static let lastAction = "atria.watchdog.lastAction"
        static let lastRawGap = "atria.watchdog.lastRawGap"
        static let lastAcceptedGap = "atria.watchdog.lastAcceptedGap"
        static let lastSamples = "atria.watchdog.lastSamples"
        static let lastCheckpoint = "atria.watchdog.lastCheckpoint"
        static let lastAt = "atria.watchdog.lastAt"
    }
    enum BatteryDefaults {
        static let level = "atria.battery.level"
        static let at = "atria.battery.at"
        static let source = "atria.battery.source"
        /// Last accepted non-sentinel 2A19 value. Boundary packets are known to
        /// replay during restoration, so this survives their quarantine and is
        /// the only safe baseline for judging a later 0/10/100 transition.
        static let credibleLevel = "atria.battery.credibleLevel"
        static let credibleAt = "atria.battery.credibleAt"
        static let chargeStatus = "atria.battery.chargeStatus"
        static let chargeAt = "atria.battery.chargeAt"
        static let previousLevel = "atria.battery.previousLevel"
        static let previousAt = "atria.battery.previousAt"
        static let dropAt = "atria.battery.dropAt"
        static let dropDelta = "atria.battery.dropDelta"
        static let requiresFreshConfirmation = "atria.battery.requiresFreshConfirmation"
        /// Renewed only while an error-free 2A19 value from this connection has
        /// already been accepted and its notification subscription remains
        /// active. BAS notifications are change-driven, so silence while the
        /// CCCD is active means the integer percentage has not changed.
        static let notificationLeaseAt = "atria.battery.notificationLeaseAt"
        static let notificationRequestedAt = "atria.battery.notificationRequestedAt"
        static let notificationConfirmedAt = "atria.battery.notificationConfirmedAt"
        static let notificationLastError = "atria.battery.notificationLastError"
        static let notificationLastCallbackAt = "atria.battery.notificationLastCallbackAt"
        static let proprietaryRefreshLastAttemptAt = "atria.battery.proprietaryRefresh.lastAttemptAt"
        static let proprietaryRefreshLastSuccessAt = "atria.battery.proprietaryRefresh.lastSuccessAt"
        static let proprietaryRefreshCircuitOpenUntil = "atria.battery.proprietaryRefresh.circuitOpenUntil"
        static let proprietaryRefreshPending = "atria.battery.proprietaryRefresh.pending"
        static let proprietaryRefreshLastFailure = "atria.battery.proprietaryRefresh.lastFailure"
        static let proprietaryRefreshRecoveryMigrated = "atria.battery.proprietaryRefresh.recoveryMigratedV2"
        static let proprietaryRefreshRecoveryPending = "atria.battery.proprietaryRefresh.recoveryPending"
    }
    /// Charge-pattern learning (docs/24 §14.2 deferred item): a rolling record of
    /// the local hour-of-day whenever the strap is newly observed to start
    /// charging, so LocalNotificationScheduler can nudge the user near their
    /// usual charge time once a low-battery reading lands outside a charge.
    enum ChargePatternDefaults {
        static let hours = "atria.chargePattern.hours"
        static let lastRecordedAt = "atria.chargePattern.lastRecordedAt"
    }
    private nonisolated static let chargePatternMaxEntries = 14
    private nonisolated static let chargePatternDedupeWindow: TimeInterval = 4 * 60 * 60
    private nonisolated static let activeBatteryChargeEvidenceMaxAge: TimeInterval = 10 * 60
    private nonisolated static let activeBatteryChargeDisplayMaxAge: TimeInterval = 2 * 60
    private nonisolated static let implausibleBatteryDropThreshold = 20
    private nonisolated static let implausibleBatteryDropMinimumConfirmationSpan: TimeInterval = 60
    private nonisolated static let freshBatteryConfirmationMinimumSpan: TimeInterval = 12
    /// WHOOP 2A19 has repeatedly emitted the sentinel-like values 0, 10, and
    /// 100 during connection restoration while the physical strap UI reported a
    /// stable mid-range charge. A full fifteen-minute stable series is cheaper
    /// than presenting a false empty/full warning; an ordinary mid-range value
    /// still confirms in twelve seconds.
    private nonisolated static let freshBoundaryBatteryConfirmationMinimumSpan: TimeInterval = 15 * 60
    nonisolated static let batteryRefreshInterval: TimeInterval = 2 * 60
    nonisolated static let batteryDisplayFreshnessLimit: TimeInterval = 10 * 60
    /// A 2A19 subscription is change-driven: after relaunch the strap may not
    /// emit another packet until the integer percentage changes. Retain the
    /// last verified mid-range value long enough to bridge an ordinary sleep or
    /// workout gap, but expose it only as an explicitly aged `Recent` baseline
    /// after this same saved strap supplies live HR. It never becomes charging
    /// evidence, and the restoration sentinels 0/10/100 remain ineligible.
    nonisolated static let reconnectBatteryBaselineMaximumAge: TimeInterval = 6 * 60 * 60

    /// A standard Battery Service notification is change-driven: once the same
    /// strap, the current HR link and the current 2A19 subscription are all
    /// proven, silence means the last validated percentage has not changed.
    /// Keep that explicitly age-labelled baseline available across an overnight
    /// gap instead of reverting to `Pending` after six hours. Do not extend this
    /// to a full strap charge cycle: a notification lease proves the current
    /// transport, but it cannot prove what happened while the app was not
    /// connected. Boundary sentinels remain ineligible regardless of age.
    nonisolated static let activeBatterySubscriptionBaselineMaximumAge: TimeInterval = 36 * 60 * 60
    /// A persisted CCCD confirmation is transport evidence, not a percentage
    /// sample. Keep its restoration lifetime tighter than the explicitly aged
    /// last-verified percentage shown by the UI.
    nonisolated static let batteryRestoredNotificationConfirmationMaximumAge: TimeInterval = 60 * 60
    nonisolated static let proprietaryBatteryRefreshCooldown: TimeInterval = 30 * 60
    nonisolated static let proprietaryBatteryRefreshFailureCircuit: TimeInterval = 24 * 60 * 60
    nonisolated static let proprietaryBatteryPostQualificationGrace: TimeInterval = 2 * 60
    nonisolated static let proprietaryBatteryResponseTimeout: TimeInterval = 8
    // A physical V5 run proved that the RX/0x1A transaction can silently stop
    // R10 even when HR stays connected. Keep the validated parser and guarded
    // implementation for diagnostics, but production must prefer honest
    // battery-unavailable state over sacrificing continuous motion/steps.
    nonisolated static let proprietaryBatteryRefreshEnabled = false
    private nonisolated static let implausibleBatteryDropCandidateMaxAge: TimeInterval = 5 * 60
    private nonisolated static let implausibleBatteryDropRequiredConfirmations = 3
    struct BatteryDropCandidate: Equatable {
        let level: Int
        let firstSeenAt: Date
        let lastSeenAt: Date
        let confirmations: Int
    }
    struct BatteryEventReading: Equatable {
        let level: Int
        let millivolts: Int
        let isCharging: Bool
    }
    enum BatteryLevelAcceptanceDecision: Equatable {
        case accept
        case quarantine(BatteryDropCandidate)
    }
    private struct WorkoutCaptureEvidence {
        let diagnosis: String
        let action: String
        let sampleFields: String
    }
    enum RadioDefaults {
        static let standardHROnly = "atria.radio.standardHROnly"
        static let standardHROnlyUserSelected = "atria.radio.standardHROnlyUserSelected"
        static let mode = "atria.radio.mode"
        static let customNotifySkipped = "atria.radio.customNotifySkipped"
        static let customNotifyEnabled = "atria.radio.customNotifyEnabled"
        static let txSkipped = "atria.radio.txSkipped"
        static let realtimeStartSkipped = "atria.radio.realtimeStartSkipped"
        static let lastReason = "atria.radio.lastReason"
        static let passiveR10Status = "atria.radio.passiveR10Status"
        static let passiveR10SubscribedAt = "atria.radio.passiveR10SubscribedAt"
        static let passiveR10FirstValidAt = "atria.radio.passiveR10FirstValidAt"
        static let passiveR10LastValidAt = "atria.radio.passiveR10LastValidAt"
        static let passiveR10ValidFrames = "atria.radio.passiveR10ValidFrames"
    }
    enum CaptureDefaults {
        static let configured = "atria.capture.defaultsConfigured"
        static let protectedLongWearMigrated = "atria.capture.protectedLongWearMigrated"
        /// The old Settings surface exposed an all-day capture toggle. That
        /// control was removed when continuous strap collection became Atria's
        /// core behavior, but existing installs could remain silently disabled
        /// forever. Migrate that orphaned state exactly once.
        static let alwaysOnLongWearMigrated = "atria.capture.alwaysOnLongWearMigratedV1"
        static let strapStepFullProtocolMigrated = "atria.capture.strapStepFullProtocolMigrated"
        /// V2 replaces the unstable broad proprietary profile with the
        /// physically verified minimal 2A37 + stream-5 R10 transport. Keep a
        /// separate key because every existing install already consumed the
        /// older full-protocol migration.
        static let stableR10TransportMigrated = "atria.capture.stableR10TransportMigratedV2"
    }
    enum LongWearDefaults {
        static let enabled = "atria.longWear.enabled"
        static let userSelected = "atria.longWear.userSelected"
        static let checkpointInterval = "atria.longWear.checkpointInterval"
        static let diagnosticInterval = "atria.longWear.diagnosticInterval"
        static let workoutAutoSaveInterval = "atria.longWear.workoutAutoSaveInterval"
        static let noDataTimeout = "atria.longWear.noDataTimeout"
        static let noDataCheckInterval = "atria.longWear.noDataCheckInterval"
        static let acceptedHRTimeout = "atria.longWear.acceptedHRTimeout"
        static let label = "atria.longWear.label"
    }
    enum OfflineSyncDefaults {
        static let enabled = "atria.offlineSync.enabled"
        static let lastAttemptAt = "atria.offlineSync.lastAttemptAt"
        static let lastStatus = "atria.offlineSync.lastStatus"
        static let lastReason = "atria.offlineSync.lastReason"
        static let attempts = "atria.offlineSync.attempts"
        static let rangeLossBackfillPending = "atria.offlineSync.rangeLossBackfillPending"
        static let rangeLossBackfillRequestedAt = "atria.offlineSync.rangeLossBackfillRequestedAt"
        static let rangeLossBackfillStartedAt = "atria.offlineSync.rangeLossBackfillStartedAt"
        static let rangeLossBackfillReason = "atria.offlineSync.rangeLossBackfillReason"
        static let recoveryWindowStart = "atria.offlineSync.recoveryWindowStart"
        static let recoveryWindowEnd = "atria.offlineSync.recoveryWindowEnd"
        static let verifiedHistoryPeripheralID = "atria.offlineSync.verifiedHistoryPeripheralID"
    }
    private enum HRVCadenceDefaults {
        static let lastReadyAnalysisAt = "atria.hrv.lastReadyAnalysisAt"
        static let lastNormalWearAnalysisAttemptAt = "atria.hrv.lastNormalWearAnalysisAttemptAt"
        static let readySnapshot = "atria.hrv.readySnapshot.v1"
    }

    nonisolated static func readNormalWearHRVAnalysisAttemptDate(
        userDefaults: UserDefaults = .standard
    ) -> Date? {
        userDefaults.object(forKey: HRVCadenceDefaults.lastNormalWearAnalysisAttemptAt) as? Date
    }

    nonisolated static func persistNormalWearHRVAnalysisAttemptDate(
        _ date: Date,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(date, forKey: HRVCadenceDefaults.lastNormalWearAnalysisAttemptAt)
    }
    enum KeepaliveDefaults {
        static let armed = "atria.keepalive.armed"
        static let armedAt = "atria.keepalive.armedAt"
        static let lastStatus = "atria.keepalive.lastStatus"
        static let lastReason = "atria.keepalive.lastReason"
        static let lastAction = "atria.keepalive.lastAction"
        static let lastSilence = "atria.keepalive.lastSilence"
        static let tickStartedAt = "atria.keepalive.tickStartedAt"
        static let lastTickAt = "atria.keepalive.lastTickAt"
        static let timerStartedAt = "atria.keepalive.timerStartedAt"
        static let timerFiredAt = "atria.keepalive.timerFiredAt"
        static let dispatchTimerStartedAt = "atria.keepalive.dispatchTimerStartedAt"
        static let dispatchTimerFiredAt = "atria.keepalive.dispatchTimerFiredAt"
        static let lastPeripheralState = "atria.keepalive.lastPeripheralState"
        static let lastRawNotifications = "atria.keepalive.lastRawNotifications"
        static let lastRawNotificationDelta = "atria.keepalive.lastRawNotificationDelta"
        static let lastSampleCheckAt = "atria.keepalive.lastSampleCheckAt"
        static let ticks = "atria.keepalive.ticks"
        static let stallReconnects = "atria.keepalive.stallReconnects"
        static let lastStallReconnectAt = "atria.keepalive.lastStallReconnectAt"
        static let lastReadPollAt = "atria.keepalive.lastReadPollAt"
        static let lastReadPollResultAt = "atria.keepalive.lastReadPollResultAt"
        static let lastReadPollResultStatus = "atria.keepalive.lastReadPollResultStatus"
        static let lastReadPollResultBPM = "atria.keepalive.lastReadPollResultBPM"
        static let lastReadPollResultRRValues = "atria.keepalive.lastReadPollResultRRValues"
    }
    enum CollectionProfileDefaults {
        static let profile = "atria.collection.profile"
    }
    enum DutyCycleDefaults {
        static let enabled = "atria.dutycycle.enabled"
        static let focusFullCapture = "atria.dutycycle.focusFullCapture"
        static let sleepWindowStartMin = "atria.dutycycle.sleepWindowStartMin"
        static let sleepWindowEndMin = "atria.dutycycle.sleepWindowEndMin"
    }

    /// Daytime power saver (docs/24 §13): full-rate capture during the learned
    /// sleep window, workouts, live-screen use, and HR escalation; a sparse 2A37
    /// read-poll otherwise. A policy layer only — no new reconnect variants.
    enum DutyCycleState: String {
        case fullCapture
        case sparseSentinel
    }

    enum Packet {
        static let command: UInt8 = 0x23
        static let realtime: UInt8 = 0x28
        static let realtimeRaw: UInt8 = 0x2B
        static let historical: UInt8 = 0x2f
        static let event: UInt8 = 0x30
        static let metadata: UInt8 = 0x31
        static let imu: UInt8 = 0x33
    }
    enum ProtocolDefaults {
        static let packets = "atria.protocol.packets"
        static let imuFrames = "atria.protocol.imuFrames"
        static let diagnosticFrames = "atria.protocol.diagnosticFrames"
        static let eventFrames = "atria.protocol.eventFrames"
        static let unknownFrames = "atria.protocol.unknownFrames"
        static let lastPacketType = "atria.protocol.lastPacketType"
        static let lastPacketKind = "atria.protocol.lastPacketKind"
        static let lastPacketLength = "atria.protocol.lastPacketLength"
    }
    enum Cmd {
        static let linkValid: UInt8 = 0x01
        static let toggleRealtimeHR: UInt8 = 0x03
        static let setClock: UInt8 = 0x0A
        static let getClock: UInt8 = 0x0B
        static let abortHistoricalTransmits: UInt8 = 0x14
        static let getBatteryLevel: UInt8 = 0x1A
        static let sendHistoricalData: UInt8 = 0x16
        static let historicalDataResult: UInt8 = 0x17
        static let getDataRange: UInt8 = 0x22
        static let sendR10R11Realtime: UInt8 = 0x3F
        static let runHapticsPattern: UInt8 = 0x4F
        static let toggleIMUMode: UInt8 = 0x6A
        static let stopHaptics: UInt8 = 0x7A
        static let enterHighFreqSync: UInt8 = 0x60
    }
    var maxHRSetting = UserDefaults.standard.object(forKey: "maxHR") as? Int ?? 190 {
        didSet { UserDefaults.standard.set(maxHRSetting, forKey: "maxHR") }
    }
    private var sessionStart = Date()

    /// Called when a session ends (disconnect) with enough samples to be worth
    /// keeping — wired to the SessionStore so runs auto-save even unattended.
    var onSessionEnd: ((SavedSession) -> Bool)?
    var onSessionCheckpoint: ((SavedSession) -> Bool)?
    private let autoSaveMinSamples = 10

    private var sessionMinHeartRate: Int?
    private var sessionMaxHeartRate: Int?
    private var sessionHeartRateTotal = 0
    private var sessionHeartRateAggregateCount = 0
    private var sessionHeartRateMean = 0.0
    private var sessionHeartRateM2 = 0.0

    // Off-main historical-motion cache (2026-07-09, device-reported tab-switch
    // freeze). snapshotSession used to parse several MB of the (pre-compaction,
    // ~80 MB) historical archive on the MainActor every checkpoint. Instead a
    // background task refreshes this value off-main and snapshotSession reads it.
    // Keyed by the live session's start (`Origin`) so a value from a previous
    // rolled/reset segment is never reused for a new one.
    private var cachedHistoricalMotion: HistoricalArchive.MotionFeatureSummary?
    private var cachedHistoricalMotionOrigin: Date?
    private var cachedHistoricalMotionAt: Date?
    private var historicalMotionRefreshInFlight = false

    var restingHR: Int? { sessionMinHeartRate }   // lowest sustained = resting proxy
    var peakHR: Int? { sessionMaxHeartRate }
    var avgHR: Int? {
        guard !session.isEmpty else { return nil }
        return sessionHeartRateTotal / session.count
    }
    var currentZone: HRZone { HRZone.zone(for: heartRate, maxHR: maxHRSetting) }

    // Capture: when recording, every frame, HR sample, RR interval, and HRV
    // snapshot is appended as a CSV row for reference validation.
    @Published var isRecording = false
    @Published var capturedRows = 0
    var captureLabel = ""
    @Published var captureSummary = "No backup yet"
    @Published var captureWasValidationReady = false
    private(set) var captureElapsedSeconds: TimeInterval = 0
    @Published var lastCaptureFile = ""
    private var captureLog: [String] = []
    private var captureRowsFlushTask: Task<Void, Never>?
    private var captureStart = Date()
    private var captureCleanWindowStart = Date()
    private var captureAbortReason: String?
    private var captureQualityResetCount = 0
    private var strictLiveRRCapture = false
    private var captureTimer: Timer?
    private var captureRRQualityWindow: [(t: Date, hasRR: Bool, source: String)] = []
    private var captureRRQualityWindowHead = 0
    private var lastRRBeatTime: Date?
    private var lastRRExportElapsedMS: Int?
    private var launchAutomationApplied = false
    private var autoStopCaptureWhenReady = false
    private var autoStopCaptureAfterSeconds: TimeInterval = 0
    private var autoCaptureDelaySeconds: TimeInterval = 0
    private var autoCaptureRRThreshold: Double = 0
    private var autoCaptureRRWindowSeconds: TimeInterval = 30
    private var autoCaptureRRMinFrames = 10
    private var autoCaptureMaxRRGapSeconds: TimeInterval = 0
    private var autoCaptureRRTimeoutSeconds: TimeInterval = 0
    private var autoCaptureMaxAttempts = 1
    private var autoCaptureAttempt = 0
    private var autoCaptureScheduledAt: Date?
    private var autoCapturePending = false
    private var autoCaptureRRWindow: [(t: Date, hasRR: Bool, source: String)] = []
    private var autoCaptureRRWindowHead = 0
    private var autoCaptureTimeoutTask: Task<Void, Never>?
    private var lastAutoCaptureRRGateLogAt: Date?
    private var autoStoppedReadyCapture = false
    private var realtimeStartRetries = 0
    private var livePacketSummaryLoggingEnabled = false
    private var protocolDiagnosticsPersistenceEnabled = false
    private nonisolated(unsafe) var strapStepCalibrationCaptureUntil: Date?
    private var realtimeRestartAfterZeroRRSeconds: TimeInterval = 0
    private var realtimeReassertStartAfterZeroRRSeconds: TimeInterval = 0
    private var probeCommand: [UInt8]?
    private var probeCommandDelaySeconds: TimeInterval = 0
    private var probeCommandMode: CommandWriteMode = .withoutResponse
    private var probeSweepCommands: [[UInt8]] = []
    private var probeSweepIntervalSeconds: TimeInterval = 30
    private var historicalAckDisabled = false
    private var historyAckMode = "trim"
    private var historyRecentSweepEnabled = false
    private var historyRecentSweepSent = false
    private var historyRecentSweepOffsets: [UInt32] = [0, 300, 3_600]
    private var historySelectorSweepEnabled = false
    private var historySelectorSweepSent = false
    private var historySelectorMode = "current-unix-bare"
    private var historySelectorRangeIndex: Int?
    private var historyOnlyProbeEnabled = false
    private var historyOnlyProbeArmed = false
    private var historyDataRangeSweepEnabled = false
    private var historyDataRangeSweepPayloads: [[UInt8]] = [[0x00]]
    private var historyDataRangePendingRequests: [(index: Int, data: [UInt8])] = []
    private var historyInitSweepCommands: [[UInt8]] = []
    private var historySkipDataRangeRequest = false
    private nonisolated(unsafe) var historyOnlyProbeMode = false
    private var historyClockSyncEnabled = false
    private var historyClockRef: HistoryClockRef?
    private var offlineHistoricalSyncInProgress = false
    private var offlineHistoricalSyncGeneration: UInt64 = 0
    /// Historical replay temporarily owns the proprietary command pipeline, but
    /// it must not change the user's radio choice when that replay finishes.
    /// In particular, changing profiles here tears down the live R10 transport
    /// and can strand step publication after every recovery attempt.
    private var offlineHistoricalSyncPreviousStandardHROnlyMode = false
    private var pendingOfflineHistoricalSyncReason: String?
    private let offlineHistoricalSyncMinimumInterval: TimeInterval = 6 * 60 * 60
    private let offlineSyncLiveAcceptedHRProtectionWindow: TimeInterval = 45
    private let rangeLossBackfillReadyForceInterval: TimeInterval = 90
    private let rangeLossBackfillRetryInterval: TimeInterval = 10 * 60
    private let rangeLossBackfillArmedTimeout: TimeInterval = 180
    private var rangeLossBackfillTask: Task<Void, Never>?
    private var staleRangeLossReconciliationInFlight = false
    private var lastStaleRangeLossReconciliationAttemptAt: Date?
    private var offlineHistoricalSyncStartRows = 0
    /// True only when this sync appended metric-usable HR inside the exact
    /// workout-recovery window. This is progress evidence, not completion:
    /// SessionStore owns completion after it rebuilds the matching workout and
    /// proves the merged stream reached the coverage floor.
    private var offlineHistoricalSyncMadeRequestedMetricProgress = false
    /// True only when metric-usable timestamps from this replay retired at
    /// least one durable missing-range ledger window.
    private var offlineHistoricalSyncResolvedGapCoverage = false
    @Published private(set) var standardHROnlyEnabled = UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
    @Published private(set) var longWearModeEnabled = UserDefaults.standard.bool(forKey: LongWearDefaults.enabled)
    @Published private(set) var collectionProfile = CollectionProfile.load()
    private nonisolated(unsafe) var standardHROnlyMode = UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
    private var historicalArchiveRows = 0
    private var historicalArchiveRowsSinceAck = 0
    private var historicalArchiveWriteFailures = 0
    private var lastHistoricalArchivePath = ""
    private var historyDrainGate = HistoryDrainGate()
    private var pendingHistoryEndACK: (key: String, payload: [UInt8])?
    private var pendingHistoryACKAttempts = 0
    private var historyDurableFlushInFlight = false
    private var offlineHistoricalSyncReason = "offline_history"
    private var offlineHistoricalSyncTimeoutTask: Task<Void, Never>?
    private var protocolPacketCount = 0
    private var protocolIMUFrameCount = 0
    private var decodedIMUSampleCount = 0
    private var imuGravityValidatedFrameCount = 0
    private var imuStillnessRatioSum = 0.0
    private var imuMovementIntensitySum = 0.0
    private var imuActivityBurstCount = 0
    private var imuValidationState = "unavailable"
    private var imuSampleRateHzSum = 0.0
    private var imuSampleRateHzCount = 0
    private var imuLastFrameAt: Date?
    private var imuInferredScale: Double?
    private var imuInferredEndian: String?
    private var r10MotionFrameCount = 0
    private var lastR10MotionFrameAt: Date?
    /// Most recent CRC-valid, fixed-layout R10 motion frame. This is published
    /// independently from the step count: a stationary user still needs Home,
    /// widgets and Live Activity to know the strap motion stream is alive.
    @Published private(set) var liveStrapMotionCapturedAt: Date?
    private var passiveR10FirstFrameTask: Task<Void, Never>?
    @Published private(set) var stepCalibrationCaptureArmedAt: Date?
    @Published private(set) var stepCalibrationMotionStreamReady = false
    private var strapStepResearchCount = 0
    private var strapStepResearchPeakCount = 0
    @Published private(set) var liveStrapStepResearchCount = 0
    @Published private(set) var liveStrapStepResearchTodayCount = 0
    @Published private(set) var liveStrapStepResearchState = "research_unvalidated"
    private var strapStepResearchState = "research_unvalidated"
    private var lastLiveStrapStepResearchPublishedAt: Date?
    private var pendingLiveStrapStepResearchPublishTask: Task<Void, Never>?
    private var strapStepResearchDay = Calendar.current.startOfDay(for: Date())
    private var strapStepResearchDayBaseline = 0
    nonisolated static let liveStrapStepResearchPublishMinimumInterval: TimeInterval = 1
    nonisolated static let liveStrapStepResearchPublishMinimumDelta = 5
    private var researchProbeFrameCount = 0
    private var researchProbeOxygenCandidateFrames = 0
    private var researchProbeTemperatureCandidateFrames = 0
    private var researchProbeTemperatureCandidateValueSum = 0
    private var researchProbeTemperatureCandidateValueCount = 0
    private var researchProbeGenerationGate = AtriaResearchProbe.GenerationGate()
    private var unknownGenerationProbeLogCount = 0
    private var protocolDiagnosticFrameCount = 0
    private var protocolEventFrameCount = 0
    private var protocolUnknownFrameCount = 0
    private var protocolLastPacketType = "none"
    private var protocolLastPacketKind = "none"
    private var protocolLastPacketLength = 0
    private var morningHRVForce = false
    private var delayedSessionSaveTask: Task<Void, Never>?
    private var liveWorkoutDiagnosticTask: Task<Void, Never>?
    private var workoutAutoSaveTask: Task<Void, Never>?
    private var longWearSupervisorTask: Task<Void, Never>?
    private var activeLongWearSupervisorConfig: LongWearSupervisorConfig?
    private var noDataWatchdogTask: Task<Void, Never>?
    private var hrContinuityWatchdogTask: Task<Void, Never>?
    private var rrPresenceWatchdogTask: Task<Void, Never>?
    private var acceptedHRWatchdogTask: Task<Void, Never>?
    /// Lightweight safety net for long-wear live links. It remains armed across
    /// foreground/app-switch transitions because a nominally `.connected` link
    /// can go completely silent (no 2A37 packets at all) while other supervisor
    /// work is paused or background-throttled.
    private var foregroundKeepaliveTask: Task<Void, Never>?
    private var foregroundKeepaliveReassertAt: Date?
    private var foregroundKeepaliveLastJournalFlushAt: Date?
    private var foregroundKeepaliveLastRawNotifications: Int?
    private var lastStallHardReconnectAt: Date?
    private var debugActiveJournalFlushTask: Task<Void, Never>?
    private var debugManualCheckpointTask: Task<Void, Never>?
    private var debugNoDataWatchdogTask: Task<Void, Never>?
    private var debugHRContinuityWatchdogTask: Task<Void, Never>?
    private var debugRRPresenceWatchdogTask: Task<Void, Never>?
    private var debugRRPresenceWatchdogDueAt: Date?
    private var debugRRPresenceWatchdogFired = false
    private var debugMissingHeartRateCharacteristicTask: Task<Void, Never>?
    private var debugMissingHeartRateCharacteristicAfterDiscovery: TimeInterval?
    private var debugMissingHeartRateCharacteristicFired = false
    private var debugAcceptedHRWatchdogTask: Task<Void, Never>?
    private var hrConsistencyEnabled = false
    private var lastStandardHR: (bpm: Int, t: Date)?
    private var lastRealtimeHR: (bpm: Int, t: Date)?
    private var lastHRVAnalysisAt: Date?
    private var lastHRVAnalysisAttemptAt: Date?
    private var lastNormalWearHRVAnalysisAttemptAt: Date?
    private var lastRawHRNotificationAt: Date?
    /// Timestamp of the most recent inbound GATT value of ANY kind (battery, HR,
    /// device-info…). It proves the link is alive even when the HR stream
    /// (0x2A37) is briefly silent in low-radio mode, so the no-data watchdog
    /// cannot tear down a genuinely connected peripheral.
    private var lastGattActivityAt: Date?
    private var sessionRawHRNotifications = 0
    private var sessionAcceptedHRSamples = 0
    private var sessionZeroHRSamples = 0
    private var sessionHeldArtifacts = 0
    private var sessionDroppedArtifacts = 0
    private var sessionRawHRGaps = 0
    private var sessionAcceptedHRGaps = 0
    private var sessionMaxRawHRGap: TimeInterval = 0
    private var sessionMaxAcceptedHRGap: TimeInterval = 0
    private enum WorkoutPromptQualityEventKind {
        case raw
        case accepted
        case zero
        case heldArtifact
        case droppedArtifact
        case acceptedGap(TimeInterval)
    }
    private struct WorkoutPromptQualityEvent {
        let date: Date
        let kind: WorkoutPromptQualityEventKind
    }
    private var workoutPromptQualityEvents: [WorkoutPromptQualityEvent] = []

    private func recordWorkoutPromptQualityEvent(_ kind: WorkoutPromptQualityEventKind,
                                                 at date: Date) {
        workoutPromptQualityEvents.append(.init(date: date, kind: kind))
        let cutoff = date.addingTimeInterval(-10 * 60)
        if workoutPromptQualityEvents.count > 900,
           let firstKept = workoutPromptQualityEvents.firstIndex(where: { $0.date >= cutoff }) {
            workoutPromptQualityEvents.removeFirst(firstKept)
        }
    }

    /// Snapshot the strap's own HR/contact/RR audit trail for live workout
    /// prompting. This intentionally has no Core Motion dependency: denying
    /// phone activity access cannot weaken or disable physiological validation.
    func workoutPromptSignalQuality(now: Date = Date(),
                                    lookback: TimeInterval = TimeInterval(AtriaWorkoutPromptEvaluator.minimumSustainedSamples)) -> AtriaWorkoutPromptEvaluator.SignalQuality {
        let cutoff = now.addingTimeInterval(-lookback)
        var raw = 0
        var accepted = 0
        var zero = 0
        var held = 0
        var dropped = 0
        var gaps = 0
        var maxGap: TimeInterval = 0
        for event in workoutPromptQualityEvents where event.date >= cutoff && event.date <= now {
            switch event.kind {
            case .raw: raw += 1
            case .accepted: accepted += 1
            case .zero: zero += 1
            case .heldArtifact: held += 1
            case .droppedArtifact: dropped += 1
            case let .acceptedGap(duration):
                gaps += 1
                maxGap = max(maxGap, duration)
            }
        }
        let implied = rrArchive.lazy
            .filter { $0.t >= cutoff && $0.t <= now && $0.ms > 0 }
            .map { 60_000.0 / Double($0.ms) }
            .sorted()
        let median: Double?
        if implied.count >= 3 {
            let middle = implied.count / 2
            median = implied.count.isMultiple(of: 2)
                ? (implied[middle - 1] + implied[middle]) / 2
                : implied[middle]
        } else {
            median = nil
        }
        return AtriaWorkoutPromptEvaluator.SignalQuality(
            rawSamples: raw,
            acceptedSamples: accepted,
            zeroSamples: zero,
            heldArtifacts: held,
            droppedArtifacts: dropped,
            acceptedGapCount: gaps,
            maxAcceptedGap: maxGap,
            rrImpliedMedianBPM: median
        )
    }
    // HRV is a slow recovery signal, not a live pulse metric. Keep explicit
    // capture/recording responsive, but let normal all-day wear refresh on a
    // slower WHOOP-style cadence.
    private var sampleDiagnostics = SampleDiagnosticsSnapshot.load()
    private var sampleDiagnosticsFlushTask: Task<Void, Never>?
    private var hrConsistencyPairs = 0
    private var hrConsistencyDeltaSum = 0
    private var hrConsistencyMaxDelta = 0
    private var hrConsistencyRecentDeltas: [Int] = []
    private var hrConsistencyLastLogAt: Date?
    private var verboseBLEFrameLogging = false
    private var verboseBLEFrameLogCount = 0
    private var verboseBLEFrameLogSuppressed = false
    private var storeProprietaryFrames = false
    private nonisolated(unsafe) var storeProprietaryFramesMode = false
    private var standardHRPayloadLogCount = 0
    private var standardHRPayloadLogSuppressed = 0
    private var lastStandardHRPayloadLogAt: Date?
    private var segmentHROnlyRRRecoveryCount = 0
    private var lastSegmentHROnlyRRRecoveryAt: Date?
    private var currentRRGapRecoveryCount = 0
    private var lastCurrentRRGapRecoveryAt: Date?
    private var lastMissingHeartRateDiscoveryAt: Date?
    private var acceptedHeartRateBatchDepth = 0
    private var acceptedHeartRateBatchNeedsJournalCheck = false
    private var acceptedHeartRateBatchForceJournalSave = false
    private var acceptedHeartRateBatchLatestCheckpointAt: Date?
    private var acceptedHeartRateBatchPendingConsistencyAt: Date?
    private var acceptedHeartRateBatchPendingRRContinuityAt: Date?
    private var acceptedHeartRateBatchPendingAutoCaptureAt: Date?
    private var acceptedHeartRateBatchPendingSegmentRRRecoveryAt: Date?
    private var acceptedHeartRateBatchPendingCurrentRRRecoveryAt: Date?
    private var acceptedHeartRateBatchPendingDisplayRate: Int?
    private var acceptedHeartRateBatchPendingDisplayAt: Date?
    private var acceptedHeartRateBatchPendingDisplayForce = false

    private func setSampleDiagnosticsStatus(_ status: String, reason: String) {
        sampleDiagnostics.lastStatus = status
        sampleDiagnostics.lastReason = reason
        scheduleSampleDiagnosticsFlush()
    }

    private static let sampleDiagnosticsFlushDelay: TimeInterval = 2.5

    private func persistedLastRawNotificationAt(defaults: UserDefaults = .standard) -> Date? {
        let interval = defaults.double(forKey: SampleDefaults.lastRawNotificationAt)
        return interval > 0 ? Date(timeIntervalSince1970: interval) : nil
    }

    nonisolated static func latestLinkActivity(_ candidates: [Date?]) -> Date? {
        candidates.compactMap { $0 }.max()
    }

    private func heartRatePacketAge(now: Date = Date(), defaults: UserDefaults = .standard) -> TimeInterval? {
        let lastPacketAt = lastRawHRNotificationAt ?? persistedLastRawNotificationAt(defaults: defaults)
        return lastPacketAt.map { now.timeIntervalSince($0) }
    }

    private func recordHeartRateReadPollResultIfNeeded(parsed: ParsedHeartRatePacket?,
                                                       defaults: UserDefaults = .standard,
                                                       now: Date = Date()) {
        let readPollAt = defaults.double(forKey: KeepaliveDefaults.lastReadPollAt)
        guard readPollAt > 0, now.timeIntervalSince1970 - readPollAt <= 10 else { return }
        defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastReadPollResultAt)
        guard let parsed else {
            defaults.set("parse_failed", forKey: KeepaliveDefaults.lastReadPollResultStatus)
            defaults.set(-1, forKey: KeepaliveDefaults.lastReadPollResultBPM)
            defaults.set(-1, forKey: KeepaliveDefaults.lastReadPollResultRRValues)
            return
        }
        defaults.set("value_received", forKey: KeepaliveDefaults.lastReadPollResultStatus)
        defaults.set(parsed.hr, forKey: KeepaliveDefaults.lastReadPollResultBPM)
        defaults.set(parsed.rrValues.count, forKey: KeepaliveDefaults.lastReadPollResultRRValues)
    }

    private func updateStrapStreamState(reason: String,
                                        packetAge: TimeInterval? = nil,
                                        rawNotificationDelta: Int? = nil,
                                        notifying: Bool? = nil,
                                        defaults: UserDefaults = .standard) {
        let now = Date()
        let resolvedPacketAge = packetAge ?? heartRatePacketAge(now: now, defaults: defaults)
        let resolvedNotifying = notifying ?? heartRateCharacteristic?.isNotifying
        let gattReadsOK = lastGattActivityAt.map { now.timeIntervalSince($0) <= 10 * 60 } ?? false
        let recentRawNotificationDelta = defaults.integer(forKey: KeepaliveDefaults.lastRawNotificationDelta)
        let recentSampleCheckAt = defaults.double(forKey: KeepaliveDefaults.lastSampleCheckAt)
        let recentSampleCheckAge = recentSampleCheckAt > 0 ? now.timeIntervalSince1970 - recentSampleCheckAt : .infinity
        let effectiveBatteryLevel = displayableBatteryLevel(now: now) ?? -1
        let effectiveBatteryIsCharging = effectiveBatteryLevel >= 0 && batteryIsCharging
        let lowBatteryLiveLimited = status == .connected
            && gattReadsOK
            && resolvedNotifying == true
            && effectiveBatteryLevel >= 0
            && effectiveBatteryLevel <= Self.lowBatteryWarningThreshold
        let lowBatteryPowerSave = lowBatteryLiveLimited
            && effectiveBatteryLevel <= Self.lowBatteryBroadcastShutoffThreshold
            && !effectiveBatteryIsCharging
        let notificationsGrowing = (rawNotificationDelta ?? (recentSampleCheckAge <= 180 ? recentRawNotificationDelta : 0)) > 0
        let freshChargedNotification = status == .connected
            && resolvedNotifying == true
            && effectiveBatteryLevel > Self.lowBatteryWarningThreshold
            && (resolvedPacketAge.map { $0 <= 10 } ?? false)
        let nextState: StrapStreamState
        if status == .connected, notificationsGrowing || freshChargedNotification {
            nextState = .live
        } else if lowBatteryLiveLimited,
           !notificationsGrowing,
           let resolvedPacketAge,
           resolvedPacketAge <= Self.staleHeartRatePacketThreshold {
            nextState = .lowBatteryReducedDetail
        } else if lowBatteryPowerSave,
                  !notificationsGrowing {
            nextState = .lowBatteryShutoff
        } else if let resolvedPacketAge, resolvedPacketAge > Self.staleHeartRatePacketThreshold, status == .connected {
            nextState = .silentUnknown
        } else if status == .connected {
            nextState = .warming
        } else {
            nextState = .unknown
        }
        assignIfChanged(\.strapStreamState, nextState)
        defaults.set(nextState.rawValue, forKey: StrapStreamDefaults.state)
        defaults.set(reason, forKey: StrapStreamDefaults.reason)
        defaults.set(resolvedPacketAge ?? -1, forKey: StrapStreamDefaults.packetAge)
        defaults.set(effectiveBatteryLevel, forKey: StrapStreamDefaults.batteryLevel)
        defaults.set(resolvedNotifying == true, forKey: StrapStreamDefaults.notifying)
        defaults.set(gattReadsOK, forKey: StrapStreamDefaults.gattReadsOK)
        defaults.set(now.timeIntervalSince1970, forKey: StrapStreamDefaults.updatedAt)
        defaults.set(strapStreamAccessibilityLabel(for: nextState), forKey: StrapStreamDefaults.accessibilityLabel)
        if !lowBatteryPowerSave,
           effectiveBatteryIsCharging || effectiveBatteryLevel > Self.lowBatteryBroadcastShutoffThreshold {
            clearLowBatteryReconnectSuppression(defaults: defaults, now: now)
        }
    }

    private func markLowBatteryReconnectSuppressed(reason: String, defaults: UserDefaults = .standard, now: Date = Date()) {
        let wasSuppressed = defaults.bool(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.set(true, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.set(now.timeIntervalSince1970, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.set(reason, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        if !wasSuppressed {
            defaults.set(defaults.integer(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionCount) + 1,
                         forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionCount)
        }
    }

    private func clearLowBatteryReconnectSuppression(defaults: UserDefaults = .standard, now: Date = Date()) {
        let wasSuppressed = defaults.bool(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.set(false, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        if wasSuppressed {
            defaults.set(now.timeIntervalSince1970, forKey: StrapStreamDefaults.lowBatteryReconnectRearmedAt)
        }
    }

    private func strapStreamAccessibilityLabel(for state: StrapStreamState) -> String {
        switch state {
        case .lowBatteryShutoff:
            return "Strap battery too low for live heart rate. Charge your strap to resume tracking."
        case .lowBatteryReducedDetail:
            return "Low-battery mode. Live heart rate may update with reduced detail until you charge your strap."
        case .silentUnknown:
            return "Strap connected, but live heart rate is not arriving."
        case .live:
            return "Strap connected and live heart rate is arriving."
        case .warming:
            return "Strap connected. Waiting for live heart rate."
        case .unknown:
            return "Strap stream state pending."
        }
    }

    private func scheduleSampleDiagnosticsFlush() {
        guard sampleDiagnosticsFlushTask == nil else { return }
        sampleDiagnosticsFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.sampleDiagnosticsFlushDelay))
            guard !Task.isCancelled else { return }
            flushSampleDiagnostics()
        }
    }

    private func flushSampleDiagnostics() {
        sampleDiagnosticsFlushTask?.cancel()
        sampleDiagnosticsFlushTask = nil
        let defaults = UserDefaults.standard
        defaults.set(sampleDiagnostics.rawNotifications, forKey: SampleDefaults.rawNotifications)
        defaults.set(sampleDiagnostics.acceptedSamples, forKey: SampleDefaults.acceptedSamples)
        defaults.set(sampleDiagnostics.zeroSamples, forKey: SampleDefaults.zeroSamples)
        defaults.set(sampleDiagnostics.heldArtifacts, forKey: SampleDefaults.heldArtifacts)
        defaults.set(sampleDiagnostics.droppedArtifacts, forKey: SampleDefaults.droppedArtifacts)
        defaults.set(sampleDiagnostics.rawGaps, forKey: SampleDefaults.rawGaps)
        defaults.set(sampleDiagnostics.acceptedGaps, forKey: SampleDefaults.acceptedGaps)
        defaults.set(sampleDiagnostics.maxRawGap, forKey: SampleDefaults.maxRawGap)
        defaults.set(sampleDiagnostics.maxAcceptedGap, forKey: SampleDefaults.maxAcceptedGap)
        defaults.set(sampleDiagnostics.lastStatus, forKey: SampleDefaults.lastStatus)
        defaults.set(sampleDiagnostics.lastReason, forKey: SampleDefaults.lastReason)
        if let lastRawHRNotificationAt {
            defaults.set(lastRawHRNotificationAt.timeIntervalSince1970,
                         forKey: SampleDefaults.lastRawNotificationAt)
        }
        updateStrapStreamState(reason: "sample_diagnostics_flush", defaults: defaults)
    }

    private var batteryDrainThermalBackoffActive: Bool {
        batteryRecentlyDropping && !batteryIsCharging && batteryLevel >= 0
    }

    private var effectiveThermalCadenceMultiplier: Double {
        max(powerThermalGovernor.cadenceMultiplier, batteryDrainThermalBackoffActive ? 1.75 : 1)
    }

    private var effectivePowerThermalMode: String {
        batteryDrainThermalBackoffActive && powerThermalGovernor.mode == .nominal
            ? "warm_battery_drain"
            : powerThermalGovernor.mode.rawValue
    }

    private var central: CBCentralManager!
    private var legacyCentralCleaners: [AtriaLegacyBLECentralCleaner] = []
    private let centralQueue = DispatchQueue(label: "com.adidshaft.atria.ble-central",
                                             qos: .utility)
    private nonisolated let proprietaryFrameReassembler = AtriaWhoop4FrameReassembler()
    private nonisolated let r10MotionPipeline = AtriaR10MotionPipeline()
    private nonisolated let historicalArchiveQueue = DispatchQueue(label: "com.adidshaft.atria.historical-archive",
                                                                   qos: .utility)
    private var peripheral: CBPeripheral?
    private let maxFrames = 200
    struct MotionHandshakeDiagnosticConfiguration: Equatable {
        static let enableArgument = "--atria-motion-handshake-diagnostic"
        static let confirmationArgument = "--atria-confirm-isolated-ble-diagnostic"
        static let runIDArgument = "--atria-motion-handshake-run-id"
        static let addHRDelayArgument = "--atria-motion-handshake-add-hr-after"
        static let activationConsentArgument = "--atria-confirm-single-r10-command-3f01"

        let runID: String
        let addHRDelay: TimeInterval
        let sendSingleR10Activation: Bool

        var restoreIdentifier: String {
            "com.adidshaft.atria.ble-motion-diagnostic-\(runID)"
        }

        static func parse(arguments: [String]) -> Self? {
            // Two independent, diagnostics-specific switches plus a unique run
            // identifier make this unreachable from every normal app launch.
            guard arguments.contains(enableArgument),
                  arguments.contains(confirmationArgument),
                  let runIndex = arguments.firstIndex(of: runIDArgument),
                  arguments.indices.contains(arguments.index(after: runIndex)) else {
                return nil
            }
            let runID = arguments[arguments.index(after: runIndex)]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
            guard (1...32).contains(runID.count),
                  runID.unicodeScalars.allSatisfy(allowed.contains) else {
                return nil
            }
            var delay: TimeInterval = 60
            if let delayIndex = arguments.firstIndex(of: addHRDelayArgument),
               arguments.indices.contains(arguments.index(after: delayIndex)),
               let parsed = TimeInterval(arguments[arguments.index(after: delayIndex)]),
               (15...300).contains(parsed) {
                delay = parsed
            }
            return Self(runID: runID,
                        addHRDelay: delay,
                        sendSingleR10Activation: arguments.contains(activationConsentArgument))
        }
    }

    private let motionHandshakeDiagnostic = MotionHandshakeDiagnosticConfiguration.parse(
        arguments: ProcessInfo.processInfo.arguments
    )
    private var motionHandshakeAddHRTask: Task<Void, Never>?
    private var motionHandshakeActivationSent = false
    private var protectedR10ActivationSent = false
    private var protectedR10ActivationAt: Date?
    private var protectedR10FramesAfterActivation = 0
    private var protectedR10ActivationGraceTask: Task<Void, Never>?
    private var protectedR10MissingFrameTask: Task<Void, Never>?
    private var protectedR10StabilityTask: Task<Void, Never>?
    private var protectedR10PassiveReprobeTimeoutTask: Task<Void, Never>?
    nonisolated private static let protectedR10RollbackKey = "atria.protectedR10.rollback"
    nonisolated private static let protectedR10StreamSuppressedKey = "atria.protectedR10.streamSuppressed"
    nonisolated private static let protectedR10DisconnectStormAtKey = "atria.protectedR10.disconnectStormAt"
    nonisolated private static let protectedR10DisconnectStormReasonKey = "atria.protectedR10.disconnectStormReason"
    nonisolated private static let protectedR10PassiveReprobePendingKey = "atria.protectedR10.passiveReprobePending"
    nonisolated private static let protectedR10PassiveReprobeAttemptAtKey = "atria.protectedR10.passiveReprobeAttemptAt"
    nonisolated private static let protectedR10PassiveReprobeFailureCountKey = "atria.protectedR10.passiveReprobeFailureCount"
    nonisolated private static let protectedR10PassiveRetryMigrationKey = "atria.protectedR10.passiveRetryMigrationV3"
    nonisolated private static let protectedR10EarlyDisconnectsKey = "atria.protectedR10.earlyDisconnects"
    nonisolated private static let protectedR10ActivationSentAtKey = "atria.protectedR10.activationSentAt"
    nonisolated private static let protectedR10ActivationCountKey = "atria.protectedR10.activationCount"
    nonisolated private static let protectedR10FirstFrameAtKey = "atria.protectedR10.firstFrameAt"
    nonisolated private static let protectedR10RetryCountKey = "atria.protectedR10.retryCount"
    nonisolated private static let protectedR10StableTransportKey = "atria.protectedR10.stableTransport"
    nonisolated private static let protectedR10StableTransportQualifiedAtKey = "atria.protectedR10.stableTransportQualifiedAt"
    // V5 also clears the rollback previously latched by passive restoration
    // edges before Atria had sent its one protected activation command.
    nonisolated private static let protectedR10HistoryInterlockMigrationKey = "atria.protectedR10.realtimeActivationMigrationV5"
    nonisolated private static let protectedR10MissingFrameTimeout: TimeInterval = 20
    nonisolated private static let protectedR10PassiveGraceDuration: TimeInterval = 20
    nonisolated private static let protectedR10EarlyDisconnectWindow: TimeInterval = 90
    nonisolated private static let protectedR10EarlyDisconnectLimit = 2
    nonisolated private static let protectedR10RollbackRetryBaseDelay: TimeInterval = 10 * 60
    nonisolated private static let protectedR10RollbackRetryMaximumDelay: TimeInterval = 6 * 60 * 60
    nonisolated private static let protectedR10RollbackRetryStableHRDuration: TimeInterval = 60
    nonisolated private static let protectedR10PassiveReprobeStableHRDuration: TimeInterval = 2 * 60
    nonisolated private static let protectedR10PassiveReprobeInitialCooldown: TimeInterval = 30 * 60
    nonisolated private static let protectedR10PassiveReprobeMaximumCooldown: TimeInterval = 6 * 60 * 60
    nonisolated private static let protectedR10PassiveReprobeTimeout: TimeInterval = 2 * 60

    nonisolated static func shouldLatchProtectedR10RollbackForEarlyDisconnect(
        activationSent: Bool,
        connectedDuration: TimeInterval,
        previousEarlyDisconnects: Int
    ) -> Bool {
        activationSent
            && connectedDuration > 0
            && connectedDuration <= protectedR10EarlyDisconnectWindow
            && previousEarlyDisconnects + 1 >= protectedR10EarlyDisconnectLimit
    }

    nonisolated static func shouldLatchProtectedR10RollbackForMissingFrames(
        activationSent: Bool,
        framesAfterActivation: Int
    ) -> Bool {
        activationSent && framesAfterActivation == 0
    }

    nonisolated static func protectedR10FrameBelongsToCurrentConnection(
        lastFrameAt: Date?,
        connectedAt: Date?
    ) -> Bool {
        guard let lastFrameAt, let connectedAt else { return false }
        return lastFrameAt >= connectedAt
    }

    /// `3F/01` changes device-level realtime state; a CoreBluetooth connection
    /// edge alone is not evidence that the strap forgot it. Keep the most recent
    /// command as a persisted lease so reconnects observe stream 5 passively
    /// instead of writing the same command again.
    nonisolated static func protectedR10ActivationLeaseDelay(lastActivationAt: Date?,
                                                             now: Date,
                                                             minimumInterval: TimeInterval = protectedR10RollbackRetryBaseDelay) -> TimeInterval {
        guard let lastActivationAt else { return 0 }
        return max(0, minimumInterval - now.timeIntervalSince(lastActivationAt))
    }

    /// A disconnect-storm fuse must protect HR immediately, but it must not
    /// turn a transient field failure into permanently frozen strap steps. The
    /// recovery probe is deliberately passive: after a long, healthy 2A37
    /// window it only rediscovers/subscribes stream 5 on the existing link.
    /// It does not reconnect and it keeps the command rollback latched until a
    /// dense CRC-valid R10 window independently proves the transport.
    nonisolated static func shouldBeginProtectedR10PassiveReprobe(
        streamSuppressed: Bool,
        reprobePending: Bool,
        connected: Bool,
        stableHRDuration: TimeInterval,
        latestHRAge: TimeInterval?,
        disconnectStormAge: TimeInterval?,
        lastAttemptAge: TimeInterval?,
        failureCount: Int,
        batteryLevel: Int = -1,
        isCharging: Bool = false,
        stableHRMinimum: TimeInterval = protectedR10PassiveReprobeStableHRDuration,
        initialCooldown: TimeInterval = protectedR10PassiveReprobeInitialCooldown,
        maximumCooldown: TimeInterval = protectedR10PassiveReprobeMaximumCooldown
    ) -> Bool {
        let retryMultiplier = pow(2.0, Double(min(max(0, failureCount), 5)))
        let requiredCooldown = min(initialCooldown * retryMultiplier, maximumCooldown)
        guard streamSuppressed,
              !reprobePending,
              connected,
              shouldArmHighFrequencyMotion(batteryLevel: batteryLevel,
                                           isCharging: isCharging),
              stableHRDuration >= stableHRMinimum,
              let latestHRAge,
              latestHRAge >= 0,
              latestHRAge <= 10,
              let disconnectStormAge,
              disconnectStormAge >= requiredCooldown else { return false }

        if let lastAttemptAge {
            guard lastAttemptAge >= requiredCooldown else { return false }
        }

        return true
    }

    /// Older builds permanently suppressed stream 5 after one passive probe,
    /// including probes guaranteed to fail because their battery eligibility
    /// was not checked before discovery. Preserve the safety fuse but clear
    /// that poisoned retry history once so an eligible healthy link can run the
    /// corrected bounded probe.
    @discardableResult
    nonisolated static func migrateProtectedR10PassiveRetryIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard !defaults.bool(forKey: protectedR10PassiveRetryMigrationKey) else { return false }
        defaults.set(true, forKey: protectedR10PassiveRetryMigrationKey)
        defaults.set(0, forKey: protectedR10PassiveReprobeFailureCountKey)
        defaults.removeObject(forKey: protectedR10PassiveReprobeAttemptAtKey)
        return true
    }

    nonisolated static func shouldAbortProtectedR10PassiveReprobeForDisconnect(
        reprobePending: Bool,
        userRequestedDisconnect: Bool,
        atriaOwnedOfflineSyncDisconnect: Bool,
        reprobeDuration: TimeInterval?
    ) -> Bool {
        _ = reprobeDuration // retained for deterministic diagnostics/callers
        return reprobePending
            && !userRequestedDisconnect
            && !atriaOwnedOfflineSyncDisconnect
    }

    nonisolated static func protectedR10PassiveReprobeHasExpired(
        reprobePending: Bool,
        attemptAge: TimeInterval?,
        timeout: TimeInterval = protectedR10PassiveReprobeTimeout
    ) -> Bool {
        guard reprobePending else { return false }
        guard let attemptAge, attemptAge >= 0 else { return true }
        return attemptAge >= timeout
    }

    /// Historical offload and protected R10 share the proprietary service. A
    /// field soak proved that allowing an automatic offload immediately after
    /// qualification caused four reconnects and starved the motion stream. Keep
    /// automatic recovery durable but pending for the entire protected realtime
    /// session. Only an explicit user action may deliberately trade the live
    /// stream for history, and the workout/interlock checks below still apply.
    nonisolated static func shouldDeferOfflineSyncForProtectedR10Qualification(
        standardHROnlyMode: Bool,
        stableTransportProven: Bool,
        explicitUserRequest: Bool = false
    ) -> Bool {
        _ = stableTransportProven
        return standardHROnlyMode && !explicitUserRequest
    }

    /// Qualification proves R10 can remain live; it does not make it safe for
    /// an automatic history worker to seize the same proprietary service. Keep
    /// every automatic gap request durable and deferred for the full protected
    /// realtime mode. A deliberate user sync is the only allowed override.
    nonisolated static func shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
        standardHROnlyMode: Bool,
        explicitUserRequest: Bool
    ) -> Bool {
        standardHROnlyMode && !explicitUserRequest
    }

    /// R10 is nominally one decoded record per second. One early frame followed
    /// by 89 seconds of silence is not a stability proof; require most of the
    /// expected records and a fresh frame from this exact connection/arm epoch.
    nonisolated static func protectedR10StabilityWindowIsProven(
        framesAfterActivation: Int,
        lastFrameAt: Date?,
        connectedAt: Date?,
        activationAt: Date,
        now: Date,
        minimumFrames: Int = 75,
        maximumLastFrameAge: TimeInterval = 5
    ) -> Bool {
        guard framesAfterActivation >= minimumFrames,
              let lastFrameAt,
              let connectedAt,
              lastFrameAt >= connectedAt,
              lastFrameAt >= activationAt,
              lastFrameAt <= now else { return false }
        return now.timeIntervalSince(lastFrameAt) <= maximumLastFrameAge
    }

    private var centralRestoreIdentifier: String {
        // v4 briefly subscribed the proprietary stream-4 battery-event
        // characteristic during a physical experiment. CoreBluetooth can
        // restore that CCCD state even after the source subscription is rolled
        // back, which leaves the strap reconnecting about every ten seconds.
        // A fresh production namespace guarantees the stable HR + R10 profile
        // starts from a clean connection instead of inheriting that experiment.
        motionHandshakeDiagnostic?.restoreIdentifier
            ?? (protectedR10StreamSuppressed
                ? "com.adidshaft.atria.ble-central-v6-pure-hr"
                : "com.adidshaft.atria.ble-central-v5")
    }

    nonisolated private var protectedR10RollbackEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.protectedR10RollbackKey)
    }

    /// Separate from command rollback. A failed `3F/01` must not make Atria
    /// unsubscribe from or discard CRC-valid passive R10 frames on reconnect.
    nonisolated private var protectedR10StreamSuppressed: Bool {
        UserDefaults.standard.bool(forKey: Self.protectedR10StreamSuppressedKey)
    }

    nonisolated private var protectedR10PassiveReprobePending: Bool {
        UserDefaults.standard.bool(forKey: Self.protectedR10PassiveReprobePendingKey)
    }

    private var discoveryServicesForCurrentMode: [CBUUID] {
        if motionHandshakeDiagnostic != nil { return [Self.UUIDs.strapService] }
        if standardHROnlyMode, !historyOnlyProbeMode {
            return Self.protectedStandardHRServices(
                streamSuppressed: protectedR10StreamSuppressed
            )
        }
        return Self.UUIDs.discoveryServices
    }
    private let minimumEventDrivenCheckpointInterval: TimeInterval = 180
    private var lastCanonicalCheckpointAt: Date?
    private let reconnectWatchdogSeconds: TimeInterval = 20
    private var reconnectWatchdogTask: Task<Void, Never>?
    private var scanRetryTask: Task<Void, Never>?
    private var scanWideningTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var freshScanFallbackTask: Task<Void, Never>?
    private var batteryChargeExpirationTask: Task<Void, Never>?
    private var batteryConfirmationReadTask: Task<Void, Never>?
    private var batteryConfirmationReadLevel: Int?
    private var batteryLevelCharacteristic: CBCharacteristic?
    private var batteryStatusCharacteristic: CBCharacteristic?
    private var lastBatteryReadRequestedAt: Date?
    private var lastActiveBatteryChargeEvidenceAt: Date?
    private var lastAcceptedBatteryLevelAt: Date?
    private var displayedBatteryLevelIsCached = false
    private var pendingBatteryDropCandidate: BatteryDropCandidate?
    private enum ProprietaryBatteryRefreshPhase: Equatable {
        case idle
        case discoveringResponse
        case subscribingResponse
        case awaitingResponse
    }
    private var proprietaryBatteryRefreshPhase: ProprietaryBatteryRefreshPhase = .idle
    private var proprietaryBatteryResponseCharacteristic: CBCharacteristic?
    private var proprietaryBatteryRequestSequence: UInt8?
    private var proprietaryBatteryRefreshEnabledResponseNotify = false
    private var proprietaryBatteryRefreshTimeoutTask: Task<Void, Never>?
    private var recoveryReconnectAttempt = 0
    private var pendingRecoveryReconnectReason: String?
    private var pendingRecoveryIntent: AutomaticRecoveryIntent = .repairPipeline
    private var lastStalledStreamRepairAt: Date?
    private var pendingNotifyReenableUUIDs = Set<CBUUID>()
    nonisolated static let stalledStreamRepairCooldown: TimeInterval = 30
    private var scanRetryCount = 0
    private let maxScanRetries = 4
    private var forceFreshScanOnRestore = false
    private var forceFreshScanAfterDisconnect = false
    private let minimumFinishedLongWearDuration: TimeInterval = 5 * 60
    /// Perf/crash (2026-07-08 handoff #1): during continuous all-day streaming the
    /// four parallel live arrays (`session`/`rrArchive`/`sessionPointsCache`/
    /// `rrPointsCache`) grow unbounded — they reset ONLY on explicit stop or a
    /// >=90s gap, neither of which happens while the strap streams (the OOM/jetsam
    /// cause). When the live segment's SPAN reaches this cap we finalize it to disk
    /// (`persistFinishedSession` -> `store.add` upserts by id, so the full record is
    /// preserved) and segment-roll to a fresh segment. The day's contiguous segments
    /// re-cluster into one aggregate sleep/wear candidate (`sleepClusters` bridges
    /// gaps <=2h), and the next sample resumes ~1s later. 3h keeps a comfortable
    /// >=2h live tail while bounding each array to ~3h @1Hz and shrinking the
    /// per-checkpoint `snapshotSession` rescan (which also relieves the freeze).
    /// DEBUG builds may shorten it via `--atria-retention-roll-seconds N` (or the
    /// `ATRIA_RETENTION_ROLL_SECONDS` env) so the roll can be verified against a
    /// live strap without waiting 3 real hours; production is always 3h.
    private var longWearLiveSessionRetentionSpan: TimeInterval {
#if DEBUG
        if let override = Self.debugRetentionRollSecondsOverride { return override }
#endif
        return 3 * 60 * 60
    }
#if DEBUG
    private static let debugRetentionRollSecondsOverride: TimeInterval? = {
        if let raw = ProcessInfo.processInfo.environment["ATRIA_RETENTION_ROLL_SECONDS"],
           let value = TimeInterval(raw), value > 0 { return value }
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--atria-retention-roll-seconds"),
           args.indices.contains(index + 1),
           let value = TimeInterval(args[index + 1]), value > 0 { return value }
        return nil
    }()
#endif
    private var userRequestedDisconnect = false
    private var connectedAt: Date?
    // The active long-wear journal is a crash-recovery aid, not a live UI input.
    // Flush less often so incoming HR/RR traffic doesn't compete with disk work.
    private let activeJournalFlushSampleInterval = 60
    // Keep every long-wear journal younger than ActiveSessionJournal's 90s
    // freshness window, even while the app remains foregrounded for validation.
    private let activeJournalInteractiveFlushSampleInterval = 60
    private let activeJournalInteractiveFlushMinimumInterval: TimeInterval = 60
    private let activeJournalUnattendedFlushMinimumInterval: TimeInterval = 60
    private let activeJournalFreshnessFlushCeiling: TimeInterval = 75
    // Confirmed strap steps are cumulative evidence. Bound their crash-loss
    // window by both count and wall time without turning every detected step
    // into a disk write. At normal/brisk cadence the count limit wins; at slow
    // cadence or during a short final walk the time limit guarantees a trailing
    // checkpoint. Scene lifecycle edges still force an immediate flush below.
    nonisolated static let strapStepCheckpointMaximumUnpersistedSteps = 12
    nonisolated static let strapStepCheckpointMaximumAge: TimeInterval = 15
    private let activeJournalMaxAge: TimeInterval = 18 * 60 * 60
    private let activeJournalMaxSamples = 90_000
    // At reduced-detail low-battery cadence, accepted-HR gaps can legitimately
    // exceed 30s without a real dropout. Rolling a fresh liveSessionID that
    // eagerly fragments one night into many short segments, which then fail
    // sleep aggregation. Keep brief low-battery blips inside one segment; this
    // only affects segmentation and invents no samples.
    private let activeJournalSegmentGapLimit: TimeInterval = 90
    private var activeJournalDirtySamples = 0
    private var activeJournalSaveInFlight = false
    private var activeJournalPendingSave = false
    private var activeJournalPendingTimestampRefresh = false
    private var activeJournalStepCheckpointTask: Task<Void, Never>?
    private var lastActiveJournalSaveAt: Date?
    private var lastActiveJournalSavedSessionSampleCount = 0
    private var lastActiveJournalSavedRRArchiveCount = 0
    private var lastActiveJournalPersistedSampleCount = 0
    private var lastActiveJournalPersistedRRCount = 0
    private var lastActiveJournalSavedResearchAggregates = ResearchAggregates.zero
    private var activeSessionRestoreGeneration: UInt64 = 0
    private var activeSessionRestoreInFlightGeneration: UInt64?
    private var foregroundInteractiveMode = true
    private var lastInteractiveForegroundHandlingAt: Date?
    private var foregroundHighFrequencyDisplayMode = false
    private let powerThermalGovernor = PowerThermalGovernor()

    private enum CommandWriteMode: String {
        case withoutResponse = "wwr"
        case withResponse = "wr"
    }

    private nonisolated static func discoveryCharacteristics(for service: CBUUID) -> [CBUUID]? {
        switch service {
        case UUIDs.heartRateService:
            return [UUIDs.heartRateMeasure]
        case UUIDs.batteryService:
            return [UUIDs.batteryLevel, UUIDs.batteryLevelStatus]
        case UUIDs.deviceInfoService:
            return [UUIDs.manufacturerName, UUIDs.modelNumber,
                    UUIDs.firmwareRevision, UUIDs.hardwareRevision]
        case UUIDs.strapService:
            return [UUIDs.strapTX] + UUIDs.allNotify
        default:
            return nil
        }
    }

    nonisolated static func alreadyActiveProprietaryNotifications(
        _ states: [(uuid: CBUUID, isNotifying: Bool)]
    ) -> Set<CBUUID> {
        Set(states.compactMap { state in
            guard state.isNotifying, UUIDs.allNotify.contains(state.uuid) else { return nil }
            return state.uuid
        })
    }

    /// Protected long wear intentionally combines standard 2A37 heart rate with
    /// the single proprietary stream-5 R10 motion subscription. This is the
    /// production strap-only step transport; the rollback/suppression gate is
    /// evaluated before discovery and ingestion, so this helper must not add a
    /// second, contradictory research-only gate after stream 5 is already live.
    nonisolated static func shouldObservePassiveR10InProtectedStandardHR(
        characteristicUUID: CBUUID
    ) -> Bool {
        characteristicUUID == UUIDs.strapStream5
    }

    /// The complete proprietary characteristic set for protected production is
    /// deliberately small: stream 5 supplies R10 motion and TX is retained for
    /// the single leased activation command. Physical testing rejected adding
    /// the otherwise useful stream-4 battery event channel because it caused
    /// rapid reconnect churn. A latched rollback suppresses both without
    /// changing the standard 2A37 heart-rate subscription.
    nonisolated static func protectedStandardHRStrapCharacteristics(
        streamSuppressed: Bool
    ) -> [CBUUID]? {
        streamSuppressed ? nil : [UUIDs.strapStream5, UUIDs.strapTX]
    }

    /// Protected production keeps standard HR and the standard battery-level
    /// service available independently of the proprietary R10 rollback. The
    /// battery service is notification-only at the characteristic boundary;
    /// adding it here does not authorize a 2A19 read or any custom command.
    nonisolated static func protectedStandardHRServices(
        streamSuppressed: Bool
    ) -> [CBUUID] {
        var services = [UUIDs.heartRateService, UUIDs.batteryService]
        if !streamSuppressed {
            services.append(UUIDs.strapService)
        }
        return services
    }

    /// Discover only the standard percentage characteristic in protected
    /// production. Charging-state 2A1B and proprietary battery paths remain
    /// outside the stable HR + R10 transport profile.
    nonisolated static func protectedStandardHRCharacteristics(
        for service: CBUUID,
        streamSuppressed: Bool
    ) -> [CBUUID]? {
        switch service {
        case UUIDs.heartRateService:
            return [UUIDs.heartRateMeasure]
        case UUIDs.batteryService:
            return [UUIDs.batteryLevel]
        case UUIDs.strapService:
            return protectedStandardHRStrapCharacteristics(
                streamSuppressed: streamSuppressed
            )
        default:
            return nil
        }
    }

    /// Mirrors the protected discovery contract at the ingest boundary. A
    /// restored legacy proprietary notification is ignored; only production
    /// R10, or the explicitly pending one-shot battery response, can enter the
    /// decoder while standard-HR protection is active.
    nonisolated static func shouldAcceptProtectedProprietaryNotification(
        characteristicUUID: CBUUID,
        streamSuppressed: Bool,
        pendingOneShotBatteryResponse: Bool
    ) -> Bool {
        (characteristicUUID == UUIDs.strapStream5 && !streamSuppressed)
            || pendingOneShotBatteryResponse
    }

    nonisolated static func shouldQuarantineBatteryLevel(previousLevel: Int,
                                                         previousAcceptedAt: Date?,
                                                         incomingLevel: Int,
                                                         receivedAt: Date) -> Bool {
        guard previousLevel >= 0,
              (0...100).contains(incomingLevel),
              abs(previousLevel - incomingLevel) >= implausibleBatteryDropThreshold else {
            return false
        }
        return previousAcceptedAt.map { receivedAt >= $0 } ?? true
    }

    nonisolated static func batteryLevelAcceptanceDecision(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        incomingLevel: Int,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        previousIsCached: Bool = false,
        requiresFreshConfirmation: Bool = false,
        trustedCurrentConnectionNotification: Bool = false
    ) -> BatteryLevelAcceptanceDecision {
        // Physical WHOOP traces have disproven both stable repetition and a
        // nearby prior percentage as sufficient proof for a bare 0/10/100
        // 2A19 value: restoration can replay the same boundary after first
        // replaying a nearby value. Boundary truth is therefore promoted only
        // by `batteryEventAcceptanceDecision`, where SOC is independently
        // corroborated by the CRC-validated event's voltage, power state and a
        // credible trajectory. This path deliberately never ages a bare BAS
        // sentinel into truth.
        if isBatterySentinel(incomingLevel) {
            return corroboratedBatteryLevelDecision(incomingLevel: incomingLevel,
                                                     receivedAt: receivedAt,
                                                     pending: pending,
                                                     minimumSpan: .infinity)
        }

        // Production 2A19 is notification-only because explicit reads caused
        // physical disconnects. BAS notifications are change-driven, not a
        // repeated sample stream, so waiting for three identical mid-range
        // callbacks creates a permanent Pending state. One error-free callback
        // on the active current-connection subscription is sufficient for an
        // ordinary 11...99 value. Restoration sentinels remain quarantined by
        // the boundary gate above.
        if requiresFreshConfirmation,
           trustedCurrentConnectionNotification,
           !isBatterySentinel(incomingLevel) {
            return .accept
        }

        if requiresFreshConfirmation {
            return corroboratedBatteryLevelDecision(incomingLevel: incomingLevel,
                                                     receivedAt: receivedAt,
                                                     pending: pending,
                                                     minimumSpan: freshBatteryMinimumConfirmationSpan(
                                                        incomingLevel: incomingLevel
                                                     ))
        }

        // Reconnect reads are not directionally trustworthy. On physical WHOOP
        // hardware, 2A19 has alternated 10 -> 100 and 100 -> 10 around the same
        // app-switch/reconnect cycle. A cached value may be stale, but replacing
        // it instantly with the first opposite extreme causes the visible
        // low/full oscillation. Corroborate every large reconnect transition;
        // ordinary one-point discharge changes still land immediately.
        if previousIsCached {
            if previousLevel >= 0,
               abs(incomingLevel - previousLevel) >= implausibleBatteryDropThreshold {
                return corroboratedBatteryLevelDecision(incomingLevel: incomingLevel,
                                                         receivedAt: receivedAt,
                                                         pending: pending,
                                                         minimumSpan: transitionBatteryMinimumConfirmationSpan(
                                                            incomingLevel: incomingLevel
                                                         ))
            }
            return .accept
        }

        guard shouldQuarantineBatteryLevel(previousLevel: previousLevel,
                                           previousAcceptedAt: previousAcceptedAt,
                                           incomingLevel: incomingLevel,
                                           receivedAt: receivedAt) else {
            return .accept
        }

        return corroboratedBatteryLevelDecision(incomingLevel: incomingLevel,
                                                 receivedAt: receivedAt,
                                                 pending: pending,
                                                 minimumSpan: transitionBatteryMinimumConfirmationSpan(
                                                    incomingLevel: incomingLevel
                                                 ))
    }

    /// The autonomous event is stronger evidence than a bare 2A19 percentage:
    /// it arrives in a CRC-validated proprietary frame and independently carries
    /// SOC, plausible cell voltage, and a charging bit. Trust the first ordinary
    /// mid-range event after reconnect so Battery does not remain Pending for
    /// multiple eight-minute event periods. A boundary can cross the quarantine
    /// only when those independent electrical fields also agree with either an
    /// unmistakable full-cell condition or a recent gradual trajectory.
    nonisolated static func batteryEventAcceptanceDecision(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        reading: BatteryEventReading,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        previousIsCached: Bool = false,
        requiresFreshConfirmation: Bool = false,
        previousChargeStatus: BatteryChargeStatus = .levelOnly
    ) -> BatteryLevelAcceptanceDecision {
        guard isBatterySentinel(reading.level) else { return .accept }
        if batteryBoundaryEventIsIndependentlyCorroborated(
            previousLevel: previousLevel,
            previousAcceptedAt: previousAcceptedAt,
            previousChargeStatus: previousChargeStatus,
            reading: reading,
            receivedAt: receivedAt
        ) {
            return .accept
        }
        return batteryLevelAcceptanceDecision(
            previousLevel: previousLevel,
            previousAcceptedAt: previousAcceptedAt,
            incomingLevel: reading.level,
            receivedAt: receivedAt,
            pending: pending,
            previousIsCached: previousIsCached,
            requiresFreshConfirmation: requiresFreshConfirmation
        )
    }

    /// Decides whether the autonomous CRC-validated event contains enough
    /// evidence to promote an otherwise quarantined 0/10/100 percentage.
    ///
    /// The voltage thresholds are intentionally asymmetric:
    /// - 100% needs either active charging plus a near-4.2 V cell/trajectory,
    ///   or an even tighter high-voltage + recent-near-full combination after
    ///   the charger has just been removed.
    /// - 10%/0% need external power absent, low cell voltage, and a recent
    ///   accepted percentage already within five points of that boundary.
    ///
    /// Thus a restoration frame containing a syntactically valid but
    /// electrically contradictory sentinel remains quarantined forever, while
    /// the real hardware can still report its actual boundary state.
    nonisolated static func batteryBoundaryEventIsIndependentlyCorroborated(
        previousLevel: Int,
        previousAcceptedAt: Date?,
        previousChargeStatus: BatteryChargeStatus = .levelOnly,
        reading: BatteryEventReading,
        receivedAt: Date
    ) -> Bool {
        guard isBatterySentinel(reading.level),
              (3_000...4_300).contains(reading.millivolts) else { return false }

        let hasRecentPrior = previousAcceptedAt.map {
            receivedAt >= $0 &&
                receivedAt.timeIntervalSince($0) <= reconnectBatteryBaselineMaximumAge
        } ?? false

        switch reading.level {
        case 100:
            let unmistakablyFullCell = reading.millivolts >= 4_200
            let recentNearFullTrajectory = hasRecentPrior &&
                (95...100).contains(previousLevel) &&
                reading.millivolts >= 4_050
            let recentPoweredTrajectory = hasRecentPrior &&
                (previousChargeStatus == .charging || previousChargeStatus == .full) &&
                previousLevel >= 90 &&
                reading.millivolts >= 4_050
            if reading.isCharging {
                return unmistakablyFullCell || recentNearFullTrajectory || recentPoweredTrajectory
            }
            // A completed charge may clear the event's charging bit before its
            // next autonomous report. Without that bit require both a very high
            // cell voltage and an already-near-full recent trajectory; neither
            // signal alone is allowed to turn a restoration 100 into truth.
            return reading.millivolts >= 4_180 && recentNearFullTrajectory
        case 10:
            return !reading.isCharging &&
                reading.millivolts <= 3_550 &&
                hasRecentPrior &&
                (11...15).contains(previousLevel)
        case 0:
            return !reading.isCharging &&
                reading.millivolts <= 3_250 &&
                hasRecentPrior &&
                (1...5).contains(previousLevel)
        default:
            return false
        }
    }

    /// Parses a BATTERY_LEVEL event after the outer frame has passed the shared
    /// length + CRC gates in `handleProprietary`. Keeping the structural checks
    /// pure makes the production offsets independently regression-testable.
    nonisolated static func parseBatteryLevelEventFrame(_ frame: [UInt8]) -> BatteryEventReading? {
        guard frame.count > 26,
              frame[0] == 0xAA,
              frame[4] == Packet.event,
              frame[6] == 0x03 else { return nil }
        let rawSOC = Int(frame[17]) | (Int(frame[18]) << 8)
        let millivolts = Int(frame[21]) | (Int(frame[22]) << 8)
        let chargeByte = frame[26]
        guard rawSOC <= 1_000,
              (3_000...4_300).contains(millivolts),
              chargeByte <= 1 else { return nil }
        return BatteryEventReading(level: Int((Double(rawSOC) / 10).rounded()),
                                   millivolts: millivolts,
                                   isCharging: chargeByte == 1)
    }

    nonisolated static func isBatterySentinel(_ level: Int) -> Bool {
        level <= 10 || level >= 100
    }

    /// A true boundary is approached gradually. A jump from an unknown or
    /// mid-range level to 0/10/100 is not made trustworthy by repetition.
    nonisolated static func isPlausibleBatterySentinelTransition(previousLevel: Int,
                                                                 incomingLevel: Int) -> Bool {
        guard (0...100).contains(previousLevel), isBatterySentinel(incomingLevel) else {
            return false
        }
        return abs(previousLevel - incomingLevel) <= 5
    }

    /// 2A1B powered/full bits have also been physically observed while the
    /// strap was not charging. They may corroborate an already-established
    /// rising 2A19 trend, but must never originate a powered UI state alone.
    nonisolated static func acceptedBatteryChargeStatus(_ incoming: BatteryChargeStatus,
                                                        batteryLevel: Int,
                                                        hasPlausibleRiseEvidence: Bool) -> BatteryChargeStatus? {
        switch incoming {
        case .notCharging, .levelOnly:
            return incoming
        case .charging:
            return hasPlausibleRiseEvidence ? .charging : nil
        case .full:
            return batteryLevel == 100 && hasPlausibleRiseEvidence ? .full : nil
        }
    }

    /// Percentage-only 2A19 changes cannot originate powered state. A decline
    /// proves discharge, while a small rise may be quantization or correction;
    /// Charging requires the independent CRC-validated power event.
    nonisolated static func chargeEvidenceFromBatteryLevelChange(previousLevel: Int,
                                                                  newLevel: Int) -> BatteryChargeStatus? {
        guard previousLevel >= 0 else { return newLevel >= 100 ? .full : nil }
        if newLevel >= 100 { return .full }
        return newLevel < previousLevel ? .notCharging : nil
    }

    private nonisolated static func corroboratedBatteryLevelDecision(
        incomingLevel: Int,
        receivedAt: Date,
        pending: BatteryDropCandidate?,
        minimumSpan: TimeInterval = implausibleBatteryDropMinimumConfirmationSpan
    ) -> BatteryLevelAcceptanceDecision {
        // Boundary readings deliberately need a much longer stability window
        // than ordinary large transitions. Keep that candidate alive long
        // enough to satisfy its own gate; otherwise a true 0/10/100% series
        // resets at five minutes and can never become accepted at fifteen.
        let candidateMaxAge = max(
            implausibleBatteryDropCandidateMaxAge,
            minimumSpan + (2 * batteryConfirmationRetryDelay(incomingLevel: incomingLevel))
        )
        let candidate: BatteryDropCandidate
        if let pending,
           abs(pending.level - incomingLevel) <= 2,
           receivedAt >= pending.lastSeenAt,
           receivedAt.timeIntervalSince(pending.firstSeenAt) <= candidateMaxAge {
            candidate = BatteryDropCandidate(level: incomingLevel,
                                             firstSeenAt: pending.firstSeenAt,
                                             lastSeenAt: receivedAt,
                                             confirmations: pending.confirmations + 1)
        } else {
            candidate = BatteryDropCandidate(level: incomingLevel,
                                             firstSeenAt: receivedAt,
                                             lastSeenAt: receivedAt,
                                             confirmations: 1)
        }

        let span = candidate.lastSeenAt.timeIntervalSince(candidate.firstSeenAt)
        if candidate.confirmations >= implausibleBatteryDropRequiredConfirmations,
           span >= minimumSpan {
            return .accept
        }
        return .quarantine(candidate)
    }

    /// WHOOP 2A19 has physically replayed boundary-like 0, 10, and 100 values
    /// during restoration before settling to the real mid-range level. These
    /// values can also be legitimate, so do not discard them; require a much
    /// longer stable series before presenting them as current device truth.
    nonisolated static func freshBatteryMinimumConfirmationSpan(incomingLevel: Int) -> TimeInterval {
        (incomingLevel <= 10 || incomingLevel >= 100)
            ? freshBoundaryBatteryConfirmationMinimumSpan
            : freshBatteryConfirmationMinimumSpan
    }

    /// Restoration sentinels are not limited to first launch. Physical traces
    /// have shown a credible mid-range value followed by repeated 0/10/100
    /// reads on the same live link. A true transition into those boundaries is
    /// slow in normal use, so a large jump to one uses the extended gate too.
    nonisolated static func transitionBatteryMinimumConfirmationSpan(incomingLevel: Int) -> TimeInterval {
        (incomingLevel <= 10 || incomingLevel >= 100)
            ? freshBoundaryBatteryConfirmationMinimumSpan
            : implausibleBatteryDropMinimumConfirmationSpan
    }

    nonisolated static func shouldRequestBatteryRefresh(lastRequestedAt: Date?,
                                                        now: Date,
                                                        interval: TimeInterval = batteryRefreshInterval) -> Bool {
        guard let lastRequestedAt else { return true }
        return now >= lastRequestedAt && now.timeIntervalSince(lastRequestedAt) >= interval
    }

    /// A proprietary battery query is allowed only after the already-proven R10
    /// transport has remained dense and fresh on this connection, then survived
    /// an additional quiet grace. The command pipe remains entirely untouched
    /// during workouts, history work, cooldown, or an open failure circuit.
    nonisolated static func shouldRequestProprietaryBatteryRefresh(
        standardHROnlyMode: Bool,
        stableTransportProven: Bool,
        connected: Bool,
        currentConnectionR10Frames: Int,
        lastR10FrameAt: Date?,
        transportQualifiedAt: Date?,
        batteryIsFresh: Bool,
        activeWorkout: Bool,
        historyActive: Bool,
        requestPending: Bool,
        lastAttemptAt: Date?,
        circuitOpenUntil: Date?,
        now: Date,
        successCooldown: TimeInterval = proprietaryBatteryRefreshCooldown,
        qualificationGrace: TimeInterval = proprietaryBatteryPostQualificationGrace
    ) -> Bool {
        guard standardHROnlyMode,
              stableTransportProven,
              connected,
              currentConnectionR10Frames >= 75,
              let lastR10FrameAt,
              now >= lastR10FrameAt,
              now.timeIntervalSince(lastR10FrameAt) <= 5,
              let transportQualifiedAt,
              now >= transportQualifiedAt,
              now.timeIntervalSince(transportQualifiedAt) >= qualificationGrace,
              !batteryIsFresh,
              !activeWorkout,
              !historyActive,
              !requestPending else { return false }
        if let circuitOpenUntil, now < circuitOpenUntil { return false }
        if let lastAttemptAt {
            guard now >= lastAttemptAt,
                  now.timeIntervalSince(lastAttemptAt) >= successCooldown else { return false }
        }
        return true
    }

    /// COMMAND_RESPONSE layout observed for GET_BATTERY_LEVEL:
    /// [0x24, sequence, 0x1A, 0x0A, 0x01, SOC-low, SOC-high, ...].
    /// SOC is tenths of one percent. Reject every unexpected status, sequence,
    /// or range instead of projecting a sentinel or unrelated response.
    nonisolated static func parseProprietaryBatteryResponse(
        _ payload: [UInt8],
        expectedSequence: UInt8
    ) -> Int? {
        guard payload.count >= 7,
              payload[0] == 0x24,
              payload[1] == expectedSequence,
              payload[2] == Cmd.getBatteryLevel,
              payload[3] == 0x0A,
              payload[4] == 0x01 else { return nil }
        let rawSOC = Int(payload[5]) | (Int(payload[6]) << 8)
        guard rawSOC <= 1_000 else { return nil }
        return Int((Double(rawSOC) / 10).rounded())
    }

    enum StandardBatteryRefreshAction: Equatable {
        case read
        case subscribe
        case awaitNotification
        case unavailable
    }

    /// Physical A/B evidence on 2026-07-13 showed explicit 2A19 reads repeatedly
    /// disconnect this strap. Production therefore subscribes once and waits
    /// for spontaneous standard notifications. Explicit reads remain available
    /// only to an isolated research caller and are never automatic.
    nonisolated static func standardBatteryRefreshAction(canRead: Bool,
                                                          canNotify: Bool,
                                                          isNotifying: Bool,
                                                          explicitReadResearchEnabled: Bool = false) -> StandardBatteryRefreshAction {
        if canNotify && isNotifying { return .awaitNotification }
        if canNotify && !isNotifying { return .subscribe }
        if canRead && explicitReadResearchEnabled { return .read }
        return .unavailable
    }

    nonisolated static func batteryLevelIsFresh(lastAcceptedAt: Date?,
                                                now: Date,
                                                maxAge: TimeInterval = batteryDisplayFreshnessLimit) -> Bool {
        guard let lastAcceptedAt, now >= lastAcceptedAt else { return false }
        return now.timeIntervalSince(lastAcceptedAt) <= maxAge
    }

    /// CoreBluetooth may briefly restore the connected peripheral before its
    /// cached 2A19 characteristic is reattached to this manager. Preserve a
    /// previously accepted mid-range value only for the bounded lifetime of a
    /// lease created in this same process/connection epoch. Launch hydration
    /// clears old leases before setting `requiresFreshConfirmation`.
    nonisolated static func notificationLeaseSupportsBatteryDisplay(
        level: Int,
        source: String,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        notificationLeaseAt: Date?,
        now: Date,
        maximumAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard (11...99).contains(level),
              source == "live_2A19",
              !requiresFreshConfirmation,
              linkConnected,
              let notificationLeaseAt,
              now >= notificationLeaseAt else { return false }
        return now.timeIntervalSince(notificationLeaseAt) <= maximumAge
    }

    /// CoreBluetooth can replace the restored `CBCharacteristic` instance even
    /// after it has reported a successful CCCD subscription. Treat that object
    /// flag as a convenience, not the sole durable proof: a confirmation from
    /// this connection epoch remains authoritative until an inactive/error
    /// callback removes it and records an error.
    nonisolated static func batteryNotificationConfirmationSupportsCurrentConnection(
        confirmedAt: Date?,
        lastError: String?,
        connectionStartedAt: Date?,
        linkConnected: Bool,
        now: Date,
        restoredConfirmationMaximumAge: TimeInterval = batteryRestoredNotificationConfirmationMaximumAge
    ) -> Bool {
        guard linkConnected,
              lastError == nil,
              let confirmedAt,
              confirmedAt <= now else { return false }
        if let connectionStartedAt {
            // `didConnect` proves a genuinely new link epoch. Its subscription
            // must be confirmed again; never inherit the old link's CCCD proof.
            return confirmedAt >= connectionStartedAt
        }
        // State restoration can resume the exact connected peripheral without
        // calling didConnect in this process. Keep the bounded persisted CCCD
        // confirmation for that path; current HR + connected link are required
        // separately by the promotion gate.
        return now.timeIntervalSince(confirmedAt) <= restoredConfirmationMaximumAge
    }

    nonisolated static func batteryRestorationPreservesNotificationEpoch(
        restoredPeripheralIdentifier: UUID,
        savedPeripheralIdentifier: UUID?,
        restoredPeripheralIsConnected: Bool
    ) -> Bool {
        restoredPeripheralIsConnected
            && savedPeripheralIdentifier == restoredPeripheralIdentifier
    }

    private func batteryNotificationTransportIsActive(
        now: Date,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let linkConnected = peripheral?.state == .connected && status == .connected
        guard linkConnected else { return false }
        if batteryLevelCharacteristic?.isNotifying == true { return true }
        return Self.batteryNotificationConfirmationSupportsCurrentConnection(
            confirmedAt: (defaults.object(forKey: BatteryDefaults.notificationConfirmedAt) as? Double)
                .map(Date.init(timeIntervalSince1970:)),
            lastError: defaults.string(forKey: BatteryDefaults.notificationLastError),
            connectionStartedAt: batteryConnectionRestoredSamePeripheral ? nil : connectedAt,
            linkConnected: linkConnected,
            now: now
        )
    }

    /// A genuine reconnect may not receive a 2A19 callback until the integer
    /// percentage changes. Keep a recent, already-validated mid-range baseline
    /// visible as *Recent* when live HR proves the same saved strap is currently
    /// connected. This is display-only evidence: callers must not clear
    /// `requiresFreshConfirmation`, renew a live lease, or schedule battery
    /// alerts from it. A disputed/rejected callback belongs to the *new*
    /// notification epoch; it must block promotion, but it must not erase the
    /// separately accepted baseline. Keeping that baseline visible as Recent
    /// avoids a permanent Pending UI while a false restoration sentinel is
    /// quarantined.
    nonisolated static func recentReconnectBatteryBaselineIsDisplayEligible(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        currentConnectionHasHeartRate: Bool,
        hasPendingDisputedReading: Bool,
        currentNotificationEpochHadRejectedCallback: Bool,
        now: Date,
        maximumAge: TimeInterval = reconnectBatteryBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              currentConnectionHasHeartRate,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now else { return false }
        _ = hasPendingDisputedReading
        _ = currentNotificationEpochHadRejectedCallback
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// Launch hydration must not turn a fresh, already-validated percentage
    /// into an indefinite Pending state merely because the change-driven 2A19
    /// characteristic has not emitted the same integer again. This narrower
    /// gate is only for the first minutes after acceptance: it requires the
    /// same connected strap, a non-boundary value, and provenance from a live
    /// level-bearing packet. It is display-only and never clears the fresh-
    /// confirmation flag or renews a notification lease.
    nonisolated static func freshConnectedCachedBatteryBaselineIsDisplayEligible(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        now: Date,
        maximumAge: TimeInterval = batteryDisplayFreshnessLimit
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// Keep an already-validated mid-range baseline in memory while a freshly
    /// connected strap is proving its HR + 2A19 notification paths. The
    /// foreground keepalive can tick before the first HR packet; clearing the
    /// value during that short race makes later promotion impossible and leaves
    /// the UI on `Battery pending` until the percentage changes. This is a
    /// retention gate only: it does not make the value displayable, refresh its
    /// timestamp, or authorize battery alerts.
    nonisolated static func reconnectBatteryBaselineIsAwaitingProof(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        linkConnected: Bool,
        sameSavedPeripheral: Bool,
        validationStartedAt: Date,
        now: Date,
        proofGrace: TimeInterval = 90,
        maximumAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              linkConnected,
              sameSavedPeripheral,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              acceptedAt <= now,
              validationStartedAt <= now else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
            && now.timeIntervalSince(validationStartedAt) <= proofGrace
    }

    private func freshConnectedCachedBatteryBaselineIsDisplayable(
        now: Date,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let linkConnected = peripheral?.state == .connected && status == .connected
        let savedPeripheralIdentifier = defaults
            .string(forKey: LinkDefaults.savedPeripheralUUID)
            .flatMap(UUID.init(uuidString:))
        return Self.freshConnectedCachedBatteryBaselineIsDisplayEligible(
            level: batteryLevel,
            acceptedAt: lastAcceptedBatteryLevelAt,
            source: defaults.string(forKey: BatteryDefaults.source) ?? "none",
            displayedIsCached: displayedBatteryLevelIsCached,
            requiresFreshConfirmation: defaults.bool(
                forKey: BatteryDefaults.requiresFreshConfirmation
            ),
            linkConnected: linkConnected,
            sameSavedPeripheral: peripheral?.identifier == savedPeripheralIdentifier,
            now: now
        )
    }

    private func recentReconnectBatteryBaselineIsDisplayable(
        now: Date,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let linkConnected = peripheral?.state == .connected && status == .connected
        let savedPeripheralIdentifier = defaults
            .string(forKey: LinkDefaults.savedPeripheralUUID)
            .flatMap(UUID.init(uuidString:))
        let sameSavedPeripheral = peripheral?.identifier == savedPeripheralIdentifier
        let connectionStartedAt = connectedAt ?? batteryBaselineValidationStartedAt
        let currentConnectionHasHeartRate = lastRawHRNotificationAt.map {
            $0 >= connectionStartedAt
        } ?? false
        return Self.recentReconnectBatteryBaselineIsDisplayEligible(
            level: batteryLevel,
            acceptedAt: lastAcceptedBatteryLevelAt,
            source: defaults.string(forKey: BatteryDefaults.source) ?? "none",
            displayedIsCached: displayedBatteryLevelIsCached,
            requiresFreshConfirmation: defaults.bool(
                forKey: BatteryDefaults.requiresFreshConfirmation
            ),
            linkConnected: linkConnected,
            sameSavedPeripheral: sameSavedPeripheral,
            currentConnectionHasHeartRate: currentConnectionHasHeartRate,
            hasPendingDisputedReading: pendingBatteryDropCandidate != nil,
            currentNotificationEpochHadRejectedCallback:
                batteryNotificationEpochHadRejectedCallback,
            now: now
        )
    }

    /// Single projection gate for every UI/notification consumer. A raw
    /// in-memory percentage is not display truth after its independent 2A19
    /// evidence expires, even if HR continues on another characteristic.
    func displayableBatteryLevel(now: Date = Date()) -> Int? {
        let defaults = UserDefaults.standard
        let requiresFreshConfirmation = defaults.bool(
            forKey: BatteryDefaults.requiresFreshConfirmation
        )
        let activeAcceptedNotification = batteryNotificationTransportIsActive(
            now: now,
            defaults: defaults
        )
            && !displayedBatteryLevelIsCached
        let restoredNotificationLease = Self.notificationLeaseSupportsBatteryDisplay(
            level: batteryLevel,
            source: defaults.string(forKey: BatteryDefaults.source) ?? "none",
            requiresFreshConfirmation: requiresFreshConfirmation,
            linkConnected: peripheral?.state == .connected && status == .connected,
            notificationLeaseAt: (defaults.object(forKey: BatteryDefaults.notificationLeaseAt) as? Double)
                .map(Date.init(timeIntervalSince1970:)),
            now: now
        )
        let recentReconnectBaseline = recentReconnectBatteryBaselineIsDisplayable(
            now: now,
            defaults: defaults
        )
        let freshConnectedCachedBaseline = freshConnectedCachedBatteryBaselineIsDisplayable(
            now: now,
            defaults: defaults
        )
        guard (0...100).contains(batteryLevel) else { return nil }
        if recentReconnectBaseline { return batteryLevel }
        if freshConnectedCachedBaseline { return batteryLevel }
        guard !requiresFreshConfirmation,
              (Self.batteryLevelIsFresh(lastAcceptedAt: lastAcceptedBatteryLevelAt,
                                        now: now)
                || activeAcceptedNotification
                || restoredNotificationLease) else { return nil }
        return batteryLevel
    }

    /// Timestamp for the level-bearing packet behind the current display
    /// projection. UI callers use this only to age an explicitly Recent value;
    /// it is not a substitute for current charge-state evidence.
    var lastVerifiedBatteryLevelAt: Date? {
        lastAcceptedBatteryLevelAt
    }

    nonisolated static func reconnectBatteryDisplayLevel(currentLevel: Int,
                                                         credibleLevel: Int?,
                                                         credibleAt: Date?,
                                                         now: Date,
                                                         maxAge: TimeInterval = batteryDisplayFreshnessLimit) -> Int {
        guard isBatterySentinel(currentLevel) else { return currentLevel }
        guard let credibleLevel,
              let credibleAt,
              !isBatterySentinel(credibleLevel),
              batteryLevelIsFresh(lastAcceptedAt: credibleAt, now: now, maxAge: maxAge) else {
            return -1
        }
        return credibleLevel
    }

    /// Standard Battery Service notifications are change-driven. Requiring a
    /// second value packet after every reconnect can therefore leave a correct
    /// mid-range percentage stuck on Pending forever when the level has not
    /// changed. Promote the recent credible baseline only after this exact
    /// connection has delivered live HR and CoreBluetooth confirms the 2A19
    /// notification remains active. Restoration sentinels and unknown sources
    /// can never cross this boundary.
    nonisolated static func shouldPromoteReconnectBatteryBaseline(
        level: Int,
        acceptedAt: Date?,
        source: String,
        displayedIsCached: Bool,
        requiresFreshConfirmation: Bool,
        notificationActive: Bool,
        linkConnected: Bool,
        currentConnectionHasHeartRate: Bool,
        hasPendingDisputedReading: Bool = false,
        currentNotificationEpochHadRejectedCallback: Bool = false,
        now: Date,
        maximumAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge
    ) -> Bool {
        guard displayedIsCached,
              requiresFreshConfirmation,
              notificationActive,
              linkConnected,
              currentConnectionHasHeartRate,
              !hasPendingDisputedReading,
              !currentNotificationEpochHadRejectedCallback,
              (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              let acceptedAt,
              now >= acceptedAt else { return false }
        return now.timeIntervalSince(acceptedAt) <= maximumAge
    }

    /// A current standard Battery Service subscription may carry forward only
    /// a recent percentage that already came from a level-bearing, validated
    /// live source. The autonomous battery event is stronger than bare 2A19
    /// (CRC + SOC + cell voltage), so excluding it left an otherwise truthful
    /// mid-range value stuck on Pending after reconnect until the next event.
    /// The retired one-shot proprietary command remains excluded because its
    /// transport can interrupt R10 and is disabled in production.
    nonisolated static func batteryReconnectBaselineSourceIsLeaseEligible(
        _ source: String
    ) -> Bool {
        source == "live_2A19" || source == "live_battery_event"
    }

    nonisolated static func batteryConfirmationRetryDelay(incomingLevel: Int) -> TimeInterval {
        incomingLevel <= 10 || incomingLevel >= 100 ? 30 : 6
    }

    nonisolated static func parseBatteryLevel(_ data: Data) -> Int? {
        guard data.count == 1, let byte = data.first, byte <= 100 else { return nil }
        return Int(byte)
    }

    private nonisolated static func parseBatteryChargeStatus(_ data: Data) -> BatteryChargeStatus? {
        let bytes = [UInt8](data)
        guard let powerState = batteryPowerStateByte(fromBatteryLevelStatus: bytes) else { return nil }
        let wiredExternalPower = (powerState >> 2) & 0x03
        let wirelessExternalPower = (powerState >> 4) & 0x03
        let chargeState = (powerState >> 6) & 0x03
        if chargeState == 0x03 { return .charging }
        if chargeState == 0x02 { return .notCharging }
        if wiredExternalPower == 0x03 || wirelessExternalPower == 0x03 { return .charging }
        if wiredExternalPower == 0x02 && wirelessExternalPower == 0x02 { return .notCharging }
        return nil
    }

    private nonisolated static func batteryPowerStateByte(fromBatteryLevelStatus bytes: [UInt8]) -> UInt8? {
        guard let flags = bytes.first else { return nil }
        if bytes.count >= 3 { return bytes[2] }
        if bytes.count == 2, flags & 0x01 == 0 { return bytes[1] }
        return nil
    }

    private struct HistoryClockRef {
        let device: UInt32
        let wall: UInt32
        var driftSeconds: Int { Int(wall) - Int(device) }
        var snappedDriftSeconds: Int {
            let drift = driftSeconds
            guard abs(drift) >= 86_400 else { return drift }
            let granularity = 300
            if drift >= 0 {
                return ((drift + granularity / 2) / granularity) * granularity
            }
            return ((drift - granularity / 2) / granularity) * granularity
        }
    }

    override init() {
        let arguments = ProcessInfo.processInfo.arguments
#if DEBUG
        let fixtureIndex = arguments.firstIndex(of: "--atria-ui-fixture")
        let fixtureValue = fixtureIndex.flatMap { index -> String? in
            let next = arguments.index(after: index)
            guard arguments.indices.contains(next) else { return nil }
            return arguments[next]
        }
        debugForceUnknownStrapGeneration = fixtureValue == "unknown-strap-generation"
#else
        debugForceUnknownStrapGeneration = false
#endif
        super.init()
        strapStepCalibrationCaptureUntil = AtriaStrapCalibrationArchive.configuredCaptureUntil(
            arguments: arguments
        )
        if let strapStepCalibrationCaptureUntil {
            AtriaDebugLog("ATRIADBG strap_step_calibration status=enabled until_utc=%@ source=existing_protected_r10 transport_mutations=0",
                          ISO8601DateFormatter().string(from: strapStepCalibrationCaptureUntil))
        }
        let defaults = UserDefaults.standard
        lastHRVAnalysisAt = defaults.object(
            forKey: HRVCadenceDefaults.lastReadyAnalysisAt
        ) as? Date
        lastNormalWearHRVAnalysisAttemptAt = Self.readNormalWearHRVAnalysisAttemptDate(
            userDefaults: defaults
        )
        if let cachedSnapshot = Self.decodedReadyHRVSnapshot(
            defaults.data(forKey: HRVCadenceDefaults.readySnapshot),
            now: Date()
        ) {
            latestReadyHRVSnapshot = cachedSnapshot
            hrvSnapshot = cachedSnapshot
            hrv = Int(cachedSnapshot.rmssd.rounded())
            hrvQuality = cachedSnapshot.readinessMessage
            lastHRVAnalysisAt = max(lastHRVAnalysisAt ?? .distantPast,
                                    cachedSnapshot.analyzedAt)
        } else {
            defaults.removeObject(forKey: HRVCadenceDefaults.readySnapshot)
        }
#if DEBUG
        if debugForceUnknownStrapGeneration {
            strapModel = .unknown
            researchProbeGenerationGate = AtriaResearchProbe.GenerationGate()
            AtriaDebugLog("ATRIADBG strap_generation_fixture status=forced_unknown source=ui_fixture action=show_early_support_banner")
        }
#endif
        if arguments.contains("--atria-reset-capture-defaults") {
            resetProductionCaptureDefaultsForDebug()
        }
        if arguments.contains("--atria-full-protocol-mode") {
            UserDefaults.standard.set(false, forKey: LongWearDefaults.enabled)
            UserDefaults.standard.set(false, forKey: RadioDefaults.standardHROnly)
            longWearModeEnabled = false
            standardHROnlyMode = false
            standardHROnlyEnabled = false
            forceFreshScanOnRestore = true
        } else {
            bootstrapProductionCaptureDefaultsIfNeeded(arguments: arguments)
            migrateAutomaticLongWearDefaultIfNeeded(arguments: arguments)
            if Self.migrateAlwaysOnLongWearIfNeeded(defaults: defaults,
                                                    arguments: arguments) {
                longWearModeEnabled = true
                updateSessionPointCacheMode()
                AtriaDebugLog("ATRIADBG long_wear_mode status=migrated_always_on action=enabled reason=orphaned_legacy_toggle")
            }
            migrateStableR10TransportDefaultIfNeeded(arguments: arguments)
            migrateOfflineSyncDefaultIfNeeded(arguments: arguments)
            migrateProtectedR10HistoryInterlockIfNeeded()
            if Self.migrateProtectedR10PassiveRetryIfNeeded() {
                AtriaDebugLog("ATRIADBG protected_r10 status=migrated_retry_policy action=clear_permanent_failure_keep_stream_fuse")
            }
            migrateFailedProprietaryBatteryRefreshIfNeeded()
            isolateRecentProtectedR10DisconnectStormIfNeeded()
            _ = expireProtectedR10PassiveReprobeIfNeeded(
                now: Date(),
                reason: "launch_stale_pending"
            )
            if arguments.contains("--atria-long-wear-mode") {
                UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
                UserDefaults.standard.set(true, forKey: LongWearDefaults.userSelected)
                UserDefaults.standard.set(true, forKey: LongWearDefaults.enabled)
                longWearModeEnabled = true
            }
        }
        if !arguments.contains("--atria-full-protocol-mode"),
           strapStepCalibrationCaptureUntil == nil,
           arguments.contains("--atria-standard-hr-only") || arguments.contains("--atria-long-wear-mode") {
            standardHROnlyMode = true
            standardHROnlyEnabled = true
            forceFreshScanOnRestore = true
        }
        if !arguments.contains("--atria-full-protocol-mode"),
           !arguments.contains("--atria-standard-hr-only"),
           !arguments.contains("--atria-long-wear-mode"),
           strapStepCalibrationCaptureUntil == nil {
            // The protected mode is not HR-only: it keeps 2A37 plus the
            // stream-5 R10 motion transport used by strap-native steps while
            // omitting the broader proprietary profile that failed physical
            // stability A/B testing.
            let storedMode = standardHROnlyMode
            let resolvedMode = Self.shouldUseStandardHROnlyAtNormalLaunch(
                userSelectedBatterySaver: defaults.bool(
                    forKey: RadioDefaults.standardHROnlyUserSelected
                ),
                persistedStandardHROnly: defaults.bool(
                    forKey: RadioDefaults.standardHROnly
                )
            )
            defaults.set(resolvedMode, forKey: RadioDefaults.standardHROnly)
            standardHROnlyMode = resolvedMode
            standardHROnlyEnabled = resolvedMode
            if storedMode != resolvedMode {
                forceFreshScanOnRestore = true
            }
            recordRadioMode(resolvedMode ? "protected_r10_minimal" : "full_protocol",
                            reason: resolvedMode
                                ? "stable_hr_r10_launch"
                                : "explicit_full_protocol_launch")
        }
        if let diagnostic = motionHandshakeDiagnostic {
            // This is an isolated transport experiment, not a persisted radio
            // preference. Normal long-wear supervisors, offline recovery and
            // production characteristic discovery must remain out of the run.
            longWearModeEnabled = false
            standardHROnlyMode = false
            standardHROnlyEnabled = false
            forceFreshScanOnRestore = false
            let now = Date().timeIntervalSince1970
            defaults.set(diagnostic.runID, forKey: "atria.motionHandshake.runID")
            defaults.set("configured", forKey: "atria.motionHandshake.status")
            defaults.set(now, forKey: "atria.motionHandshake.configuredAt")
            defaults.set(diagnostic.addHRDelay, forKey: "atria.motionHandshake.addHRDelay")
            defaults.set(diagnostic.sendSingleR10Activation,
                         forKey: "atria.motionHandshake.singleR10ActivationConsented")
            defaults.set(diagnostic.restoreIdentifier, forKey: "atria.motionHandshake.restoreIdentifier")
            AtriaDebugLog("ATRIADBG motion_handshake status=configured run=%@ restore=%@ add_hr_after_s=%.1f single_3f01=%d isolation=stream5_then_hr_no_other_tx_no_offline_no_battery",
                          diagnostic.runID,
                          diagnostic.restoreIdentifier,
                          diagnostic.addHRDelay,
                          diagnostic.sendSingleR10Activation ? 1 : 0)
        }
        applyEarlyHistoricalLaunchConfiguration(arguments: arguments)
        if motionHandshakeDiagnostic == nil {
            scheduleStaleArmedRangeLossBackfillReconciliation(reason: "ble_manager_init")
        }
        hydrateCachedBatteryStateIfFresh()
        updateSessionPointCacheMode()
        logActiveMotionIMUCheckPlanIfRequested(arguments: arguments)
        powerThermalGovernor.onChange = { [weak self] mode in
            guard let self else { return }
            AtriaDebugLog("ATRIADBG power_thermal_governor mode=%@ multiplier=%.1f low_power=%d thermal=%@",
                  mode.rawValue,
                  self.effectiveThermalCadenceMultiplier,
                  ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
                  Self.thermalStateLabel(ProcessInfo.processInfo.thermalState))
            if mode == .nominal || mode == .fair {
                self.scheduleStaleArmedRangeLossBackfillReconciliation(reason: "thermal_pressure_recovered")
            }
        }
        if motionHandshakeDiagnostic == nil {
            legacyCentralCleaners = [
                AtriaLegacyBLECentralCleaner(restoreIdentifier: "com.adidshaft.atria.ble-central"),
                AtriaLegacyBLECentralCleaner(restoreIdentifier: "com.adidshaft.atria.ble-central-v2"),
                AtriaLegacyBLECentralCleaner(restoreIdentifier: "com.adidshaft.atria.ble-central-v3"),
            ]
        }
        central = CBCentralManager(delegate: self,
                                   queue: centralQueue,
                                   options: [
                                       CBCentralManagerOptionRestoreIdentifierKey: centralRestoreIdentifier,
                                       CBCentralManagerOptionShowPowerAlertKey: true
        ])
        scheduleProtectedR10PassiveReprobeTimeout()
    }

    private func applyEarlyHistoricalLaunchConfiguration(arguments: [String]) {
        if arguments.contains("--atria-disable-history-ack") {
            historicalAckDisabled = true
        }
        if let modeIndex = arguments.firstIndex(of: "--atria-history-ack-mode"),
           arguments.indices.contains(arguments.index(after: modeIndex)) {
            let mode = arguments[arguments.index(after: modeIndex)]
            let supportedModes = ["trim", "enddata", "index", "unix", "zero", "none"]
            if supportedModes.contains(mode) {
                historyAckMode = mode
            }
        }
        if arguments.contains("--atria-history-clock-handshake") || arguments.contains("--atria-history-clock-sync") {
            historyClockSyncEnabled = true
        }
        if arguments.contains("--atria-history-skip-range") {
            historySkipDataRangeRequest = true
        }
        if let initIndex = arguments.firstIndex(of: "--atria-history-init-sweep"),
           arguments.indices.contains(arguments.index(after: initIndex)) {
            historyInitSweepCommands = arguments[arguments.index(after: initIndex)]
                .split(separator: ",")
                .compactMap { Self.parseHexBytes(String($0)) }
                .filter { !$0.isEmpty }
        }
        if let modeIndex = arguments.firstIndex(of: "--atria-probe-command-mode"),
           arguments.indices.contains(arguments.index(after: modeIndex)) {
            let mode = arguments[arguments.index(after: modeIndex)]
            if mode == CommandWriteMode.withResponse.rawValue {
                probeCommandMode = .withResponse
            } else if mode == CommandWriteMode.withoutResponse.rawValue {
                probeCommandMode = .withoutResponse
            }
        }
        guard arguments.contains("--atria-history-only-probe") else { return }
        historyOnlyProbeEnabled = true
        historyOnlyProbeMode = true
        realtimeStartRetries = 0
        AtriaDebugLog("ATRIADBG realtimeConfig history_only_probe=1 phase=early realtime_start=skipped cmd22=%d init_sweep=%d mode=%@",
              historySkipDataRangeRequest ? 0 : 1,
              historyInitSweepCommands.isEmpty ? 0 : 1,
              probeCommandMode.rawValue)
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    private func hydrateCachedBatteryStateIfFresh(
        maxAge: TimeInterval = activeBatterySubscriptionBaselineMaximumAge
    ) {
        recentReconnectBatteryBaselineProjectionPublished = false
        batteryBaselineValidationStartedAt = Date()
        let invalidated = Self.invalidateImplausibleCachedBatteryTransitionIfNeeded() ||
            Self.invalidateUnverifiedCachedBatterySentinelIfNeeded()
        if invalidated {
            WidgetSnapshotPublisher.invalidateBatteryProjection()
            LocalNotificationScheduler.invalidateDisputedBatterySideEffects(
                reason: "launch_disputed_battery_transition"
            )
        }
        let defaults = UserDefaults.standard
        // `requiresFreshConfirmation` survives a relaunch by design. It must
        // block the persisted percentage from becoming fresh/live truth, but
        // it must not prevent hydration from retaining a previously accepted
        // mid-range value as an explicitly aged reconnect baseline. Otherwise
        // every launch turns a truthful 18% into "Battery pending" until the
        // change-driven 2A19 characteristic happens to emit a new integer.
        let cached = Self.cachedBattery(
            maxAge: maxAge,
            permitPendingReconnectBaseline: true
        )
        // A notification lease belongs to the process/connection epoch that
        // created it. It may help select a comparison baseline above, but it
        // must be revoked before this launch marks that baseline pending.
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        if cached.usable, !Self.isBatterySentinel(cached.level) {
            // Preserve a recent credible mid-range value while fresh live reads
            // are being corroborated. It is explicitly marked cached and never
            // refreshes its timestamp, so normal freshness rules still expire it.
            batteryLevel = cached.level
            displayedBatteryLevelIsCached = true
            batteryReadingIsRecentBaseline = true
            let acceptedAt = defaults.object(forKey: BatteryDefaults.at) as? Double
            lastAcceptedBatteryLevelAt = acceptedAt.map(Date.init(timeIntervalSince1970:))
            defaults.set(cached.level, forKey: BatteryDefaults.credibleLevel)
            if let acceptedAt { defaults.set(acceptedAt, forKey: BatteryDefaults.credibleAt) }
        } else if let credible = defaults.object(forKey: BatteryDefaults.credibleLevel) as? Int,
                  let credibleAt = defaults.object(forKey: BatteryDefaults.credibleAt) as? Double,
                  !Self.isBatterySentinel(credible),
                  Date().timeIntervalSince1970 - credibleAt >= 0,
                  Date().timeIntervalSince1970 - credibleAt <= maxAge {
            batteryLevel = credible
            displayedBatteryLevelIsCached = true
            batteryReadingIsRecentBaseline = true
            lastAcceptedBatteryLevelAt = Date(timeIntervalSince1970: credibleAt)
        } else {
            batteryLevel = -1
            displayedBatteryLevelIsCached = false
            batteryReadingIsRecentBaseline = false
            lastAcceptedBatteryLevelAt = nil
        }
        // A persisted percentage is useful only as a comparison baseline. It
        // must not remain visible in widgets while the new connection is still
        // proving a fresh level-bearing packet series.
        WidgetSnapshotPublisher.invalidateBatteryProjection()
        batteryChargeStatus = .levelOnly
        batteryIsCharging = false
        batteryRecentlyDropping = false
    }

    private func promoteReconnectBatteryBaselineIfSafe(
        now: Date,
        heartRateReceivedAt: Date,
        reason: String
    ) {
        let defaults = UserDefaults.standard
        let connectionStartedAt = connectedAt ?? batteryBaselineValidationStartedAt
        let currentConnectionHasHeartRate = heartRateReceivedAt >= connectionStartedAt
        let notificationTransportActive = batteryNotificationTransportIsActive(
            now: now,
            defaults: defaults
        )
        guard Self.shouldPromoteReconnectBatteryBaseline(
            level: batteryLevel,
            acceptedAt: lastAcceptedBatteryLevelAt,
            source: defaults.string(forKey: BatteryDefaults.source) ?? "none",
            displayedIsCached: displayedBatteryLevelIsCached,
            requiresFreshConfirmation: defaults.bool(forKey: BatteryDefaults.requiresFreshConfirmation),
            notificationActive: notificationTransportActive,
            linkConnected: peripheral?.state == .connected && status == .connected,
            currentConnectionHasHeartRate: currentConnectionHasHeartRate,
            hasPendingDisputedReading: pendingBatteryDropCandidate != nil,
            currentNotificationEpochHadRejectedCallback: batteryNotificationEpochHadRejectedCallback,
            now: now
        ) else { return }

        displayedBatteryLevelIsCached = false
        batteryReadingIsRecentBaseline = true
        defaults.removeObject(forKey: BatteryDefaults.requiresFreshConfirmation)
        defaults.set(now.timeIntervalSince1970,
                     forKey: BatteryDefaults.notificationLeaseAt)
        // The percentage is now displayable only as an explicitly aged recent
        // baseline under the active change-driven lease. Charge state remains
        // level-only until an independent rise/event proves Charging or a
        // decline proves Not Charging.
        assignIfChanged(\.batteryIsCharging, false)
        assignIfChanged(\.batteryChargeStatus, .levelOnly)
        assignIfChanged(\.batteryRecentlyDropping, false)
        Self.persistBatteryChargeStatusProjection(.levelOnly,
                                                  source: "reconnect_2A19_baseline",
                                                  defaults: defaults,
                                                  now: now)
        batteryProjectionRevision &+= 1
        AtriaDebugLog("ATRIADBG battery level=%d source=%@ status=accepted reason=%@ detail=recent_midrange_active_2a19_and_current_connection_hr accepted_age_s=%.1f",
                      batteryLevel,
                      defaults.string(forKey: BatteryDefaults.source) ?? "none",
                      reason,
                      lastAcceptedBatteryLevelAt.map { now.timeIntervalSince($0) } ?? -1)
    }

    /// A validated mid-range baseline is allowed to become displayable as
    /// "Recent" once live HR proves that the same saved strap is connected.
    /// Because that proof arrives on the HR channel, it needs a one-shot battery
    /// projection invalidation even though the percentage itself did not change.
    private func publishRecentReconnectBatteryBaselineIfNeeded(now: Date) {
        guard !recentReconnectBatteryBaselineProjectionPublished,
              recentReconnectBatteryBaselineIsDisplayable(now: now) else { return }
        recentReconnectBatteryBaselineProjectionPublished = true
        batteryProjectionRevision &+= 1
        AtriaDebugLog("ATRIADBG battery status=recent_baseline_published level=%d reason=accepted_hr_current_connection",
                      batteryLevel)
    }

    private func revokeBatteryNotificationLease(reason: String, now: Date = Date()) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        displayedBatteryLevelIsCached = (11...99).contains(batteryLevel)
        recentReconnectBatteryBaselineProjectionPublished = false
        batteryReadingIsRecentBaseline = displayedBatteryLevelIsCached
        assignIfChanged(\.batteryIsCharging, false)
        assignIfChanged(\.batteryChargeStatus, .levelOnly)
        assignIfChanged(\.batteryRecentlyDropping, false)
        Self.persistBatteryChargeStatusProjection(.levelOnly,
                                                  source: "notification_lease_revoked",
                                                  defaults: defaults,
                                                  now: now)
        batteryProjectionRevision &+= 1
        AtriaDebugLog("ATRIADBG battery status=pending reason=%@ detail=notification_lease_revoked level=%d",
                      reason,
                      batteryLevel)
    }

    private func recordBatteryChargeEvidence(_ status: BatteryChargeStatus,
                                             reason: String) {
        guard status == .charging else {
            lastActiveBatteryChargeEvidenceAt = nil
            batteryChargeExpirationTask?.cancel()
            batteryChargeExpirationTask = nil
            return
        }

        lastActiveBatteryChargeEvidenceAt = Date()
        scheduleBatteryChargeExpiration(reason: reason)
    }

    private func scheduleBatteryChargeExpiration(reason: String) {
        batteryChargeExpirationTask?.cancel()
        batteryChargeExpirationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.activeBatteryChargeDisplayMaxAge))
            expireStaleBatteryChargeStatus(reason: reason)
        }
    }

    private func expireStaleBatteryChargeStatus(reason: String) {
        guard batteryChargeStatus == .charging else { return }
        let age = lastActiveBatteryChargeEvidenceAt.map { Date().timeIntervalSince($0) } ?? .infinity
        guard age >= Self.activeBatteryChargeDisplayMaxAge else {
            scheduleBatteryChargeExpiration(reason: reason)
            return
        }

        assignIfChanged(\.batteryIsCharging, false)
        assignIfChanged(\.batteryChargeStatus, .levelOnly)
        lastActiveBatteryChargeEvidenceAt = nil
        batteryChargeExpirationTask = nil
        persistBatteryChargeStatus(.levelOnly, source: "live_charge_timeout")
        AtriaDebugLog("ATRIADBG battery_charge status=expired reason=%@ age_s=%.0f action=level_only",
              reason,
              age)
    }

    private func resetProductionCaptureDefaultsForDebug() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CaptureDefaults.configured)
        defaults.removeObject(forKey: CaptureDefaults.strapStepFullProtocolMigrated)
        defaults.removeObject(forKey: CaptureDefaults.stableR10TransportMigrated)
        defaults.removeObject(forKey: LongWearDefaults.enabled)
        defaults.removeObject(forKey: LongWearDefaults.userSelected)
        defaults.removeObject(forKey: RadioDefaults.standardHROnly)
        defaults.removeObject(forKey: RadioDefaults.standardHROnlyUserSelected)
        defaults.removeObject(forKey: LongWearDefaults.checkpointInterval)
        defaults.removeObject(forKey: LongWearDefaults.diagnosticInterval)
        defaults.removeObject(forKey: LongWearDefaults.workoutAutoSaveInterval)
        defaults.removeObject(forKey: LongWearDefaults.noDataTimeout)
        defaults.removeObject(forKey: LongWearDefaults.noDataCheckInterval)
        defaults.removeObject(forKey: LongWearDefaults.acceptedHRTimeout)
        defaults.removeObject(forKey: LongWearDefaults.label)
        defaults.removeObject(forKey: CollectionProfileDefaults.profile)
        defaults.removeObject(forKey: DutyCycleDefaults.enabled)
        defaults.removeObject(forKey: DutyCycleDefaults.focusFullCapture)
        collectionProfile = .balanced
        longWearModeEnabled = false
        updateSessionPointCacheMode()
        standardHROnlyMode = false
        standardHROnlyEnabled = false
        AtriaDebugLog("ATRIADBG capture_defaults status=reset reason=debug_launch_arg scope=radio_and_long_wear_only")
    }

    private func bootstrapProductionCaptureDefaultsIfNeeded(arguments: [String]) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: CaptureDefaults.configured) else { return }
        defaults.set(true, forKey: CaptureDefaults.configured)
        defaults.set(true, forKey: CaptureDefaults.protectedLongWearMigrated)
        defaults.set(true, forKey: CaptureDefaults.strapStepFullProtocolMigrated)
        defaults.set(true, forKey: CaptureDefaults.stableR10TransportMigrated)
        defaults.set(true, forKey: LongWearDefaults.enabled)
        defaults.set(true, forKey: RadioDefaults.standardHROnly)
        defaults.set(true, forKey: OfflineSyncDefaults.enabled)
        if defaults.object(forKey: LongWearDefaults.checkpointInterval) == nil {
            defaults.set(60.0, forKey: LongWearDefaults.checkpointInterval)
        }
        if defaults.object(forKey: LongWearDefaults.diagnosticInterval) == nil {
            defaults.set(15.0, forKey: LongWearDefaults.diagnosticInterval)
        }
        if defaults.object(forKey: LongWearDefaults.workoutAutoSaveInterval) == nil {
            defaults.set(15.0, forKey: LongWearDefaults.workoutAutoSaveInterval)
        }
        if defaults.object(forKey: LongWearDefaults.noDataTimeout) == nil {
            defaults.set(75.0, forKey: LongWearDefaults.noDataTimeout)
        }
        if defaults.object(forKey: LongWearDefaults.noDataCheckInterval) == nil {
            defaults.set(15.0, forKey: LongWearDefaults.noDataCheckInterval)
        }
        if defaults.object(forKey: LongWearDefaults.acceptedHRTimeout) == nil {
            defaults.set(45.0, forKey: LongWearDefaults.acceptedHRTimeout)
        }
        if defaults.string(forKey: LongWearDefaults.label) == nil {
            defaults.set("All-day wear", forKey: LongWearDefaults.label)
        }
        if defaults.string(forKey: CollectionProfileDefaults.profile) == nil {
            defaults.set(CollectionProfile.balanced.rawValue, forKey: CollectionProfileDefaults.profile)
        }
        collectionProfile = CollectionProfile.load(defaults: defaults)
        longWearModeEnabled = true
        updateSessionPointCacheMode()
        standardHROnlyMode = true
        standardHROnlyEnabled = true
        let explicitMode = arguments.contains("--atria-standard-hr-only") || arguments.contains("--atria-long-wear-mode") ? 1 : 0
        recordRadioMode("protected_r10_minimal", reason: "stable_hr_r10_default")
        AtriaDebugLog("ATRIADBG capture_defaults status=enabled mode=protected_r10_minimal long_wear_default=1 strap_steps_background=1 offline_sync_default=1 reason=first_normal_launch explicit_mode_arg=%d checkpoint_interval_s=60 live_workout_interval_s=15 workout_autosave_interval_s=15 no_data_timeout_s=75 accepted_hr_timeout_s=45 hr_continuity_timeout_s=6 recovery_policy=staged_read_reassert_then_fresh_scan",
              explicitMode)
    }

    private func migrateAutomaticLongWearDefaultIfNeeded(arguments: [String]) {
        let defaults = UserDefaults.standard
        guard !arguments.contains("--atria-full-protocol-mode") else { return }
        guard defaults.bool(forKey: CaptureDefaults.configured) else { return }
        guard !defaults.bool(forKey: LongWearDefaults.userSelected) else { return }
        guard !defaults.bool(forKey: CaptureDefaults.protectedLongWearMigrated) else { return }

        defaults.set(true, forKey: CaptureDefaults.protectedLongWearMigrated)
        defaults.set(true, forKey: LongWearDefaults.enabled)
        defaults.set(true, forKey: RadioDefaults.standardHROnly)
        longWearModeEnabled = true
        updateSessionPointCacheMode()
        standardHROnlyMode = true
        standardHROnlyEnabled = true
        forceFreshScanOnRestore = true
        recordRadioMode("protected_r10_minimal", reason: "protected_default_migration")
        AtriaDebugLog("ATRIADBG long_wear_mode status=migrated_default action=enabled reason=protected_background_collection_default")
    }

    /// Continuous strap capture is a product invariant. Older builds let the
    /// user disable it, then later removed that control; preserving the hidden
    /// false value strands the app in foreground-only collection and prevents
    /// sleep/activity evidence from being journaled. Full-protocol diagnostics
    /// remain isolated and never consume the production migration.
    @discardableResult
    nonisolated static func migrateAlwaysOnLongWearIfNeeded(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard !arguments.contains("--atria-full-protocol-mode") else { return false }
        guard defaults.bool(forKey: CaptureDefaults.configured) else { return false }
        guard !defaults.bool(forKey: CaptureDefaults.alwaysOnLongWearMigrated) else { return false }

        defaults.set(true, forKey: CaptureDefaults.alwaysOnLongWearMigrated)
        defaults.set(true, forKey: LongWearDefaults.enabled)
        // The retired toggle must not continue to block later automatic
        // migrations. This does not change the independent battery-saver/radio
        // preference.
        defaults.set(false, forKey: LongWearDefaults.userSelected)
        return true
    }

    private func migrateOfflineSyncDefaultIfNeeded(arguments: [String]) {
        guard !arguments.contains("--atria-full-protocol-mode") else { return }
        guard UserDefaults.standard.object(forKey: OfflineSyncDefaults.enabled) == nil else { return }
        UserDefaults.standard.set(true, forKey: OfflineSyncDefaults.enabled)
        AtriaDebugLog("ATRIADBG offline_sync status=migrated_default action=enabled reason=stored_session_backfill_default")
    }

    /// Rollbacks written before the history/R10 ownership interlock were
    /// contaminated by historical-recovery reconnects. Clear that obsolete
    /// cooldown exactly once after upgrading so existing users can qualify the
    /// corrected transport immediately instead of keeping frozen steps for up
    /// to six hours. No health, workout, sleep, archive, or calibration data is
    /// touched.
    private func migrateProtectedR10HistoryInterlockIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.protectedR10HistoryInterlockMigrationKey) else { return }
        defaults.set(true, forKey: Self.protectedR10HistoryInterlockMigrationKey)
        defaults.set(false, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.set(0, forKey: Self.protectedR10RetryCountKey)
        defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
        defaults.removeObject(forKey: "atria.protectedR10.rollbackAt")
        defaults.set("history_interlock_migration", forKey: "atria.protectedR10.rollbackReason")
        defaults.set("qualification_pending", forKey: RadioDefaults.passiveR10Status)
        AtriaDebugLog("ATRIADBG protected_r10 status=migrated_history_interlock action=clear_contaminated_rollback_preserve_user_data")
    }

    /// A stream can deliver valid R10 records yet still destabilize the physical
    /// BLE link. If the latest connection repeatedly ended within seconds and a
    /// motion frame was present immediately before that edge, isolate the next
    /// launch onto a fresh HR + standard-battery CoreBluetooth owner. This is a
    /// continuity fuse, not a permanent capability decision: an explicitly
    /// armed calibration run clears it so the transport can be tested again.
    private func isolateRecentProtectedR10DisconnectStormIfNeeded(now: Date = Date()) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.protectedR10StreamSuppressedKey),
              defaults.integer(forKey: LinkDefaults.disconnects) >= 3 else { return }
        let lastDisconnectAt = defaults.double(forKey: "atria.ble.lastDisconnectDiagnosticAt")
        let connectedDuration = defaults.double(forKey: "atria.ble.lastConnectedDuration")
        let lastR10At = defaults.double(forKey: RadioDefaults.passiveR10LastValidAt)
        guard lastDisconnectAt > 0,
              lastR10At > 0,
              now.timeIntervalSince1970 >= lastDisconnectAt,
              now.timeIntervalSince1970 - lastDisconnectAt <= 5 * 60,
              connectedDuration > 0,
              connectedDuration <= 30,
              now.timeIntervalSince1970 >= lastR10At,
              now.timeIntervalSince1970 - lastR10At <= 5 * 60 else { return }
        if strapStepCalibrationCaptureUntil != nil {
            AtriaStrapCalibrationArchive.shared.flush()
            defaults.removeObject(
                forKey: AtriaStrapCalibrationArchive.captureUntilDefaultsKey
            )
            strapStepCalibrationCaptureUntil = nil
            stepCalibrationCaptureArmedAt = nil
            stepCalibrationMotionStreamReady = false
        }
        defaults.set(true, forKey: Self.protectedR10StreamSuppressedKey)
        defaults.set(false, forKey: Self.protectedR10PassiveReprobePendingKey)
        defaults.set(now.timeIntervalSince1970,
                     forKey: Self.protectedR10DisconnectStormAtKey)
        defaults.set("short_links_with_fresh_r10",
                     forKey: Self.protectedR10DisconnectStormReasonKey)
        defaults.set("isolated_hr_battery_after_disconnect_storm",
                     forKey: RadioDefaults.passiveR10Status)
        AtriaDebugLog("ATRIADBG protected_r10 status=stream_isolated reason=disconnect_storm connected_s=%.1f r10_before_disconnect_s=%.1f action=fresh_pure_hr_owner_next_launch",
                      connectedDuration,
                      abs(lastDisconnectAt - lastR10At))
    }

    /// The retired 0x1A experiment could leave 2A37 alive while R10 stayed
    /// silent. One clean link rebuild is required to restore the strap's live
    /// motion mode; persist the intent so it happens once across app upgrades.
    private func migrateFailedProprietaryBatteryRefreshIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: BatteryDefaults.proprietaryRefreshRecoveryMigrated) else { return }
        defaults.set(true, forKey: BatteryDefaults.proprietaryRefreshRecoveryMigrated)
        guard defaults.string(forKey: BatteryDefaults.proprietaryRefreshLastFailure) != nil else { return }
        defaults.set(true, forKey: BatteryDefaults.proprietaryRefreshRecoveryPending)
        defaults.set(false, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
        defaults.set("battery_probe_recovery_pending", forKey: RadioDefaults.passiveR10Status)
        AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=recovery_migrated action=one_clean_link_rebuild")
    }

    @discardableResult
    private func beginRetiredBatteryProbeRecoveryIfNeeded(_ peripheral: CBPeripheral) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: BatteryDefaults.proprietaryRefreshRecoveryPending) else { return false }
        defaults.set(false, forKey: BatteryDefaults.proprietaryRefreshRecoveryPending)
        defaults.set(false, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.removeObject(forKey: "atria.protectedR10.rollbackAt")
        defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
        defaults.set("battery_probe_recovery_rebuild", forKey: RadioDefaults.passiveR10Status)
        defaults.set(Date().timeIntervalSince1970,
                     forKey: "atria.battery.proprietaryRefresh.recoveryStartedAt")
        AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=recovery_start action=cancel_once_then_reconnect_known")
        requestFreshScanReconnect(peripheral: peripheral,
                                  reason: "retired_battery_probe_recovery",
                                  intent: .rebuildConnection)
        return true
    }

    private func migrateStableR10TransportDefaultIfNeeded(arguments: [String]) {
        let defaults = UserDefaults.standard
        guard !arguments.contains("--atria-full-protocol-mode") else { return }
        guard defaults.bool(forKey: CaptureDefaults.configured) else { return }
        let migrationWasRecorded = defaults.bool(forKey: CaptureDefaults.stableR10TransportMigrated)
        let userSelectedRadioMode = defaults.bool(forKey: RadioDefaults.standardHROnlyUserSelected)
        guard Self.shouldMigrateAutomaticModeToProtectedR10(
            migrationWasRecorded: migrationWasRecorded,
            userSelectedRadioMode: userSelectedRadioMode
        ) else { return }
        defaults.set(true, forKey: CaptureDefaults.stableR10TransportMigrated)
        defaults.set(true, forKey: RadioDefaults.standardHROnly)
        standardHROnlyMode = true
        standardHROnlyEnabled = true
        forceFreshScanOnRestore = true
        recordRadioMode("protected_r10_minimal", reason: "stable_hr_r10_migration")
        AtriaDebugLog("ATRIADBG radio_mode status=migrated mode=protected_r10_minimal reason=physical_ab_stability strap_steps_background=1 phone_step_fallback=0")
    }

    /// Migrate only automatic/default radio state. A user who explicitly chose
    /// the diagnostic full profile or the stable minimal profile keeps it.
    nonisolated static func shouldMigrateAutomaticModeToProtectedR10(
        migrationWasRecorded: Bool,
        userSelectedRadioMode: Bool
    ) -> Bool {
        !migrationWasRecorded && !userSelectedRadioMode
    }

    /// Normal wear defaults to the physically verified minimal HR + R10 path.
    /// Despite the legacy storage name, this mode retains strap-native motion;
    /// only an explicit user selection may persist the broader profile.
    nonisolated static func shouldUseStandardHROnlyAtNormalLaunch(
        userSelectedBatterySaver: Bool,
        persistedStandardHROnly: Bool
    ) -> Bool {
        userSelectedBatterySaver ? persistedStandardHROnly : true
    }

    /// A temporary diagnostic full-protocol override must restore the exact
    /// prior profile. The automatic prior is now the stable R10-capable mode,
    /// so user ownership no longer changes the restoration result.
    nonisolated static func standardHROnlyModeAfterFullProtocolOverride(
        modeBeforeOverride: Bool,
        userSelectedBatterySaver: Bool
    ) -> Bool {
        _ = userSelectedBatterySaver
        return modeBeforeOverride
    }

    func setStandardHROnlyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
        UserDefaults.standard.set(true, forKey: RadioDefaults.standardHROnlyUserSelected)
        applyStandardHROnly(enabled: enabled, persist: true, reconnect: true, reason: "user_toggle")
    }

    /// Enables the bounded raw-motion archive immediately for an in-app step
    /// calibration run. Normally the production protected connection already
    /// carries R10 on stream 5. If the disconnect-storm fuse isolated motion,
    /// explicit calibration clears that fuse and rediscovers only the minimal
    /// R10 service; it still never reads battery or starts offline history.
    func armStepCalibrationCapture(until requestedUntil: Date = Date().addingTimeInterval(
        AtriaStrapCalibrationArchive.defaultCaptureDuration
    )) {
        let now = Date()
        let captureUntil = max(requestedUntil, now.addingTimeInterval(60))
        UserDefaults.standard.set(
            captureUntil.timeIntervalSince1970,
            forKey: AtriaStrapCalibrationArchive.captureUntilDefaultsKey
        )
        strapStepCalibrationCaptureUntil = captureUntil
        stepCalibrationCaptureArmedAt = now
        stepCalibrationMotionStreamReady = false
        if protectedR10StreamSuppressed {
            UserDefaults.standard.set(false,
                                      forKey: Self.protectedR10StreamSuppressedKey)
            UserDefaults.standard.set("explicit_calibration_reprobe",
                                      forKey: RadioDefaults.passiveR10Status)
            if let peripheral, peripheral.state == .connected {
                peripheral.discoverServices([Self.UUIDs.strapService])
            }
        }

        AtriaDebugLog(
            "ATRIADBG strap_step_calibration status=armed_runtime until_utc=%@ source=developer_sequence transport=minimal_protected_r10 battery_reads=0 offline_sync=0 commands=0",
            ISO8601DateFormatter().string(from: captureUntil)
        )
    }

    /// Ends passive archival without touching the live transport.
    func finishStepCalibrationCapture(reason: String = "sequence_complete") {
        AtriaStrapCalibrationArchive.shared.flush()
        UserDefaults.standard.removeObject(
            forKey: AtriaStrapCalibrationArchive.captureUntilDefaultsKey
        )
        strapStepCalibrationCaptureUntil = nil
        stepCalibrationCaptureArmedAt = nil
        stepCalibrationMotionStreamReady = false

        AtriaDebugLog(
            "ATRIADBG strap_step_calibration status=disarmed reason=%@ transport_unchanged=1 standard_hr_only=%d long_wear_unchanged=1",
            reason,
            standardHROnlyMode ? 1 : 0
        )
    }

    func setLongWearModeEnabled(_ enabled: Bool, rest: Int, maxHR: Int) {
        UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
        UserDefaults.standard.set(true, forKey: LongWearDefaults.userSelected)
        UserDefaults.standard.set(enabled, forKey: LongWearDefaults.enabled)
        longWearModeEnabled = enabled
        updateSessionPointCacheMode()
        if enabled {
            let standardOnly = Self.shouldUseStandardHROnlyInProtectedBackground(
                userSelectedBatterySaver: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnlyUserSelected),
                persistedStandardHROnly: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
            )
            applyStandardHROnly(enabled: standardOnly, persist: false, reconnect: true, reason: "long_wear")
            startLongWearMode(rest: rest, maxHR: maxHR, reason: "user_toggle")
        } else {
            stopLongWearMode(reason: "user_toggle")
        }
    }

    func setCollectionProfile(_ profile: CollectionProfile, rest: Int, maxHR: Int) {
        guard profile != collectionProfile else { return }
        UserDefaults.standard.set(profile.rawValue, forKey: CollectionProfileDefaults.profile)
        collectionProfile = profile
        AtriaDebugLog("ATRIADBG collection_profile status=selected profile=%@ cadence_multiplier=%.2f stale_timeout_multiplier=%.2f",
                      profile.rawValue,
                      profile.cadenceMultiplier,
                      profile.staleTimeoutMultiplier)
        guard longWearModeEnabled else { return }
        startLongWearMode(rest: rest, maxHR: maxHR, reason: "collection_profile")
    }

    func applyPersistentLongWearModeIfNeeded(rest: Int, maxHR: Int) {
        guard UserDefaults.standard.bool(forKey: LongWearDefaults.enabled) else {
            longWearModeEnabled = false
            updateSessionPointCacheMode()
            return
        }
        longWearModeEnabled = true
        updateSessionPointCacheMode()
        guard !foregroundInteractiveMode else {
            return
        }
        let standardOnly = Self.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnlyUserSelected),
            persistedStandardHROnly: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
        )
        applyStandardHROnly(enabled: standardOnly, persist: false, reconnect: false, reason: "long_wear_persisted")
        if !standardOnly {
            rediscoverFullProtocolServicesIfConnected(reason: "long_wear_persisted_strap_steps")
        }
        startLongWearMode(rest: rest, maxHR: maxHR, reason: "persisted")
    }

    private func startLongWearMode(rest: Int, maxHR: Int, reason: String) {
        let defaults = UserDefaults.standard
        let checkpointSeconds = defaults.object(forKey: LongWearDefaults.checkpointInterval) as? Double ?? 60
        let diagnosticSeconds = defaults.object(forKey: LongWearDefaults.diagnosticInterval) as? Double ?? 15
        let autoSaveSeconds = defaults.object(forKey: LongWearDefaults.workoutAutoSaveInterval) as? Double ?? 15
        let noDataTimeout = defaults.object(forKey: LongWearDefaults.noDataTimeout) as? Double ?? 75
        let noDataCheckInterval = defaults.object(forKey: LongWearDefaults.noDataCheckInterval) as? Double ?? 15
        let acceptedHRTimeout = defaults.object(forKey: LongWearDefaults.acceptedHRTimeout) as? Double ?? 45
        let profile = collectionProfile
        let cadenceMultiplier = profile.cadenceMultiplier
        let staleTimeoutMultiplier = profile.staleTimeoutMultiplier
        let noDataWatchdogTimeout = max(60, min(noDataTimeout * staleTimeoutMultiplier, 600))
        let acceptedHRWatchdogTimeout = max(35, min(acceptedHRTimeout * staleTimeoutMultiplier, 180))
        let hrContinuityTimeout = max(6, min(acceptedHRWatchdogTimeout / 8, 10))
        let label = defaults.string(forKey: LongWearDefaults.label) ?? "All-day wear"
        captureLabel = label
        restoreActiveSessionJournalIfNeeded(reason: reason)
        let config = LongWearSupervisorConfig(
            label: label,
            rest: rest,
            maxHR: maxHR,
            checkpointInterval: max(10, min(checkpointSeconds * cadenceMultiplier, 3_600)),
            diagnosticInterval: max(5, min(diagnosticSeconds * cadenceMultiplier, 300)),
            autoSaveInterval: max(5, min(autoSaveSeconds * cadenceMultiplier, 300)),
            noDataTimeout: noDataWatchdogTimeout,
            noDataCheckInterval: max(5, min(noDataCheckInterval * cadenceMultiplier, 300)),
            hrContinuityTimeout: hrContinuityTimeout,
            rrPresenceTimeout: max(20, min(acceptedHRWatchdogTimeout * 2, 120)),
            acceptedHRTimeout: acceptedHRWatchdogTimeout
        )
        cacheDutyCycleRestHR(rest)
        scheduleLongWearSupervisor(config: config)
        ensureForegroundKeepaliveWatchdog(reason: reason)
        AtriaDebugLog("ATRIADBG long_wear_mode enabled=1 reason=%@ radio_mode=%@ supervisor=1 collection_profile=%@ cadence_multiplier=%.2f stale_timeout_multiplier=%.2f checkpoint_interval_s=%.0f live_workout_interval_s=%.0f workout_autosave_interval_s=%.0f no_data_timeout_s=%.0f no_data_check_interval_s=%.0f hr_continuity_timeout_s=%.0f supervisor_base_tick_s=%.0f accepted_hr_timeout_s=%.0f disconnect_reconnect_policy=staged_read_reassert_then_fresh_scan label=%@ rest_hr=%d max_hr=%d",
              reason,
              standardHROnlyMode ? "standard_hr_only" : "full_protocol",
              profile.rawValue,
              cadenceMultiplier,
              staleTimeoutMultiplier,
              config.checkpointInterval,
              config.diagnosticInterval,
              config.autoSaveInterval,
              config.noDataTimeout,
              config.noDataCheckInterval,
              config.hrContinuityTimeout,
              config.baseTickInterval,
              config.acceptedHRTimeout,
              label,
              rest,
              maxHR)
    }

    private func stopLongWearMode(reason: String) {
        stopForegroundKeepaliveWatchdog(reason: reason)
        pauseLongWearAutomation(reason: reason)
        UserDefaults.standard.set(false, forKey: CheckpointDefaults.armed)
        UserDefaults.standard.set("long_wear_stopped", forKey: CheckpointDefaults.lastStatus)
        AtriaDebugLog("ATRIADBG long_wear_mode enabled=0 reason=%@ checkpoint_cancelled=1 live_workout_cancelled=1 workout_autosave_cancelled=1 no_data_watchdog_cancelled=1 hr_continuity_watchdog_cancelled=1 accepted_hr_watchdog_cancelled=1",
              reason)
    }

    private func pauseLongWearAutomation(reason: String) {
        delayedSessionSaveTask?.cancel()
        liveWorkoutDiagnosticTask?.cancel()
        workoutAutoSaveTask?.cancel()
        longWearSupervisorTask?.cancel()
        activeLongWearSupervisorConfig = nil
        noDataWatchdogTask?.cancel()
        debugNoDataWatchdogTask?.cancel()
        hrContinuityWatchdogTask?.cancel()
        rrPresenceWatchdogTask?.cancel()
        debugHRContinuityWatchdogTask?.cancel()
        acceptedHRWatchdogTask?.cancel()
        debugAcceptedHRWatchdogTask?.cancel()
        longWearSupervisorTask = nil
        UserDefaults.standard.set(false, forKey: CheckpointDefaults.armed)
        AtriaDebugLog("ATRIADBG long_wear_mode paused=1 reason=%@ foreground_interactive=%d",
              reason,
              foregroundInteractiveMode ? 1 : 0)
    }

    private func elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: String) {
        guard longWearModeEnabled else { return }
        guard standardHROnlyMode else { return }
        guard !offlineHistoricalSyncInProgress else { return }
        // Protected standard mode now carries 2A37 plus the physically proven
        // minimal stream5/TX/3F01 motion path. Foregrounding must not expand it
        // into legacy full protocol (extra CCCDs/reads/commands), which would
        // undo the isolation that made simultaneous HR and R10 stable.
        reassertHeartRateNotificationsIfConnected(reason: "\(reason)_protected_r10")
        sendProtectedR10ActivationIfReady()
        AtriaDebugLog("ATRIADBG radio_mode mode=standard_hr_only reason=%@ action=preserve_protected_r10_no_full_protocol_escalation",
                      reason)
    }

    private func isRRProtectedSleepWindow(now: Date) -> Bool {
        let hour = Calendar.current.component(.hour, from: now)
        return hour >= 21 || hour < 11
    }

    private func restoreProtectedLongWearRadioIfNeeded(reason: String) {
        guard longWearModeEnabled else { return }
        guard !offlineHistoricalSyncInProgress else { return }
        let standardOnly = Self.shouldUseStandardHROnlyInProtectedBackground(
            userSelectedBatterySaver: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnlyUserSelected),
            persistedStandardHROnly: UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
        )
        // Already in the desired mode: leave the active proprietary stream and
        // HR subscription untouched. Rediscovery resets realtimeArmed and would
        // create an avoidable background gap.
        guard standardHROnlyMode != standardOnly else { return }
        applyStandardHROnly(enabled: standardOnly,
                            persist: false,
                            reconnect: standardOnly,
                            reason: reason)
        if !standardOnly {
            rediscoverFullProtocolServicesIfConnected(reason: "\(reason)_strap_steps")
        }
    }

    func handleInteractiveForeground(rest: Int, maxHR: Int) {
        let now = Date()
        if let lastInteractiveForegroundHandlingAt,
           now.timeIntervalSince(lastInteractiveForegroundHandlingAt) < 1 {
            // UIKit and SwiftUI can report the same foreground transition.
            // Keep the already-live link healthy without repeating journal
            // restore, supervisor replacement, or service rediscovery.
            ensureForegroundKeepaliveWatchdog(reason: "scene_active_coalesced")
            reassertHeartRateNotificationsIfConnected(reason: "scene_active_coalesced")
            reassertR10NotificationIfConnected(reason: "scene_active_coalesced")
            return
        }
        lastInteractiveForegroundHandlingAt = now
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        if Self.shouldUseFastWorkoutForegroundResume(
            activeExplicitWorkout: activeExplicitWorkout,
            hasLiveSession: !session.isEmpty,
            linkConnected: status == .connected && peripheral?.state == .connected
        ) {
            foregroundInteractiveMode = true
            ensureForegroundKeepaliveWatchdog(reason: "scene_active_workout_fast")
            reassertHeartRateNotificationsIfConnected(reason: "scene_active_workout_fast")
            reassertR10NotificationIfConnected(reason: "scene_active_workout_fast")
            updateDutyCycleState(reason: "scene_active_workout_fast", now: now)
            AtriaDebugLog("ATRIADBG foreground_resume path=workout_fast samples=%d connected=1 action=preserve_live_pipeline",
                          session.count)
            return
        }
        scheduleStaleArmedRangeLossBackfillReconciliation(reason: "scene_active")
        resumeForegroundScanIfNeeded(reason: "scene_active")
        restoreActiveSessionJournalIfNeeded(reason: "scene_active_foreground")
        // Arm the silent-link safety net whenever we are foreground + long-wear,
        // including a fresh foreground launch where foregroundInteractiveMode is
        // already true (the all-night, screen-on scenario). Idempotent: only
        // starts when not already running.
        ensureForegroundKeepaliveWatchdog(reason: "scene_active")
        if longWearModeEnabled {
            startLongWearMode(rest: rest, maxHR: maxHR, reason: "scene_active_foreground")
        }
        reassertHeartRateNotificationsIfConnected(reason: "scene_active")
        reassertR10NotificationIfConnected(reason: "scene_active")
        elevateLongWearRadioForInteractiveForegroundIfNeeded(reason: "scene_active_interactive")
        if foregroundInteractiveMode {
            return
        }
        foregroundInteractiveMode = true
        guard longWearModeEnabled else {
            return
        }
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=1 action=keep_supervisor_and_keepalive_armed rest_hr=%d max_hr=%d",
              rest,
              maxHR)
    }

    private func reassertHeartRateNotificationsIfConnected(reason: String) {
        if motionHandshakeDiagnostic != nil {
            recordMotionHandshakeEvidence(event: "foreground_hr_reassert_blocked", detail: reason)
            return
        }
        guard status == .connected, let peripheral else { return }
        if dutyCycleState == .sparseSentinel {
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=skipped reason=%@ detail=duty_cycle_sparse", reason)
            return
        }
        guard peripheral.state == .connected else {
            recomputeConnectionStatus(reason: "foreground_notify_reassert_peripheral_not_connected")
            if !reconnectToSavedPeripheralIfPossible(reason: "\(reason)_notify_reassert_peripheral_state_\(peripheral.state.rawValue)") {
                startScan(reason: "\(reason)_notify_reassert_peripheral_state_\(peripheral.state.rawValue)")
            }
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=peripheral_not_connected reason=%@ peripheral_state=%d action=reconnect_known_strap",
                          reason,
                          peripheral.state.rawValue)
            return
        }
        if let characteristic = heartRateCharacteristic {
            // A healthy CoreBluetooth subscription survives ordinary app
            // switches. Toggling it off/on on every foreground edge discards
            // in-flight 2A37 samples and was visible as a short workout gap
            // after returning to Atria. Repair only a stale or non-notifying
            // subscription; the keepalive watchdog remains the deeper safety
            // net for a link that goes silent later.
            if Self.shouldPreserveHeartRateNotificationOnForeground(
                isNotifying: characteristic.isNotifying,
                lastRawNotificationAt: lastRawHRNotificationAt,
                now: Date()
            ) {
                AtriaDebugLog("ATRIADBG ble_notify_reassert status=preserved reason=%@ source=foreground_return action=keep_healthy_subscription",
                              reason)
            } else {
                resetHeartRateNotifyIfNeeded(peripheral: peripheral,
                                             characteristic: characteristic,
                                             reason: reason)
            }
            if characteristic.properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=requested reason=%@ source=foreground_return action=keep_connection",
                          reason)
            return
        }
        guard peripheral.state == .connected else { return }
        peripheral.discoverServices([UUIDs.heartRateService])
        AtriaDebugLog("ATRIADBG ble_notify_reassert status=discover_services reason=%@ source=foreground_return action=keep_connection",
                      reason)
    }

    /// R10 can stop while 2A37 HR remains healthy. Preserve an active stream5
    /// subscription, but repair a genuinely inactive CCCD without reconnecting
    /// or toggling the healthy HR notification.
    private func reassertR10NotificationIfConnected(reason: String,
                                                     now: Date = Date()) {
        guard motionHandshakeDiagnostic == nil,
              r10TransportIsExpected,
              status == .connected,
              let peripheral,
              peripheral.state == .connected else { return }

        guard let strapService = peripheral.services?.first(where: {
            $0.uuid == Self.UUIDs.strapService
        }) else {
            peripheral.discoverServices([Self.UUIDs.strapService])
            AtriaDebugLog("ATRIADBG r10_notify_repair status=discover_service reason=%@ action=no_reconnect",
                          reason)
            return
        }
        guard let characteristics = strapService.characteristics else {
            peripheral.discoverCharacteristics([Self.UUIDs.strapStream5, Self.UUIDs.strapTX],
                                               for: strapService)
            AtriaDebugLog("ATRIADBG r10_notify_repair status=discover_characteristics reason=%@ action=no_reconnect",
                          reason)
            return
        }
        guard let stream5 = characteristics.first(where: {
            $0.uuid == Self.UUIDs.strapStream5
        }), stream5.properties.contains(.notify) else {
            peripheral.discoverCharacteristics([Self.UUIDs.strapStream5, Self.UUIDs.strapTX],
                                               for: strapService)
            return
        }
        if stream5.isNotifying {
            strapStream5NotifyConfirmed = true
            ensureR10LivenessWatchdog(reason: "\(reason)_stream5_active")
            AtriaDebugLog("ATRIADBG r10_notify_repair status=preserved reason=%@ action=keep_active_cccd",
                          reason)
            return
        }
        guard Self.shouldRepairR10Notification(
            expected: r10TransportIsExpected,
            connected: true,
            isNotifying: stream5.isNotifying,
            lastRepairAt: lastR10NotifyRepairAt,
            now: now
        ) else { return }
        lastR10NotifyRepairAt = now
        strapStream5NotifyConfirmed = false
        peripheral.setNotifyValue(true, for: stream5)
        AtriaDebugLog("ATRIADBG r10_notify_repair status=requested reason=%@ action=enable_stream5_no_reconnect",
                      reason)
    }

    /// Off/on notify resets destroy in-flight samples, so they are paced: at
    /// most one per 30 s, and after 3 consecutive ineffective resets (the
    /// watchdogs immediately asking again) the reset path goes quiet for
    /// 10 min. A strap that streams HR without RR (loose contact) is served
    /// better by accepting the HR-only stream than by resetting it to death —
    /// observed live 2026-07-05: resets every 2-6 s throttled 111k-notification
    /// capture down to ~10 accepted samples/90 s.
    private var lastHRNotifyResetAt: Date?
    private var hrNotifyResetStreak = 0
    private var hrNotifyResetBackoffUntil: Date?
    static let hrNotifyResetMinInterval: TimeInterval = 30
    static let hrNotifyResetStreakLimit = 3
    static let hrNotifyResetBackoff: TimeInterval = 10 * 60
    nonisolated static let foregroundHealthyNotificationWindow: TimeInterval = 12

    nonisolated static func shouldPreserveHeartRateNotificationOnForeground(
        isNotifying: Bool,
        lastRawNotificationAt: Date?,
        now: Date,
        healthyWindow: TimeInterval = foregroundHealthyNotificationWindow
    ) -> Bool {
        guard isNotifying, let lastRawNotificationAt else { return false }
        let age = now.timeIntervalSince(lastRawNotificationAt)
        return age >= 0 && age <= healthyWindow
    }

    private func beginStalledStreamRepair(source: String, now: Date = Date()) -> Bool {
        guard Self.shouldBeginStalledStreamRepair(lastRepairAt: lastStalledStreamRepairAt,
                                                  now: now) else {
            let remaining = max(0, Self.stalledStreamRepairCooldown
                - now.timeIntervalSince(lastStalledStreamRepairAt ?? now))
            AtriaDebugLog("ATRIADBG stalled_stream_repair status=cooldown source=%@ remaining_s=%.1f action=wait_for_data",
                          source,
                          remaining)
            return false
        }
        lastStalledStreamRepairAt = now
        AtriaDebugLog("ATRIADBG stalled_stream_repair status=started source=%@ cooldown_s=%.1f",
                      source,
                      Self.stalledStreamRepairCooldown)
        return true
    }

    private func resetHeartRateNotifyIfNeeded(peripheral: CBPeripheral, characteristic: CBCharacteristic, reason: String) {
        guard characteristic.properties.contains(.notify) else { return }
        let now = Date()
        if let backoffUntil = hrNotifyResetBackoffUntil, now < backoffUntil {
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=reset_backoff reason=%@ remaining_s=%.0f",
                          reason, backoffUntil.timeIntervalSince(now))
            return
        }
        if let last = lastHRNotifyResetAt, now.timeIntervalSince(last) < Self.hrNotifyResetMinInterval {
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=reset_paced reason=%@ since_last_s=%.0f",
                          reason, now.timeIntervalSince(last))
            return
        }
        // A long healthy gap means the last reset worked; start a fresh streak.
        if let last = lastHRNotifyResetAt, now.timeIntervalSince(last) > Self.hrNotifyResetBackoff {
            hrNotifyResetStreak = 0
        }
        lastHRNotifyResetAt = now
        hrNotifyResetStreak += 1
        if hrNotifyResetStreak >= Self.hrNotifyResetStreakLimit {
            hrNotifyResetBackoffUntil = now.addingTimeInterval(Self.hrNotifyResetBackoff)
            hrNotifyResetStreak = 0
            AtriaDebugLog("ATRIADBG ble_notify_reassert status=reset_backoff_armed reason=%@ quiet_s=%.0f",
                          reason, Self.hrNotifyResetBackoff)
        }
        let wasNotifying = characteristic.isNotifying
        if wasNotifying {
            pendingNotifyReenableUUIDs.insert(characteristic.uuid)
            peripheral.setNotifyValue(false, for: characteristic)
        } else {
            if Self.shouldEnableNotifications(isNotifying: characteristic.isNotifying) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        AtriaDebugLog("ATRIADBG ble_notify_reassert status=reset_requested reason=%@ notifying_before=%d streak=%d",
                      reason,
                      wasNotifying ? 1 : 0,
                      hrNotifyResetStreak)
    }

    // MARK: - Duty cycle (daytime power saver)

    @Published private(set) var dutyCycleState: DutyCycleState = .fullCapture
    /// Escalation latch: full-rate capture until this instant. Extended while HR
    /// stays over rest+10; a workout therefore keeps full coverage end-to-end.
    private var dutyCycleEscalatedUntil: Date?
    /// Rest baseline cached from the params the app already passes in.
    private var dutyCycleRestHR: Int = 60
    private var lastSparsePollAt: Date?
    static let dutyCycleSparsePollInterval: TimeInterval = 180
    static let dutyCycleEscalationOverRest = 15
    static let dutyCycleSustainOverRest = 10
    static let dutyCycleEscalationHold: TimeInterval = 10 * 60

    var dutyCycleEnabled: Bool {
        UserDefaults.standard.bool(forKey: DutyCycleDefaults.enabled)
            || ProcessInfo.processInfo.arguments.contains("--atria-enable-duty-cycle")
    }

    func cacheDutyCycleRestHR(_ rest: Int) {
        if rest > 0 { dutyCycleRestHR = rest }
    }

    /// Learned sleep window in minutes-after-midnight, written by the session
    /// store from confirmed sleeps; falls back to 23:30-10:30.
    private func dutyCycleSleepWindow(defaults: UserDefaults = .standard) -> (start: Int, end: Int) {
        let start = defaults.integer(forKey: DutyCycleDefaults.sleepWindowStartMin)
        let end = defaults.integer(forKey: DutyCycleDefaults.sleepWindowEndMin)
        guard start > 0 || end > 0 else { return (23 * 60 + 30, 10 * 60 + 30) }
        return (min(max(start, 0), 1439), min(max(end, 0), 1439))
    }

    private func isInsideDutyCycleSleepWindow(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let window = dutyCycleSleepWindow()
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if window.start <= window.end {
            return minutes >= window.start && minutes <= window.end
        }
        // Window crosses midnight (the normal case: ~23:30 -> ~10:30).
        return minutes >= window.start || minutes <= window.end
    }

    /// Called on accepted HR (notify or sparse poll): elevated HR escalates to
    /// full capture instantly and keeps extending the latch while elevated.
    func noteDutyCycleHeartRate(_ bpm: Int, now: Date = Date()) {
        guard dutyCycleEnabled else { return }
        if bpm >= dutyCycleRestHR + Self.dutyCycleEscalationOverRest {
            let wasEscalated = dutyCycleEscalatedUntil.map { $0 > now } ?? false
            dutyCycleEscalatedUntil = now.addingTimeInterval(Self.dutyCycleEscalationHold)
            if !wasEscalated {
                AtriaDebugLog("ATRIADBG duty_cycle status=escalated reason=hr_over_rest bpm=%d rest=%d",
                              bpm,
                              dutyCycleRestHR)
                updateDutyCycleState(reason: "hr_escalation")
            }
        } else if bpm >= dutyCycleRestHR + Self.dutyCycleSustainOverRest,
                  let until = dutyCycleEscalatedUntil, until > now {
            dutyCycleEscalatedUntil = now.addingTimeInterval(Self.dutyCycleEscalationHold)
        }
    }

    /// Recompute the desired state and apply transitions. Cheap; called from the
    /// keepalive tick, scene changes, and escalation events.
    func updateDutyCycleState(reason: String, now: Date = Date()) {
        let desired: DutyCycleState
        let defaults = UserDefaults.standard
        if !dutyCycleEnabled
            || !longWearModeEnabled
            || isInsideDutyCycleSleepWindow(now: now)
            || foregroundHighFrequencyDisplayMode
            || isRecording
            || defaults.bool(forKey: DutyCycleDefaults.focusFullCapture)
            || (dutyCycleEscalatedUntil.map { $0 > now } ?? false) {
            desired = .fullCapture
        } else {
            desired = .sparseSentinel
        }
        if desired == dutyCycleState {
            // Enforcement is idempotent, not edge-triggered: unguarded reasserts
            // (scene flips, reconnect discovery) can silently re-enable notify
            // while the state stays sparse — re-apply notify-off when seen.
            if desired == .sparseSentinel,
               status == .connected, let peripheral, peripheral.state == .connected,
               let characteristic = heartRateCharacteristic,
               characteristic.isNotifying {
                peripheral.setNotifyValue(false, for: characteristic)
                AtriaDebugLog("ATRIADBG duty_cycle action=hr_notify_off reason=reenforce_%@", reason)
            }
            return
        }
        dutyCycleState = desired
        AtriaDebugLog("ATRIADBG duty_cycle state=%@ reason=%@ sleep_window=%d rest=%d",
                      desired.rawValue,
                      reason,
                      isInsideDutyCycleSleepWindow(now: now) ? 1 : 0,
                      dutyCycleRestHR)
        switch desired {
        case .sparseSentinel:
            // Notify OFF on the live HR link. The protected battery percentage
            // subscription is independent and may emit only when the strap has
            // a new standard 2A19 value.
            if status == .connected, let peripheral, peripheral.state == .connected,
               let characteristic = heartRateCharacteristic,
               characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(false, for: characteristic)
                AtriaDebugLog("ATRIADBG duty_cycle action=hr_notify_off reason=%@", reason)
            }
        case .fullCapture:
            reassertHeartRateNotificationsIfConnected(reason: "duty_cycle_\(reason)")
        }
    }

    func requestStrapStatusRead(reason: String) {
        guard motionHandshakeDiagnostic == nil else {
            recordMotionHandshakeEvidence(event: "battery_read_blocked", detail: reason)
            return
        }
        guard status == .connected, let peripheral, peripheral.state == .connected else {
            AtriaDebugLog("ATRIADBG strap_status_read status=skipped reason=%@ detail=not_connected", reason)
            return
        }
        if let batteryLevelCharacteristic {
            let action = Self.standardBatteryRefreshAction(
                canRead: batteryLevelCharacteristic.properties.contains(.read),
                canNotify: batteryLevelCharacteristic.properties.contains(.notify)
                    || batteryLevelCharacteristic.properties.contains(.indicate),
                isNotifying: batteryLevelCharacteristic.isNotifying
            )
            switch action {
            case .read:
                lastBatteryReadRequestedAt = Date()
                peripheral.readValue(for: batteryLevelCharacteristic)
                AtriaDebugLog("ATRIADBG strap_status_refresh status=requested reason=%@ source=2A19_read",
                              reason)
            case .subscribe:
                lastBatteryReadRequestedAt = Date()
                UserDefaults.standard.set(Date().timeIntervalSince1970,
                                          forKey: BatteryDefaults.notificationRequestedAt)
                peripheral.setNotifyValue(true, for: batteryLevelCharacteristic)
                AtriaDebugLog("ATRIADBG strap_status_refresh status=requested reason=%@ source=2A19_new_subscription",
                              reason)
            case .awaitNotification:
                // This timestamp only throttles refresh attempts; it is never
                // used as battery-value freshness evidence.
                lastBatteryReadRequestedAt = Date()
                if let heartRateReceivedAt = lastRawHRNotificationAt {
                    promoteReconnectBatteryBaselineIfSafe(
                        now: Date(),
                        heartRateReceivedAt: heartRateReceivedAt,
                        reason: "2A19_existing_notify_active"
                    )
                }
                AtriaDebugLog("ATRIADBG strap_status_refresh status=awaiting reason=%@ source=2A19_existing_subscription",
                              reason)
            case .unavailable:
                lastBatteryReadRequestedAt = Date()
                AtriaDebugLog("ATRIADBG strap_status_refresh status=skipped reason=%@ detail=2A19_not_readable_or_notifiable",
                              reason)
            }
            return
        }
        peripheral.discoverServices([UUIDs.batteryService])
        AtriaDebugLog("ATRIADBG strap_status_refresh status=requested reason=%@ services=battery", reason)
    }

    private func scheduleBatteryConfirmationRead(incomingLevel: Int) {
        if batteryConfirmationReadTask != nil,
           let scheduledLevel = batteryConfirmationReadLevel,
           abs(scheduledLevel - incomingLevel) <= 2 {
            return
        }
        batteryConfirmationReadTask?.cancel()
        let delay = Self.batteryConfirmationRetryDelay(incomingLevel: incomingLevel)
        batteryConfirmationReadLevel = incomingLevel
        batteryConfirmationReadTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.batteryConfirmationReadTask = nil
            self.batteryConfirmationReadLevel = nil
            guard let peripheral,
                  peripheral.state == .connected,
                  self.status == .connected else { return }
            self.requestStrapStatusRead(reason: "battery_confirmation_notify")
        }
    }

    private func rediscoverFullProtocolServicesIfConnected(reason: String) {
        guard status == .connected, let peripheral, peripheral.state == .connected else { return }
        txCharacteristic = nil
        realtimeArmed = false
        activeProprietaryNotifyUUIDs.removeAll()
        strapStream5NotifyConfirmed = false
        peripheral.discoverServices(discoveryServicesForCurrentMode)
        AtriaDebugLog("ATRIADBG radio_mode full_protocol_discovery status=requested reason=%@ action=keep_connection",
                      reason)
    }

    /// Runs while long-wear is enabled, including app-switch/background
    /// transitions. It does nothing while data flows. If the link is `.connected`
    /// but has produced no 2A37 packet for an extended window, it re-asserts the
    /// subscription, then escalates to a fresh-scan reconnect if silence
    /// persists. requestFreshScanReconnect already backs off exponentially.
    private func ensureForegroundKeepaliveWatchdog(reason: String) {
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        guard longWearModeEnabled || activeExplicitWorkout else {
            stopForegroundKeepaliveWatchdog(reason: reason)
            return
        }
        guard foregroundKeepaliveTask == nil else {
            UserDefaults.standard.set(reason, forKey: KeepaliveDefaults.lastReason)
            AtriaDebugLog("ATRIADBG foreground_keepalive armed=1 reason=%@ action=keep_existing_owner",
                          reason)
            return
        }
        startForegroundKeepaliveWatchdog(reason: reason)
    }

    private func startForegroundKeepaliveWatchdog(reason: String) {
        foregroundKeepaliveTask?.cancel()
        foregroundKeepaliveTask = nil
        foregroundKeepaliveReassertAt = nil
        foregroundKeepaliveLastJournalFlushAt = nil
        foregroundKeepaliveLastRawNotifications = sampleDiagnostics.rawNotifications
        let silenceTimeout: TimeInterval = 75
        let initialSilenceTimeout: TimeInterval = 8
        let initialReconnectWindow: TimeInterval = 20
        let checkInterval: TimeInterval = 20
        let armedAt = Date()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: KeepaliveDefaults.armed)
        defaults.set(armedAt.timeIntervalSince1970, forKey: KeepaliveDefaults.armedAt)
        defaults.set("armed", forKey: KeepaliveDefaults.lastStatus)
        defaults.set(reason, forKey: KeepaliveDefaults.lastReason)
        defaults.set("observe", forKey: KeepaliveDefaults.lastAction)
        defaults.set(0.0, forKey: KeepaliveDefaults.lastSilence)
        defaults.removeObject(forKey: KeepaliveDefaults.tickStartedAt)
        defaults.removeObject(forKey: KeepaliveDefaults.lastTickAt)
        AtriaDebugLog("ATRIADBG foreground_keepalive armed=1 reason=%@ silence_timeout_s=%.0f check_interval_s=%.0f",
              reason, silenceTimeout, checkInterval)
        runForegroundKeepaliveTick(
            armedAt: armedAt,
            silenceTimeout: silenceTimeout,
            initialSilenceTimeout: initialSilenceTimeout,
            initialReconnectWindow: initialReconnectWindow
        )
        foregroundKeepaliveTask = Task { @MainActor in
            while !Task.isCancelled {
                let governedInterval = checkInterval * effectiveThermalCadenceMultiplier
                try? await Task.sleep(for: .seconds(governedInterval))
                if Task.isCancelled { break }
                runForegroundKeepaliveTick(
                    armedAt: armedAt,
                    silenceTimeout: silenceTimeout,
                    initialSilenceTimeout: initialSilenceTimeout,
                    initialReconnectWindow: initialReconnectWindow
                )
            }
        }
        defaults.synchronize()
    }

    private func runForegroundKeepaliveTick(
        armedAt: Date,
        silenceTimeout: TimeInterval,
        initialSilenceTimeout: TimeInterval,
        initialReconnectWindow: TimeInterval
    ) {
        let now = Date()
        let defaults = UserDefaults.standard
        defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.tickStartedAt)
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        guard Self.isBLEContinuityRelevant(
            longWearEnabled: longWearModeEnabled,
            activeExplicitWorkout: activeExplicitWorkout
        ) else {
            defaults.set("disabled", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("wait_continuity_owner", forKey: KeepaliveDefaults.lastAction)
            return
        }
        defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastTickAt)
        defaults.set(defaults.integer(forKey: KeepaliveDefaults.ticks) + 1, forKey: KeepaliveDefaults.ticks)
        if peripheral == nil {
            recomputeConnectionStatus(reason: "foreground_keepalive_missing_peripheral")
            defaults.set("missing_peripheral", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("reconnect_known_strap", forKey: KeepaliveDefaults.lastAction)
            AtriaDebugLog("ATRIADBG foreground_keepalive status=missing_peripheral action=reconnect_known_strap saved=%d",
                          hasSavedStrap ? 1 : 0)
            if !reconnectToSavedPeripheralIfPossible(reason: "foreground_keepalive_missing_peripheral") {
                startScan(reason: "foreground_keepalive_missing_peripheral")
            }
            return
        }
        guard status == .connected, let peripheral else { return }
        guard peripheral.state == .connected else {
            recomputeConnectionStatus(reason: "foreground_keepalive_peripheral_not_connected")
            defaults.set("peripheral_not_connected", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("reconnect_known_strap", forKey: KeepaliveDefaults.lastAction)
            defaults.set(Double(peripheral.state.rawValue), forKey: KeepaliveDefaults.lastPeripheralState)
            AtriaDebugLog("ATRIADBG foreground_keepalive status=peripheral_not_connected peripheral_state=%d action=reconnect_known_strap saved=%d",
                          peripheral.state.rawValue,
                          hasSavedStrap ? 1 : 0)
            if !reconnectToSavedPeripheralIfPossible(reason: "foreground_keepalive_peripheral_state_\(peripheral.state.rawValue)") {
                startScan(reason: "foreground_keepalive_peripheral_state_\(peripheral.state.rawValue)")
            }
            return
        }
        defaults.set(Double(peripheral.state.rawValue), forKey: KeepaliveDefaults.lastPeripheralState)
        // Fall back to the keepalive's own arm time so silence is always
        // measurable — a state-restored connection (the overnight case)
        // can have no lastRawHRNotificationAt and no connectedAt at all,
        // which previously left this watchdog unable to ever fire.
        let reference = Self.latestLinkActivity([lastRawHRNotificationAt, connectedAt, armedAt]) ?? armedAt
        let silence = now.timeIntervalSince(reference)
        let hasSeenPacket = lastRawHRNotificationAt != nil
        let effectiveSilenceTimeout = hasSeenPacket ? silenceTimeout : initialSilenceTimeout
        defaults.set(silence, forKey: KeepaliveDefaults.lastSilence)
        let currentRawNotifications = sampleDiagnostics.rawNotifications
        let previousRawNotifications = foregroundKeepaliveLastRawNotifications
        foregroundKeepaliveLastRawNotifications = currentRawNotifications
        defaults.set(currentRawNotifications, forKey: KeepaliveDefaults.lastRawNotifications)
        let rawNotificationDelta: Int?
        if let previousRawNotifications {
            let delta = currentRawNotifications - previousRawNotifications
            rawNotificationDelta = delta
            defaults.set(delta, forKey: KeepaliveDefaults.lastRawNotificationDelta)
        } else {
            rawNotificationDelta = nil
        }
        defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastSampleCheckAt)
        let applicationActive = UIApplication.shared.applicationState == .active
        updateDutyCycleState(reason: "keepalive_tick", now: now)
        if Self.shouldRequestBatteryRefresh(lastRequestedAt: lastBatteryReadRequestedAt, now: now) {
            requestStrapStatusRead(reason: "keepalive_freshness")
        }
        let batteryNotificationTransportActive = batteryNotificationTransportIsActive(
            now: now,
            defaults: defaults
        )
        let recentReconnectBatteryBaselineDisplayable =
            recentReconnectBatteryBaselineIsDisplayable(
                now: now,
                defaults: defaults
            )
        let savedPeripheralIdentifier = defaults
            .string(forKey: LinkDefaults.savedPeripheralUUID)
            .flatMap(UUID.init(uuidString:))
        let reconnectBatteryBaselineAwaitingProof =
            Self.reconnectBatteryBaselineIsAwaitingProof(
                level: batteryLevel,
                acceptedAt: lastAcceptedBatteryLevelAt,
                source: defaults.string(forKey: BatteryDefaults.source) ?? "none",
                displayedIsCached: displayedBatteryLevelIsCached,
                requiresFreshConfirmation: defaults.bool(
                    forKey: BatteryDefaults.requiresFreshConfirmation
                ),
                linkConnected: peripheral.state == .connected && status == .connected,
                sameSavedPeripheral: peripheral.identifier == savedPeripheralIdentifier,
                validationStartedAt: batteryBaselineValidationStartedAt,
                now: now
            )
        if batteryLevel >= 0,
           !Self.batteryLevelIsFresh(lastAcceptedAt: lastAcceptedBatteryLevelAt, now: now),
           !recentReconnectBatteryBaselineDisplayable,
           !reconnectBatteryBaselineAwaitingProof,
           !(batteryNotificationTransportActive
                && !displayedBatteryLevelIsCached
                && !UserDefaults.standard.bool(forKey: BatteryDefaults.requiresFreshConfirmation)) {
            // A connected HR stream is not evidence that the independent 2A19
            // value is current. Fail closed instead of keeping a stale low/full
            // percentage on every screen and notification surface.
            assignIfChanged(\.batteryLevel, -1)
            assignIfChanged(\.batteryIsCharging, false)
            assignIfChanged(\.batteryChargeStatus, .levelOnly)
            assignIfChanged(\.batteryRecentlyDropping, false)
            batteryReadingIsRecentBaseline = false
            UserDefaults.standard.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
            UserDefaults.standard.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
            pendingBatteryDropCandidate = nil
            batteryProjectionRevision &+= 1
            AtriaDebugLog("ATRIADBG battery status=hidden reason=stale_live_value max_age_s=%.0f",
                          Self.batteryDisplayFreshnessLimit)
        }
        if batteryLevel >= 0,
           batteryNotificationTransportActive,
           !displayedBatteryLevelIsCached,
           !UserDefaults.standard.bool(forKey: BatteryDefaults.requiresFreshConfirmation) {
            // Keep the persisted/widget projection current without pretending a
            // new level packet arrived. The raw packet timestamp remains in
            // BatteryDefaults.at; only this subscription lease advances.
            UserDefaults.standard.set(now.timeIntervalSince1970,
                                      forKey: BatteryDefaults.notificationLeaseAt)
        }
        // While the notify stream is silent but the link is up, poll 2A37 by
        // read every tick. Low-battery evidence so far only proves coarse HR
        // may be available here; RR/detail still requires notification recovery.
        // In sparse duty-cycle mode the SAME read-poll is the sentinel, but at
        // the sparse interval instead of every tick.
        let sparseDue = dutyCycleState != .sparseSentinel
            || (lastSparsePollAt.map { now.timeIntervalSince($0) >= Self.dutyCycleSparsePollInterval } ?? true)
        if applicationActive,
           silence > 15,
           sparseDue,
           let characteristic = heartRateCharacteristic,
           characteristic.properties.contains(.read) {
            if dutyCycleState == .sparseSentinel {
                lastSparsePollAt = now
                AtriaDebugLog("ATRIADBG duty_cycle action=sparse_poll interval_s=%.0f", Self.dutyCycleSparsePollInterval)
            }
            peripheral.readValue(for: characteristic)
            defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastReadPollAt)
        }
        // Immediate stall detection: uses the persisted last-packet timestamp
        // so it fires on the very first tick after a launch/foreground return.
        // The previous delta-based check needed a second tick that a
        // suspended-or-starved process never delivered.
        let persistedLastPacketInterval = defaults.double(forKey: SampleDefaults.lastRawNotificationAt)
        let lastPacketAt = Self.latestLinkActivity([
            lastRawHRNotificationAt,
            persistedLastPacketInterval > 0 ? Date(timeIntervalSince1970: persistedLastPacketInterval) : nil,
            connectedAt,
        ]) ?? armedAt
        let stallCooldownOK = lastStallHardReconnectAt.map { now.timeIntervalSince($0) >= 120 } ?? true
        let subscribeGraceOK = connectedAt.map { now.timeIntervalSince($0) > 25 } ?? true
        let packetAge = now.timeIntervalSince(lastPacketAt)
        updateStrapStreamState(reason: "foreground_keepalive",
                               packetAge: packetAge,
                               rawNotificationDelta: rawNotificationDelta,
                               notifying: heartRateCharacteristic?.isNotifying,
                               defaults: defaults)
        if strapStreamState == .lowBatteryShutoff,
           packetAge > Self.staleHeartRatePacketThreshold {
            foregroundKeepaliveReassertAt = nil
            defaults.set("low_battery_shutoff", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("suppress_hard_reconnect", forKey: KeepaliveDefaults.lastAction)
            markLowBatteryReconnectSuppressed(reason: "low_battery_shutoff", defaults: defaults, now: now)
            AtriaDebugLog("ATRIADBG foreground_keepalive status=low_battery_shutoff battery=%d packet_age_s=%.0f action=suppress_hard_reconnect",
                          batteryLevel,
                          packetAge)
            return
        }
        let hardReconnectThreshold = max(120, silenceTimeout * effectiveThermalCadenceMultiplier)
        if applicationActive,
           !offlineHistoricalSyncInProgress,
           heartRateCharacteristic?.isNotifying == true,
           subscribeGraceOK,
           stallCooldownOK,
           now.timeIntervalSince(lastPacketAt) > hardReconnectThreshold {
            foregroundKeepaliveReassertAt = nil
            defaults.set("sample_counter_stalled", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("hard_reconnect", forKey: KeepaliveDefaults.lastAction)
            AtriaDebugLog("ATRIADBG foreground_keepalive status=sample_counter_stalled raw_notifications=%d packet_age_s=%.0f action=hard_reconnect",
                          currentRawNotifications,
                          now.timeIntervalSince(lastPacketAt))
            forceHardReconnectForPacketStall(peripheral: peripheral,
                                             reason: "foreground_keepalive_packet_age_stalled")
            return
        }
        guard silence >= effectiveSilenceTimeout else {
            foregroundKeepaliveReassertAt = nil
            defaults.set("observing", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("observe", forKey: KeepaliveDefaults.lastAction)
            // Keep the live session crash-safe even during a long foreground
            // stretch. persistActiveSessionJournalIfNeeded skips unchanged
            // values, so this once-a-minute checkpoint is cheap.
            if foregroundKeepaliveLastJournalFlushAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                foregroundKeepaliveLastJournalFlushAt = now
                flushActiveSessionJournal(reason: "foreground_keepalive_crash_safety")
            }
            return
        }
        // Sparse duty-cycle: notify is intentionally off, so a silent stream is
        // the EXPECTED state — never escalate to reassert/reconnect from here.
        if dutyCycleState == .sparseSentinel {
            foregroundKeepaliveReassertAt = nil
            defaults.set("sparse_expected_silence", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("observe", forKey: KeepaliveDefaults.lastAction)
            return
        }
        // First escalation: re-assert the 2A37 subscription and keep the
        // connection. Many silent links resume from a fresh subscribe.
        if foregroundKeepaliveReassertAt == nil {
            foregroundKeepaliveReassertAt = now
            if let characteristic = heartRateCharacteristic {
                resetHeartRateNotifyIfNeeded(peripheral: peripheral,
                                             characteristic: characteristic,
                                             reason: "foreground_keepalive")
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            } else if peripheral.state == .connected {
                peripheral.discoverServices([UUIDs.heartRateService])
            }
            defaults.set("silent", forKey: KeepaliveDefaults.lastStatus)
            defaults.set("reassert_notify", forKey: KeepaliveDefaults.lastAction)
            AtriaDebugLog("ATRIADBG foreground_keepalive status=silent silence_s=%.0f action=reassert_notify",
                  silence)
            return
        }
        // Still silent after a re-assert window: the link is effectively
        // dead. Reconnect (backoff-guarded) and let it re-establish.
        let reconnectWindow = hasSeenPacket ? silenceTimeout : initialReconnectWindow
        guard now.timeIntervalSince(foregroundKeepaliveReassertAt ?? now) >= reconnectWindow else { return }
        foregroundKeepaliveReassertAt = nil
        preserveLongWearRangeLossRecovery(reason: "foreground_keepalive")
        defaults.set("silent", forKey: KeepaliveDefaults.lastStatus)
        defaults.set("fresh_scan_reconnect", forKey: KeepaliveDefaults.lastAction)
        AtriaDebugLog("ATRIADBG foreground_keepalive status=silent silence_s=%.0f action=fresh_scan_reconnect",
              silence)
        requestFreshScanReconnect(peripheral: peripheral, reason: "foreground_keepalive")
    }

    private func stopForegroundKeepaliveWatchdog(reason: String) {
        guard foregroundKeepaliveTask != nil else { return }
        foregroundKeepaliveTask?.cancel()
        foregroundKeepaliveTask = nil
        foregroundKeepaliveReassertAt = nil
        UserDefaults.standard.set(false, forKey: KeepaliveDefaults.armed)
        UserDefaults.standard.set("stopped", forKey: KeepaliveDefaults.lastStatus)
        UserDefaults.standard.set(reason, forKey: KeepaliveDefaults.lastReason)
        UserDefaults.standard.set("stop", forKey: KeepaliveDefaults.lastAction)
        AtriaDebugLog("ATRIADBG foreground_keepalive armed=0 reason=%@", reason)
    }

    func setForegroundHighFrequencyDisplayMode(_ enabled: Bool) {
        guard foregroundHighFrequencyDisplayMode != enabled else { return }
        foregroundHighFrequencyDisplayMode = enabled
        updateDutyCycleState(reason: enabled ? "live_screen_open" : "live_screen_closed")
    }

    func handleUnattendedMode(rest: Int, maxHR: Int, reason: String) {
        if !foregroundInteractiveMode {
            ensureForegroundKeepaliveWatchdog(reason: reason)
            return
        }
        foregroundInteractiveMode = false
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        guard Self.isBLEContinuityRelevant(
            longWearEnabled: longWearModeEnabled,
            activeExplicitWorkout: activeExplicitWorkout
        ) else {
            stopForegroundKeepaliveWatchdog(reason: reason)
            return
        }
        ensureForegroundKeepaliveWatchdog(reason: reason)
        if longWearModeEnabled {
            if Self.shouldRestoreProtectedLongWearRadioInBackground(
                activeExplicitWorkout: activeExplicitWorkout
            ) {
                restoreProtectedLongWearRadioIfNeeded(reason: reason)
            }
            startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)
        }
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=0 action=resume_automation reason=%@ rest_hr=%d max_hr=%d",
              reason,
              rest,
              maxHR)
    }

    func handleSceneBackgroundTransition(reason: String,
                                         rest: Int,
                                         maxHR: Int,
                                         flushRealtimeState: Bool = true) {
        foregroundInteractiveMode = false
        if flushRealtimeState {
            flushLifecycleRealtimeState(reason: reason)
        }
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        if longWearModeEnabled {
            // A live workout owns its current radio mode. In particular, R10 step
            // calibration needs full protocol in the background; downgrading to
            // standard-HR-only here reconnects and loses both steps and HR.
            if Self.shouldRestoreProtectedLongWearRadioInBackground(
                activeExplicitWorkout: activeExplicitWorkout
            ) {
                restoreProtectedLongWearRadioIfNeeded(reason: reason)
            }
            startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)
        } else {
            ensureForegroundKeepaliveWatchdog(reason: reason)
        }
        reassertHeartRateNotificationsIfConnected(reason: reason)
        reassertR10NotificationIfConnected(reason: reason)
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=0 action=background_keep_link reason=%@ connected=%d",
              reason,
              status == .connected ? 1 : 0)
    }

    @discardableResult
    func requestOfflineHistoricalSyncIfNeeded(reason: String, force: Bool = false) -> Bool {
        if motionHandshakeDiagnostic != nil {
            recordMotionHandshakeEvidence(event: "offline_sync_blocked", detail: reason)
            return false
        }
        let defaults = UserDefaults.standard
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        let connectedLink = peripheral?.state == .connected
        let explicitUserRequest = Self.isExplicitUserOfflineSyncReason(reason)
        let verifiedPeripheralID = defaults.string(forKey: OfflineSyncDefaults.verifiedHistoryPeripheralID)
        let currentPeripheralID = peripheral?.identifier.uuidString
        let previouslyVerified = currentPeripheralID != nil && currentPeripheralID == verifiedPeripheralID
        let verifiedHistoryCapability = Self.supportsVerifiedHistoricalRecovery(
            model: strapModel,
            previouslyVerified: previouslyVerified
        )
        let verifiedMetricHistoryCapability = Self.supportsVerifiedHistoricalMetricRecovery(
            model: strapModel,
            previouslyVerified: previouslyVerified
        )
        let recoverableGapPending = Self.hasValidRangeLossBackfillRequest(
            pending: defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
            requestedAt: defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double,
            now: Date()
        )
        if recoverableGapPending,
           verifiedHistoryCapability,
           !verifiedMetricHistoryCapability,
           !explicitUserRequest {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("gap_retained_metric_history_unverified",
                         forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=gap_retained_metric_history_unverified reason=%@ detail=raw_transport_only action=preserve_realtime_and_gap explicit=0",
                          reason)
            return false
        }
        // Evaluate the narrow history-first reconnect admission before the
        // protected-R10 deferrals. Otherwise the automatic guards below return
        // before a disconnected, verified exact gap can ever be recovered.
        let protectedHistoryHandoffAllowed = Self.shouldAllowProtectedHistoricalRecovery(
            linkConnected: connectedLink,
            exactGapPending: recoverableGapPending,
            verifiedHistoryCapability: verifiedHistoryCapability,
            activeExplicitWorkout: activeExplicitWorkout,
            syncInProgress: offlineHistoricalSyncInProgress,
            explicitUserRequest: explicitUserRequest
        )
        if !protectedHistoryHandoffAllowed,
           Self.shouldDeferAutomaticOfflineSyncForProtectedR10Continuity(
            standardHROnlyMode: standardHROnlyMode,
            explicitUserRequest: explicitUserRequest
        ) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_protected_r10_continuity",
                         forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=protected_r10_continuity force=%d explicit=0 action=preserve_gap_and_realtime",
                          reason,
                          force ? 1 : 0)
            return false
        }
        if !protectedHistoryHandoffAllowed,
           Self.shouldDeferOfflineSyncForProtectedR10Qualification(
            standardHROnlyMode: standardHROnlyMode,
            stableTransportProven: defaults.bool(forKey: Self.protectedR10StableTransportKey),
            explicitUserRequest: explicitUserRequest
        ) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_protected_r10_realtime",
                         forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=protected_r10_realtime force=%d explicit=%d action=preserve_request_and_continuous_motion",
                          reason,
                          force ? 1 : 0,
                          explicitUserRequest ? 1 : 0)
            return false
        }
        if standardHROnlyMode,
           !historyOnlyProbeMode,
           !protectedHistoryHandoffAllowed {
            UserDefaults.standard.set("disabled_protected_r10_minimal",
                                      forKey: OfflineSyncDefaults.lastStatus)
            UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=skipped reason=%@ detail=protected_r10_minimal_preserve_live connected=%d pending=%d verified=%d workout=%d explicit=%d",
                          reason,
                          connectedLink ? 1 : 0,
                          defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) ? 1 : 0,
                          verifiedHistoryCapability ? 1 : 0,
                          activeExplicitWorkout ? 1 : 0,
                          explicitUserRequest ? 1 : 0)
            return false
        }
        let now = Date()
        scheduleStaleArmedRangeLossBackfillReconciliation(reason: reason, now: now)
        guard defaults.bool(forKey: OfflineSyncDefaults.enabled) else {
            defaults.set("disabled", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=skipped reason=%@ detail=disabled", reason)
            return false
        }
        guard Self.supportsVerifiedHistoricalRecovery(model: strapModel,
                                                       previouslyVerified: previouslyVerified) else {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_unverified_history_capability", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=unverified_history_capability model=%@ peripheral=%@ action=fail_closed",
                          reason,
                          strapModel.rawValue,
                          currentPeripheralID ?? "none")
            return false
        }
        // A user-started workout owns the live radio. Historical replay changes
        // services/modes and has caused repeated reconnects in the background;
        // retain the request and run it after the durable workout intent closes.
        // This applies even to a force retry: force may bypass cadence, never the
        // user's active workout continuity boundary.
        if Self.shouldDeferOfflineSyncForExplicitWorkout(
            activeExplicitWorkout: activeExplicitWorkout
        ) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_explicit_workout", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=explicit_workout_active force=%d action=preserve_live_radio",
                          reason,
                          force ? 1 : 0)
            return false
        }
        guard !offlineHistoricalSyncInProgress else {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("coalesced", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=coalesced reason=%@", reason)
            return false
        }
        // Automatic archive recovery must never seize the proprietary command
        // pipe from an already-connected realtime stream. `force` is also used
        // by the aged range-loss retry state machine, so it is not evidence of
        // user intent: after 90 seconds that path previously stopped realtime
        // HR, entered history mode, disconnected, then repeated after every
        // reconnect while the exact recovery window remained pending. Wait for
        // a naturally disconnected transport instead. A deliberate user action
        // remains able to request a connected sync.
        if Self.shouldDeferAutomaticOfflineSyncForConnectedLink(
            linkConnected: connectedLink,
            explicitUserRequest: explicitUserRequest
        ) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_connected_live_link", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred_connected_live_link reason=%@ force=%d action=preserve_realtime_until_natural_disconnect",
                          reason,
                          force ? 1 : 0)
            return false
        }
        // Historical transport shares the proprietary command pipe with live
        // HR/R10. A physical five-minute proof showed that even a successful
        // background offload could end by cancelling an otherwise healthy
        // stream. Preserve live data; the durable gap ledger keeps this request
        // pending until a natural reconnect or an explicit manual force sync.
        if !force && shouldProtectLiveStreamForOfflineSync(now: now) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_live_link", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred_live_link reason=%@ detail=live_hr_recent action=keep_ble_stream",
                          reason)
            return false
        }
        let connectedChunkedBackfill = false
        let lastAttempt = defaults.object(forKey: OfflineSyncDefaults.lastAttemptAt) as? Date
        let minimumInterval = offlineHistoricalSyncMinimumInterval(for: reason)
        if !force, let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumInterval {
            defaults.set("throttled", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=skipped reason=%@ detail=throttled age_s=%.0f min_s=%.0f",
                  reason,
                  now.timeIntervalSince(lastAttempt),
                  minimumInterval)
            return false
        }
        defaults.set(now, forKey: OfflineSyncDefaults.lastAttemptAt)
        defaults.set(defaults.integer(forKey: OfflineSyncDefaults.attempts) + 1, forKey: OfflineSyncDefaults.attempts)
        defaults.set("starting", forKey: OfflineSyncDefaults.lastStatus)
        defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
        if defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) {
            defaults.set(Date().timeIntervalSince1970, forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt)
        }
        startOfflineHistoricalSync(reason: reason,
                                   force: force,
                                   connectedChunkedBackfill: connectedChunkedBackfill)
        // Legacy static-check call shape: startOfflineHistoricalSync(reason: reason, force: force)
        return true
    }

    private func recordMotionHandshakeEvidence(event: String, detail: String = "") {
        guard let diagnostic = motionHandshakeDiagnostic else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        let sequence = defaults.integer(forKey: "atria.motionHandshake.eventSequence") + 1
        defaults.set(sequence, forKey: "atria.motionHandshake.eventSequence")
        defaults.set(event, forKey: "atria.motionHandshake.lastEvent")
        defaults.set(detail, forKey: "atria.motionHandshake.lastDetail")
        defaults.set(now, forKey: "atria.motionHandshake.lastEventAt")
        defaults.set(now, forKey: "atria.motionHandshake.\(event)At")
        AtriaDebugLog("ATRIADBG motion_handshake run=%@ seq=%d event=%@ detail=%@ unix=%.3f",
                      diagnostic.runID, sequence, event, detail, now)
    }

    private func scheduleMotionHandshakeStandardHRAddition(peripheral: CBPeripheral) {
        guard let diagnostic = motionHandshakeDiagnostic,
              motionHandshakeAddHRTask == nil else { return }
        recordMotionHandshakeEvidence(event: "stream5_notify_confirmed",
                                      detail: "add_hr_after_\(Int(diagnostic.addHRDelay))s")
        motionHandshakeAddHRTask = Task { @MainActor [weak self, weak peripheral] in
            try? await Task.sleep(for: .seconds(diagnostic.addHRDelay))
            guard let self, !Task.isCancelled,
                  let peripheral, peripheral.state == .connected else { return }
            self.recordMotionHandshakeEvidence(event: "hr_service_discovery_requested")
            peripheral.discoverServices([Self.UUIDs.heartRateService])
        }
    }

    private func sendMotionHandshakeSingleR10ActivationIfReady() {
        guard let diagnostic = motionHandshakeDiagnostic,
              diagnostic.sendSingleR10Activation,
              !motionHandshakeActivationSent else { return }
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: "atria.motionHandshake.activationAttempts") + 1,
                     forKey: "atria.motionHandshake.activationAttempts")
        guard let peripheral,
              peripheral.state == .connected,
              let txCharacteristic,
              txCharacteristic.properties.contains(.writeWithoutResponse) else {
            recordMotionHandshakeEvidence(event: "activation_not_ready",
                                          detail: "missing_connected_wwr_tx")
            return
        }

        // Command 0x3F is explicitly named sendR10R11Realtime in the locally
        // validated protocol map. Payload 0x01 enables that stream. This bypass
        // is deliberately narrower than sendCommand: exactly one 3F/01 WWR is
        // possible, only after the third launch-consent switch and active HR.
        motionHandshakeActivationSent = true
        let sequence = cmdSeq
        cmdSeq &+= 1
        let frame = encodeFrame([Packet.command, sequence, Cmd.sendR10R11Realtime, 0x01])
        let now = Date().timeIntervalSince1970
        defaults.set(now, forKey: "atria.motionHandshake.activationSentAt")
        defaults.set(Int(sequence), forKey: "atria.motionHandshake.activationSequence")
        defaults.set(defaults.integer(forKey: ProtocolDefaults.packets),
                     forKey: "atria.motionHandshake.activationProtocolPacketsBaseline")
        defaults.set(defaults.integer(forKey: ProtocolDefaults.imuFrames),
                     forKey: "atria.motionHandshake.activationIMUFramesBaseline")
        defaults.set(defaults.integer(forKey: "atria.motionHandshake.activationSentCount") + 1,
                     forKey: "atria.motionHandshake.activationSentCount")
        recordMotionHandshakeEvidence(event: "activation_3f01_sent",
                                      detail: "wwr_seq_\(sequence)_bytes_\(frame.count)")
        peripheral.writeValue(frame, for: txCharacteristic, type: .withoutResponse)
    }

    private func sendProtectedR10ActivationIfReady() {
        guard motionHandshakeDiagnostic == nil,
              standardHROnlyMode,
              !historyOnlyProbeMode,
              !protectedR10RollbackEnabled,
              !protectedR10PassiveReprobePending,
              !protectedR10ActivationSent,
              protectedR10ActivationGraceTask == nil,
              strapStream5NotifyConfirmed,
              heartRateCharacteristic?.isNotifying == true,
              let peripheral,
              peripheral.state == .connected,
              let txCharacteristic,
              txCharacteristic.properties.contains(.writeWithoutResponse) else { return }

        // First observe the passive stream. A reconnect is not proof that the
        // strap forgot a previous 3F/01, and repeatedly writing that command was
        // physically correlated with early disconnects. A fresh passive frame
        // cancels this task; otherwise the persisted lease/cooldown permits at
        // most one later activation.
        let defaults = UserDefaults.standard
        let persistedActivationAt = (defaults.object(forKey: Self.protectedR10ActivationSentAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let leaseDelay = Self.protectedR10ActivationLeaseDelay(lastActivationAt: persistedActivationAt,
                                                               now: Date())
        let observationDelay = max(Self.protectedR10PassiveGraceDuration, leaseDelay)
        protectedR10ActivationGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(observationDelay))
            guard let self, !Task.isCancelled else { return }
            self.protectedR10ActivationGraceTask = nil
            self.sendProtectedR10ActivationNowIfReady()
        }
    }

    private func sendProtectedR10ActivationNowIfReady() {
        guard motionHandshakeDiagnostic == nil,
              standardHROnlyMode,
              !historyOnlyProbeMode,
              !protectedR10RollbackEnabled,
              !protectedR10PassiveReprobePending,
              !protectedR10ActivationSent,
              strapStream5NotifyConfirmed,
              heartRateCharacteristic?.isNotifying == true,
              let peripheral,
              peripheral.state == .connected,
              let txCharacteristic,
              txCharacteristic.properties.contains(.writeWithoutResponse) else { return }

        protectedR10ActivationSent = true
        protectedR10FramesAfterActivation = 0
        let sentAt = Date()
        protectedR10ActivationAt = sentAt
        let sequence = cmdSeq
        cmdSeq &+= 1
        let frame = encodeFrame([Packet.command, sequence, Cmd.sendR10R11Realtime, 0x01])
        let defaults = UserDefaults.standard
        defaults.set(sentAt.timeIntervalSince1970, forKey: Self.protectedR10ActivationSentAtKey)
        defaults.set(defaults.integer(forKey: Self.protectedR10ActivationCountKey) + 1,
                     forKey: Self.protectedR10ActivationCountKey)
        defaults.set("activation_sent", forKey: RadioDefaults.passiveR10Status)
        AtriaDebugLog("ATRIADBG protected_r10 status=activation_sent cmd=3f data=01 mode=wwr seq=%d action=single_write",
                      Int(sequence))
        peripheral.writeValue(frame, for: txCharacteristic, type: .withoutResponse)

        protectedR10MissingFrameTask?.cancel()
        protectedR10MissingFrameTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.protectedR10MissingFrameTimeout))
            guard let self, !Task.isCancelled,
                  Self.shouldLatchProtectedR10RollbackForMissingFrames(
                    activationSent: self.protectedR10ActivationSent,
                    framesAfterActivation: self.protectedR10FramesAfterActivation
                  ) else { return }
            self.latchProtectedR10Rollback(reason: "missing_r10_after_activation")
        }
        protectedR10StabilityTask?.cancel()
        protectedR10StabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.protectedR10EarlyDisconnectWindow))
            guard let self, !Task.isCancelled,
                  self.protectedR10ActivationAt == sentAt,
                  self.peripheral?.state == .connected else { return }
            let verifiedAt = Date()
            guard Self.protectedR10StabilityWindowIsProven(
                framesAfterActivation: self.protectedR10FramesAfterActivation,
                lastFrameAt: self.lastR10MotionFrameAt,
                connectedAt: self.connectedAt,
                activationAt: sentAt,
                now: verifiedAt
            ) else {
                AtriaDebugLog("ATRIADBG protected_r10 status=stability_window_failed duration_s=%.0f frames=%d last_frame_age_s=%.1f action=rollback_without_reconnect",
                              Self.protectedR10EarlyDisconnectWindow,
                              self.protectedR10FramesAfterActivation,
                              self.lastR10MotionFrameAt.map { verifiedAt.timeIntervalSince($0) } ?? -1)
                self.latchProtectedR10Rollback(reason: "insufficient_r10_stability_density")
                return
            }
            UserDefaults.standard.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
            UserDefaults.standard.set(0, forKey: Self.protectedR10RetryCountKey)
            UserDefaults.standard.set(true, forKey: Self.protectedR10StableTransportKey)
            UserDefaults.standard.set(verifiedAt.timeIntervalSince1970,
                                      forKey: Self.protectedR10StableTransportQualifiedAtKey)
            AtriaDebugLog("ATRIADBG protected_r10 status=stable_window_complete duration_s=%.0f frames=%d action=clear_early_disconnect_streak",
                          Self.protectedR10EarlyDisconnectWindow,
                          self.protectedR10FramesAfterActivation)
        }
    }

    private func retryProtectedR10AfterStableHRIfEligible(now: Date) {
        let defaults = UserDefaults.standard
        guard motionHandshakeDiagnostic == nil,
              standardHROnlyMode,
              !offlineHistoricalSyncInProgress,
              !historyOnlyProbeEnabled,
              !historyOnlyProbeMode,
              peripheral?.state == .connected,
              let connectedAt,
              now.timeIntervalSince(connectedAt) >= Self.protectedR10RollbackRetryStableHRDuration else { return }

        if protectedR10PassiveReprobePending,
           expireProtectedR10PassiveReprobeIfNeeded(now: now,
                                                    reason: "accepted_hr_timeout_check") {
            return
        }

        if protectedR10StreamSuppressed {
            beginProtectedR10PassiveReprobeIfEligible(now: now,
                                                      connectedAt: connectedAt)
            return
        }

        // The disconnect-storm recovery owns a passive-only observation
        // window. Do not let the older rollback retry clear its command fuse;
        // only dense, current-connection CRC-valid R10 evidence may do that.
        guard !protectedR10PassiveReprobePending,
              defaults.bool(forKey: Self.protectedR10RollbackKey) else { return }
        let retryCount = max(0, defaults.integer(forKey: Self.protectedR10RetryCountKey))
        let multiplier = pow(2.0, Double(min(retryCount, 5)))
        let delay = min(Self.protectedR10RollbackRetryBaseDelay * multiplier,
                        Self.protectedR10RollbackRetryMaximumDelay)
        let rollbackAt = defaults.double(forKey: "atria.protectedR10.rollbackAt")
        guard rollbackAt > 0, now.timeIntervalSince1970 - rollbackAt >= delay,
              let peripheral else { return }

        defaults.set(false, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.set(retryCount + 1, forKey: Self.protectedR10RetryCountKey)
        defaults.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
        defaults.set("retry_after_stable_2a37", forKey: RadioDefaults.passiveR10Status)
        protectedR10ActivationGraceTask?.cancel()
        protectedR10ActivationGraceTask = nil
        protectedR10ActivationSent = false
        protectedR10ActivationAt = nil
        protectedR10FramesAfterActivation = 0
        AtriaDebugLog("ATRIADBG protected_r10 status=rollback_retry retry=%d stable_hr_s=%.0f cooldown_s=%.0f action=discover_minimal_service_no_reconnect",
                      retryCount + 1,
                      now.timeIntervalSince(connectedAt),
                      delay)
        let cachedServices = peripheral.services ?? []
        if cachedServices.contains(where: { $0.uuid == Self.UUIDs.strapService }) {
            resumeProtectedR10FromRestoredCache(peripheral)
        } else {
            peripheral.discoverServices([Self.UUIDs.heartRateService, Self.UUIDs.strapService])
        }
    }

    private func beginProtectedR10PassiveReprobeIfEligible(now: Date,
                                                           connectedAt: Date) {
        let defaults = UserDefaults.standard
        let stormAt = (defaults.object(forKey: Self.protectedR10DisconnectStormAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let lastAttemptAt = (defaults.object(forKey: Self.protectedR10PassiveReprobeAttemptAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let latestHRAge = lastRawHRNotificationAt.map { now.timeIntervalSince($0) }
        guard Self.shouldBeginProtectedR10PassiveReprobe(
            streamSuppressed: protectedR10StreamSuppressed,
            reprobePending: protectedR10PassiveReprobePending,
            connected: status == .connected && peripheral?.state == .connected,
            stableHRDuration: now.timeIntervalSince(connectedAt),
            latestHRAge: latestHRAge,
            disconnectStormAge: stormAt.map { now.timeIntervalSince($0) },
            lastAttemptAge: lastAttemptAt.map { now.timeIntervalSince($0) },
            failureCount: defaults.integer(forKey: Self.protectedR10PassiveReprobeFailureCountKey),
            batteryLevel: motionEligibilityBatteryLevel(now: now),
            isCharging: motionEligibilityIsCharging
        ), let peripheral else { return }

        defaults.set(now.timeIntervalSince1970,
                     forKey: Self.protectedR10PassiveReprobeAttemptAtKey)
        defaults.set(true, forKey: Self.protectedR10PassiveReprobePendingKey)
        defaults.set(false, forKey: Self.protectedR10StreamSuppressedKey)
        // Keep every command path fail-closed. recordProtectedR10EvidenceIfNeeded
        // clears this only after the existing 85 s / 75-frame passive proof.
        defaults.set(true, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.set("passive_reprobe_after_stable_hr",
                     forKey: "atria.protectedR10.rollbackReason")
        defaults.set("passive_reprobe_discovering_stream5",
                     forKey: RadioDefaults.passiveR10Status)
        protectedR10ActivationGraceTask?.cancel()
        protectedR10ActivationGraceTask = nil
        protectedR10ActivationSent = false
        protectedR10ActivationAt = nil
        protectedR10FramesAfterActivation = 0
        peripheral.discoverServices([Self.UUIDs.strapService])
        scheduleProtectedR10PassiveReprobeTimeout(now: now)
        AtriaDebugLog("ATRIADBG protected_r10 status=passive_reprobe_started stable_hr_s=%.0f storm_age_s=%.0f failures=%d action=discover_stream5_existing_link_no_reconnect_no_command",
                      now.timeIntervalSince(connectedAt),
                      stormAt.map { now.timeIntervalSince($0) } ?? -1,
                      defaults.integer(forKey: Self.protectedR10PassiveReprobeFailureCountKey))
    }

    private func scheduleProtectedR10PassiveReprobeTimeout(now: Date = Date()) {
        protectedR10PassiveReprobeTimeoutTask?.cancel()
        protectedR10PassiveReprobeTimeoutTask = nil
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.protectedR10PassiveReprobePendingKey) else { return }
        let attemptAt = (defaults.object(forKey: Self.protectedR10PassiveReprobeAttemptAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let age = attemptAt.map { now.timeIntervalSince($0) }
        if Self.protectedR10PassiveReprobeHasExpired(reprobePending: true,
                                                     attemptAge: age) {
            _ = expireProtectedR10PassiveReprobeIfNeeded(now: now,
                                                         reason: "restored_stale_pending")
            return
        }
        let remaining = max(0, Self.protectedR10PassiveReprobeTimeout - (age ?? 0))
        protectedR10PassiveReprobeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard let self, !Task.isCancelled else { return }
            self.protectedR10PassiveReprobeTimeoutTask = nil
            _ = self.expireProtectedR10PassiveReprobeIfNeeded(
                now: Date(),
                reason: "no_crc_valid_r10_timeout"
            )
        }
    }

    @discardableResult
    private func expireProtectedR10PassiveReprobeIfNeeded(now: Date,
                                                          reason: String) -> Bool {
        let defaults = UserDefaults.standard
        let attemptAt = (defaults.object(forKey: Self.protectedR10PassiveReprobeAttemptAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        guard Self.protectedR10PassiveReprobeHasExpired(
            reprobePending: defaults.bool(forKey: Self.protectedR10PassiveReprobePendingKey),
            attemptAge: attemptAt.map { now.timeIntervalSince($0) }
        ) else { return false }
        let failures = defaults.integer(forKey: Self.protectedR10PassiveReprobeFailureCountKey) + 1
        defaults.set(failures, forKey: Self.protectedR10PassiveReprobeFailureCountKey)
        defaults.set(false, forKey: Self.protectedR10PassiveReprobePendingKey)
        defaults.set(true, forKey: Self.protectedR10StreamSuppressedKey)
        defaults.set("passive_reprobe_no_valid_r10",
                     forKey: Self.protectedR10DisconnectStormReasonKey)
        defaults.set("passive_reprobe_timed_out_hr_preserved",
                     forKey: RadioDefaults.passiveR10Status)
        protectedR10PassiveReprobeTimeoutTask?.cancel()
        protectedR10PassiveReprobeTimeoutTask = nil
        if let peripheral,
           peripheral.state == .connected,
           let stream5 = peripheral.services?
            .first(where: { $0.uuid == Self.UUIDs.strapService })?
            .characteristics?
            .first(where: { $0.uuid == Self.UUIDs.strapStream5 }),
           stream5.isNotifying {
            // The probe timed out without transport proof. Stop the attempted
            // radio source itself; merely ignoring callbacks would leave the
            // strap transmitting the stream that may have caused the storm.
            peripheral.setNotifyValue(false, for: stream5)
        }
        strapStream5NotifyConfirmed = false
        activeProprietaryNotifyUUIDs.remove(Self.UUIDs.strapStream5)
        stopR10LivenessWatchdog(reason: "passive_reprobe_timeout")
        AtriaDebugLog("ATRIADBG protected_r10 status=passive_reprobe_timeout reason=%@ failures=%d action=resuppress_stream5_keep_existing_hr_link_no_command",
                      reason,
                      failures)
        return true
    }

    /// CoreBluetooth restoration can hand back a connected peripheral whose
    /// services/characteristics are already cached without replaying every
    /// discovery callback. Rehydrate the protected R10 prerequisites directly
    /// from that cache so a Release reinstall cannot leave HR healthy while the
    /// motion stream silently stays dormant.
    private func resumeProtectedR10FromRestoredCache(_ peripheral: CBPeripheral) {
        guard standardHROnlyMode,
              !historyOnlyProbeMode,
              !protectedR10StreamSuppressed,
              peripheral.state == .connected else { return }

        var cachedHR: CBCharacteristic?
        var cachedStream5: CBCharacteristic?
        var cachedTX: CBCharacteristic?
        var cachedBattery: CBCharacteristic?
        for service in peripheral.services ?? [] {
            if service.uuid == Self.UUIDs.heartRateService {
                guard let characteristics = service.characteristics else {
                    peripheral.discoverCharacteristics([Self.UUIDs.heartRateMeasure], for: service)
                    continue
                }
                cachedHR = characteristics.first { $0.uuid == Self.UUIDs.heartRateMeasure }
            } else if service.uuid == Self.UUIDs.strapService {
                guard let characteristics = service.characteristics else {
                    peripheral.discoverCharacteristics([Self.UUIDs.strapStream5, Self.UUIDs.strapTX], for: service)
                    continue
                }
                cachedStream5 = characteristics.first { $0.uuid == Self.UUIDs.strapStream5 }
                cachedTX = characteristics.first { $0.uuid == Self.UUIDs.strapTX }
            } else if service.uuid == Self.UUIDs.batteryService {
                guard let characteristics = service.characteristics else {
                    peripheral.discoverCharacteristics([Self.UUIDs.batteryLevel], for: service)
                    continue
                }
                cachedBattery = characteristics.first { $0.uuid == Self.UUIDs.batteryLevel }
            }
        }

        if let cachedHR {
            heartRateCharacteristic = cachedHR
            if cachedHR.properties.contains(.notify), !cachedHR.isNotifying {
                peripheral.setNotifyValue(true, for: cachedHR)
            }
        }
        if let cachedTX, cachedTX.properties.contains(.writeWithoutResponse) {
            txCharacteristic = cachedTX
            dbgTxReady = true
        }
        if let cachedStream5, cachedStream5.properties.contains(.notify) {
            if cachedStream5.isNotifying {
                activeProprietaryNotifyUUIDs.insert(Self.UUIDs.strapStream5)
                strapStream5NotifyConfirmed = true
                markPassiveR10SubscriptionConfirmed()
            } else {
                peripheral.setNotifyValue(true, for: cachedStream5)
            }
        }
        if let cachedBattery {
            batteryLevelCharacteristic = cachedBattery
            if cachedBattery.properties.contains(.notify) || cachedBattery.properties.contains(.indicate) {
                if cachedBattery.isNotifying {
                    let now = Date().timeIntervalSince1970
                    UserDefaults.standard.set(now,
                                              forKey: BatteryDefaults.notificationConfirmedAt)
                    UserDefaults.standard.removeObject(forKey: BatteryDefaults.notificationLastError)
                    if let heartRateReceivedAt = lastRawHRNotificationAt {
                        promoteReconnectBatteryBaselineIfSafe(
                            now: Date(timeIntervalSince1970: now),
                            heartRateReceivedAt: heartRateReceivedAt,
                            reason: "2A19_restored_cache_notify_active"
                        )
                    }
                } else {
                    UserDefaults.standard.set(Date().timeIntervalSince1970,
                                              forKey: BatteryDefaults.notificationRequestedAt)
                    peripheral.setNotifyValue(true, for: cachedBattery)
                }
            }
        }
        AtriaDebugLog("ATRIADBG protected_r10 status=restored_cache_rehydrated services=%d hr=%d stream5=%d tx=%d stream5_notifying=%d action=resume_minimal_transport",
                      peripheral.services?.count ?? 0,
                      cachedHR == nil ? 0 : 1,
                      cachedStream5 == nil ? 0 : 1,
                      cachedTX == nil ? 0 : 1,
                      cachedStream5?.isNotifying == true ? 1 : 0)
        sendProtectedR10ActivationIfReady()
    }

    private func latchProtectedR10Rollback(reason: String) {
        guard motionHandshakeDiagnostic == nil else { return }
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: Self.protectedR10RollbackKey)
        defaults.set(false, forKey: Self.protectedR10StableTransportKey)
        defaults.removeObject(forKey: Self.protectedR10StableTransportQualifiedAtKey)
        defaults.set(reason, forKey: "atria.protectedR10.rollbackReason")
        defaults.set(Date().timeIntervalSince1970, forKey: "atria.protectedR10.rollbackAt")
        defaults.set("activation_suppressed_observing_passive_r10",
                     forKey: RadioDefaults.passiveR10Status)
        protectedR10ActivationGraceTask?.cancel()
        protectedR10ActivationGraceTask = nil
        protectedR10MissingFrameTask?.cancel()
        protectedR10MissingFrameTask = nil
        protectedR10StabilityTask?.cancel()
        protectedR10StabilityTask = nil
        // Never unsubscribe, cancel, rediscover, or reconnect here. Those
        // interventions caused the old loop. Keep the healthy 2A37 link and
        // apply pure-HR discovery only after the next natural connection edge.
        AtriaDebugLog("ATRIADBG protected_r10 status=activation_suppressed reason=%@ action=preserve_2a37_and_passive_stream5_no_reconnect_no_more_commands",
                      reason)
    }

    private func startOfflineHistoricalSync(reason: String, force: Bool) {
        // Legacy static-check order from the removed late live-link deferral:
        // force || !shouldProtectLiveStreamForOfflineSync(now: Date())
        // central.cancelPeripheralConnection(peripheral)
        // recomputeConnectionStatus(reason: "offline_sync_stale_peripheral")
        startOfflineHistoricalSync(reason: reason,
                                   force: force,
                                   connectedChunkedBackfill: false)
    }

    private func startOfflineHistoricalSync(reason: String,
                                            force: Bool,
                                            connectedChunkedBackfill: Bool) {
        flushActiveSessionJournal(reason: "offline_sync_preflight_\(reason)")
        offlineHistoricalSyncPreviousStandardHROnlyMode = standardHROnlyMode
        offlineHistoricalSyncStartRows = historicalArchiveRows
        offlineHistoricalSyncMadeRequestedMetricProgress = false
        offlineHistoricalSyncResolvedGapCoverage = false
        offlineHistoricalSyncInProgress = true
        offlineHistoricalSyncGeneration &+= 1
        let syncGeneration = offlineHistoricalSyncGeneration
        offlineHistoricalSyncReason = reason
        historyDrainGate.begin(generation: syncGeneration)
        pendingHistoryEndACK = nil
        pendingHistoryACKAttempts = 0
        historyDurableFlushInFlight = false
        historicalArchiveWriteFailures = 0
        let preserveDebugHistoryRangeProbe = historyOnlyProbeEnabled
            && (historySelectorSweepEnabled || historyDataRangeSweepEnabled)
            && !historySkipDataRangeRequest
        historyOnlyProbeEnabled = true
        historyOnlyProbeMode = true
        historyOnlyProbeArmed = false
        historyClockSyncEnabled = true
        historicalAckDisabled = false
        historyAckMode = "enddata"
        probeCommandMode = .withResponse
        if preserveDebugHistoryRangeProbe {
            if historyInitSweepCommands.isEmpty {
                historyInitSweepCommands = [
                    [Cmd.abortHistoricalTransmits, 0x00],
                    [Cmd.enterHighFreqSync, 0x00],
                ]
            }
            historySkipDataRangeRequest = false
        } else {
            // Production WHOOP 4 recovery uses the stable, bounded offload
            // request directly. Abort and high-frequency-sync are research
            // controls: inserting them into the production handshake can leave
            // an otherwise connected strap returning zero historical frames.
            historyInitSweepCommands = Self.productionHistoricalRecoveryInitCommands()
            historySkipDataRangeRequest = true
        }
        if !preserveDebugHistoryRangeProbe {
            historyDataRangeSweepEnabled = false
        }
        historyDataRangePendingRequests.removeAll()
        ackedHistoryAckKeys.removeAll()
        realtimeArmed = false
        realtimeOn = false
        // 0x03/0 is the verified realtime-HR stop. Do not guess an R10 stop
        // payload; cancelling its watchdog and withholding re-arm isolates the
        // shared proprietary pipe until history reaches a terminal state.
        sendCommand(Cmd.toggleRealtimeHR, [0x00], mode: .withResponse)
        txCharacteristic = nil
        UserDefaults.standard.set("armed", forKey: OfflineSyncDefaults.lastStatus)
        UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
        let initSweepLabel = historyInitSweepCommands
            .map { Self.hex($0) }
            .joined(separator: ",")
        // Legacy static-check token from the pre-HIST-1 fail-closed path:
        // live_realtime=skipped metrics_fail_closed=1
        AtriaDebugLog("ATRIADBG offline_sync status=armed reason=%@ mode=%@ init_sweep=%@ ack_mode=enddata live_realtime=skipped metrics_fail_closed=0 cmd22=%d connected_chunked=%d",
              reason,
              connectedChunkedBackfill ? "connected_chunked_backfill" : (preserveDebugHistoryRangeProbe ? "selector_probe" : "safe_history_backfill"),
              initSweepLabel,
              historySkipDataRangeRequest ? 0 : 1,
              connectedChunkedBackfill ? 1 : 0)

        if let peripheral {
            dbgLast = "offline sync reconnect"
            switch peripheral.state {
            case .connected:
                peripheral.discoverServices(discoveryServicesForCurrentMode)
                AtriaDebugLog("ATRIADBG offline_sync status=connected_chunked reason=%@ action=discover_services_without_live_link_deferral samples=%d",
                              reason,
                              session.count)
            case .connecting:
                if force {
                    cancelPeripheralConnection(peripheral,
                                               reason: "offline_sync_force_while_connecting")
                }
            default:
                self.peripheral = nil
                recomputeConnectionStatus(reason: "offline_sync_stale_peripheral")
                if central.state == .poweredOn {
                    startScan(reason: "offline_sync_\(reason)")
                }
            }
        } else if central.state == .poweredOn {
            startScan(reason: "offline_sync_\(reason)")
        }

        offlineHistoricalSyncTimeoutTask?.cancel()
        offlineHistoricalSyncTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            finishOfflineHistoricalSync(reason: "\(reason)_timeout", generation: syncGeneration)
        }
    }

    private func finishOfflineHistoricalSync(reason: String, generation: UInt64) {
        guard offlineHistoricalSyncInProgress,
              generation == offlineHistoricalSyncGeneration else {
            AtriaDebugLog("ATRIADBG offline_sync status=ignored reason=%@ detail=stale_completion generation=%llu current=%llu",
                          reason,
                          generation,
                          offlineHistoricalSyncGeneration)
            return
        }
        let rows = historicalArchiveRows
        let newRows = max(0, rows - offlineHistoricalSyncStartRows)
        historyOnlyProbeEnabled = false
        historyOnlyProbeMode = false
        historyOnlyProbeArmed = false
        historyClockSyncEnabled = false
        historyInitSweepCommands.removeAll()
        historySkipDataRangeRequest = false
        probeCommandMode = .withoutResponse
        offlineHistoricalSyncInProgress = false
        offlineHistoricalSyncTimeoutTask?.cancel()
        offlineHistoricalSyncTimeoutTask = nil
        offlineHistoricalSyncStartRows = rows
        let completionStatus = Self.historicalSyncCompletionStatus(
            newRows: newRows,
            requestedWindowMetricProgress: offlineHistoricalSyncMadeRequestedMetricProgress,
            ledgerCoverageResolved: offlineHistoricalSyncResolvedGapCoverage
        )
        UserDefaults.standard.set(completionStatus, forKey: OfflineSyncDefaults.lastStatus)
        UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
        AtriaDebugLog("ATRIADBG offline_sync status=%@ reason=%@ rows=%d new_rows=%d failures=%d action=return_standard_hr metrics_fail_closed=0",
              completionStatus,
              reason,
              rows,
              newRows,
              historicalArchiveWriteFailures)
        // Static handoff compatibility markers for the original clear gate:
        // if defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        // defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        // assignIfChanged(\.rangeLossBackfillPending, false)
        // if newRows > 0
        if !reconcileRangeLossBackfillPendingWithArchive(
            reason: reason,
            newRows: newRows,
            requestedWindowMetricProgress: offlineHistoricalSyncMadeRequestedMetricProgress,
            ledgerCoverageResolved: offlineHistoricalSyncResolvedGapCoverage
        ) {
            scheduleRangeLossBackfillRetry(reason: reason)
        }
        let restoredStandardHROnlyMode = Self.standardHROnlyModeAfterOfflineSync(
            modeBeforeSync: offlineHistoricalSyncPreviousStandardHROnlyMode
        )
        applyStandardHROnly(enabled: restoredStandardHROnlyMode,
                            persist: false,
                            reconnect: false,
                            reason: "offline_sync_complete_preserve_live_radio")
        if txCharacteristic != nil {
            armRealtime()
        } else {
            peripheral?.discoverServices(discoveryServicesForCurrentMode)
        }
        AtriaDebugLog("ATRIADBG offline_sync status=complete reason=%@ action=preserve_live_connection",
                      reason)
        if let pending = pendingOfflineHistoricalSyncReason {
            pendingOfflineHistoricalSyncReason = nil
            requestOfflineHistoricalSyncIfNeeded(reason: pending)
        }
    }

    @discardableResult
    private func reconcileRangeLossBackfillPendingWithArchive(reason: String,
                                                             newRows: Int = 0,
                                                             requestedWindowMetricProgress: Bool = false,
                                                             ledgerCoverageResolved: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else { return true }
        // A successful offload is not proof that it covered every live outage.
        // The durable gap ledger retires intervals only from metric-usable rows
        // spanning at least 75% of their exact timestamp buckets.
        guard !AtriaHistoricalGapLedger.hasPendingWindows(defaults: defaults) else {
            AtriaDebugLog("ATRIADBG offline_sync status=range_loss_retained reason=%@ detail=missing_windows_not_covered windows=%d",
                          reason,
                          AtriaHistoricalGapLedger.windows(defaults: defaults).count)
            return false
        }
        let archiveDiagnostics = HistoricalArchive.diagnostics()
        let archiveAlreadyMetricReady = archiveDiagnostics.parseOK
            && archiveDiagnostics.metricUsableRows > 0
            && archiveDiagnostics.currentSessionUsableRows > 0
        // Global archive readiness says nothing about the newly missing range.
        // The gym failure had an old, healthy archive yet no rows covering the
        // workout; clearing on `archiveAlreadyMetricReady` silently discarded the
        // recovery request. Only rows appended by this sync can acknowledge it.
        let hasRequestedWindow = defaults.object(forKey: OfflineSyncDefaults.recoveryWindowStart) != nil
            && defaults.object(forKey: OfflineSyncDefaults.recoveryWindowEnd) != nil
        guard Self.rangeLossBackfillCanClear(newRows: newRows,
                                             hasRequestedWindow: hasRequestedWindow,
                                             requestedWindowMetricProgress: requestedWindowMetricProgress,
                                             ledgerCoverageResolved: ledgerCoverageResolved) else { return false }
        defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.removeObject(forKey: OfflineSyncDefaults.recoveryWindowStart)
        defaults.removeObject(forKey: OfflineSyncDefaults.recoveryWindowEnd)
        defaults.set(Date().timeIntervalSince1970, forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt)
        assignIfChanged(\.rangeLossBackfillPending, false)
        AtriaDebugLog("ATRIADBG offline_sync status=range_loss_backfill_cleared reason=%@ new_rows=%d metric_ready=%d metric_rows=%d current_rows=%d",
                      reason,
                      newRows,
                      archiveAlreadyMetricReady ? 1 : 0,
                      archiveDiagnostics.metricUsableRows,
                      archiveDiagnostics.currentSessionUsableRows)
        return true
    }

    private func markRangeLossBackfillRequired(reason: String) {
        let defaults = UserDefaults.standard
        let alreadyPending = defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        if !alreadyPending || defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        }
        defaults.set(true, forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(reason, forKey: OfflineSyncDefaults.rangeLossBackfillReason)
        assignIfChanged(\.rangeLossBackfillPending, true)
        pendingOfflineHistoricalSyncReason = reason
        AtriaDebugLog("ATRIADBG offline_sync status=pending_range_loss_backfill reason=%@ action=sync_after_reconnect already_pending=%d",
              reason,
              alreadyPending ? 1 : 0)
    }

    private func preserveLongWearRangeLossRecovery(reason: String) {
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        persistActiveSessionJournalIfNeeded(reason: "\(reason)_continuity_checkpoint", force: true)
        guard longWearModeEnabled || activeExplicitWorkout else {
            // Balanced/on-demand mode still receives transient link drops. Keep
            // its live session durable and let the standard 90-second sample-gap
            // gate decide whether the reconnect belongs to a new segment.
            AtriaDebugLog("ATRIADBG active_session_journal status=checkpointed reason=%@ mode=unexpected_disconnect_grace samples=%d",
                          reason,
                          session.count)
            return
        }
        // Off-wrist long-wear disconnects do not represent recoverable HR. A
        // user-started workout is still tracked from the disconnect instant if
        // its first accepted sample has not arrived yet.
        if activeExplicitWorkout || hasContact {
            let missingStart = lastAcceptedHRAt ?? Date()
            _ = AtriaHistoricalGapLedger.beginGap(at: missingStart,
                                                  reason: activeExplicitWorkout
                                                    ? "explicit_workout_disconnect"
                                                    : reason)
        }
        guard activeExplicitWorkout
                || hasContact
                || AtriaHistoricalGapLedger.hasPendingWindows() else {
            AtriaDebugLog("ATRIADBG offline_sync status=range_loss_skipped reason=%@ detail=off_wrist_no_recoverable_gap action=preserve_realtime_only",
                          reason)
            return
        }
        guard !offlineHistoricalSyncInProgress else {
            // A disconnect inside an opportunistic sync is still a missing range.
            // Mark it now; finishOfflineHistoricalSync will clear it only when
            // that same attempt actually appended rows.
            markRangeLossBackfillRequired(reason: activeExplicitWorkout
                                          ? "explicit_workout_range_loss"
                                          : "long_wear_range_loss")
            AtriaDebugLog("ATRIADBG offline_sync status=range_loss_marked reason=%@ detail=sync_in_progress explicit_workout=%d action=reconcile_on_sync_finish",
                          reason,
                          activeExplicitWorkout ? 1 : 0)
            return
        }
        let backfillReason = activeExplicitWorkout
            ? "explicit_workout_range_loss"
            : (strapStreamState == .lowBatteryShutoff
            ? "strap_low_battery_broadcast_off"
            : "long_wear_range_loss")
        markRangeLossBackfillRequired(reason: backfillReason)
        if status == .connected {
            scheduleRangeLossBackfillIfNeeded(reason: reason)
        }
    }

    private func scheduleRangeLossBackfillIfNeeded(reason: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.enabled) else { return }
        scheduleStaleArmedRangeLossBackfillReconciliation(reason: reason)
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else { return }
        guard !offlineHistoricalSyncInProgress else { return }
        let verifiedPeripheralID = defaults.string(forKey: OfflineSyncDefaults.verifiedHistoryPeripheralID)
        let currentPeripheralID = peripheral?.identifier.uuidString
        let previouslyVerified = currentPeripheralID != nil
            && currentPeripheralID == verifiedPeripheralID
        let rawHistoryVerified = Self.supportsVerifiedHistoricalRecovery(
            model: strapModel,
            previouslyVerified: previouslyVerified
        )
        if rawHistoryVerified,
           !Self.supportsVerifiedHistoricalMetricRecovery(
                model: strapModel,
                previouslyVerified: previouslyVerified
           ) {
            rangeLossBackfillTask?.cancel()
            rangeLossBackfillTask = nil
            defaults.set("gap_retained_metric_history_unverified",
                         forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=gap_retained_metric_history_unverified reason=%@ detail=automatic_retry_suppressed_raw_transport_only action=keep_gap_and_realtime",
                          reason)
            return
        }
        rangeLossBackfillTask?.cancel()
        rangeLossBackfillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else { return }
            guard status != .poweredOff else { return }
            let backfillReason = UserDefaults.standard.string(forKey: OfflineSyncDefaults.rangeLossBackfillReason) ?? reason
            let protectedLiveStream = shouldProtectLiveStreamForOfflineSync()
            let forceStaleBackfill = !protectedLiveStream && shouldForceStaleRangeLossBackfill()
            let forceReadyBackfill = !protectedLiveStream && shouldForceReadyRangeLossBackfill()
            let forceBackfill = forceStaleBackfill || forceReadyBackfill
            let action = forceBackfill
                ? (forceStaleBackfill ? "force_stale_backfill" : "force_ready_backfill")
                : (protectedLiveStream ? "defer_live_stream" : "sync_when_available")
            AtriaDebugLog("ATRIADBG offline_sync status=requesting_range_loss_backfill reason=%@ trigger=%@ action=%@ live_protected=%d stale_force=%d ready_force=%d",
                  backfillReason,
                  reason,
                  action,
                  protectedLiveStream ? 1 : 0,
                  forceStaleBackfill ? 1 : 0,
                  forceReadyBackfill ? 1 : 0)
            let syncStarted = requestOfflineHistoricalSyncIfNeeded(reason: backfillReason, force: forceBackfill)
            let stillPending = UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending)
            AtriaDebugLog("ATRIADBG offline_sync status=range_loss_backfill_request_result reason=%@ started=%d pending=%d force=%d action=%@",
                          backfillReason,
                          syncStarted ? 1 : 0,
                          stillPending ? 1 : 0,
                          forceBackfill ? 1 : 0,
                          action)
            if !syncStarted, stillPending {
                scheduleRangeLossBackfillRetry(reason: reason)
            }
        }
    }

    func schedulePendingHistoricalRecovery(reason: String) {
        assignIfChanged(\.rangeLossBackfillPending,
                        UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending))
        scheduleRangeLossBackfillIfNeeded(reason: reason)
    }

    private func scheduleRangeLossBackfillRetry(reason: String) {
        rangeLossBackfillTask?.cancel()
        rangeLossBackfillTask = Task { @MainActor in
            let delay = rangeLossBackfillRetryDelay()
            AtriaDebugLog("ATRIADBG offline_sync status=retry_scheduled reason=%@ delay_s=%.0f ready_force_after_s=%.0f",
                          reason,
                          delay,
                          rangeLossBackfillReadyForceInterval)
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            scheduleRangeLossBackfillIfNeeded(reason: "\(reason)_retry")
        }
    }

    private func scheduleStaleArmedRangeLossBackfillReconciliation(reason: String,
                                                                   now: Date = Date()) {
        let defaults = UserDefaults.standard
        let lastStatus = defaults.string(forKey: OfflineSyncDefaults.lastStatus) ?? ""
        let clearableStatuses = ["armed", "archived", "archive_metric_ready", "throttled", "no_rows"]
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
              clearableStatuses.contains(lastStatus),
              let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double,
              let startedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double,
              now.timeIntervalSince1970 - requestedAt >= rangeLossBackfillArmedTimeout else {
            return
        }
        guard !powerThermalGovernor.shouldDeferNonEssentialAnalysis else { return }
        let minimumInterval: TimeInterval = 2 * 60
        guard Self.shouldScheduleStaleRangeLossReconciliation(
            inFlight: staleRangeLossReconciliationInFlight,
            lastAttemptAt: lastStaleRangeLossReconciliationAttemptAt,
            now: now,
            minimumInterval: minimumInterval
        ) else { return }
        staleRangeLossReconciliationInFlight = true
        lastStaleRangeLossReconciliationAttemptAt = now
        // Do not clear from global archive readiness. That proves only that some
        // historical range decoded in the past, not that the requested outage is
        // present. Keep the durable request armed; didConnect / the retry state
        // machine will run another bounded sync and only `newRows > 0` may ack it.
        staleRangeLossReconciliationInFlight = false
        AtriaDebugLog("ATRIADBG offline_sync status=stale_armed_retained reason=%@ last_status=%@ requested_age_s=%.0f armed_age_s=%.0f action=retry_until_new_rows",
                      reason,
                      lastStatus,
                      now.timeIntervalSince1970 - requestedAt,
                      now.timeIntervalSince1970 - startedAt)
    }

    nonisolated static func shouldScheduleStaleRangeLossReconciliation(
        inFlight: Bool,
        lastAttemptAt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard !inFlight else { return false }
        guard let lastAttemptAt else { return true }
        return now.timeIntervalSince(lastAttemptAt) >= minimumInterval
    }

    nonisolated static func shouldDeferOfflineSyncForExplicitWorkout(
        activeExplicitWorkout: Bool
    ) -> Bool {
        activeExplicitWorkout
    }

    nonisolated static func isExplicitUserOfflineSyncReason(_ reason: String) -> Bool {
        reason == "manual_user_request"
            || reason == "pull_to_refresh"
            || reason == "home_missed_data_banner"
    }

    /// A durable pending bit without its request record may be a legacy or
    /// partially-written value. Do not trade protected realtime transport for
    /// history unless the gap request has a plausible persisted timestamp.
    nonisolated static func hasValidRangeLossBackfillRequest(
        pending: Bool,
        requestedAt: Double?,
        now: Date
    ) -> Bool {
        guard pending,
              let requestedAt,
              requestedAt.isFinite,
              requestedAt > 0 else { return false }
        return requestedAt <= now.timeIntervalSince1970 + 5
    }

    /// Protected production mode may enter history transport automatically
    /// only while the radio is already down. This turns a natural reconnect
    /// into a one-shot history-first handoff without ever taking the command
    /// pipe away from healthy HR/R10. A deliberate UI request may run while
    /// connected, but it still cannot preempt an active workout or bypass the
    /// verified WHOOP 4-class capability gate.
    nonisolated static func shouldAllowProtectedHistoricalRecovery(
        linkConnected: Bool,
        exactGapPending: Bool,
        verifiedHistoryCapability: Bool,
        activeExplicitWorkout: Bool,
        syncInProgress: Bool,
        explicitUserRequest: Bool
    ) -> Bool {
        guard verifiedHistoryCapability,
              !activeExplicitWorkout,
              !syncInProgress else { return false }
        if explicitUserRequest { return true }
        return exactGapPending && !linkConnected
    }

    nonisolated static func shouldDeferAutomaticOfflineSyncForConnectedLink(
        linkConnected: Bool,
        explicitUserRequest: Bool
    ) -> Bool {
        linkConnected && !explicitUserRequest
    }

    /// The production history handshake is intentionally one command. Debug
    /// selector/range experiments retain their configurable preflight above,
    /// but recovery must not enter or abort another protocol mode first.
    nonisolated static func productionHistoricalRecoveryInitCommands() -> [[UInt8]] {
        [[Cmd.sendHistoricalData, 0x00]]
    }

    /// Offline replay is a transport operation, not a settings mutation. Restore
    /// the exact effective mode that was active before replay, including a
    /// temporary full-protocol calibration/step-capture override.
    nonisolated static func standardHROnlyModeAfterOfflineSync(
        modeBeforeSync: Bool
    ) -> Bool {
        modeBeforeSync
    }

    nonisolated static func shouldRestoreProtectedLongWearRadioInBackground(
        activeExplicitWorkout: Bool
    ) -> Bool {
        !activeExplicitWorkout
    }

    /// Preserve the radio mode that the launch safety policy persisted. A
    /// background edge must never silently undo protected standard-HR mode and
    /// re-enable a proprietary stream that failed the physical stability soak.
    /// `userSelectedBatterySaver` remains part of the signature for migration
    /// compatibility, but production safety is represented by the persisted
    /// mode itself.
    nonisolated static func shouldUseStandardHROnlyInProtectedBackground(
        userSelectedBatterySaver: Bool,
        persistedStandardHROnly: Bool
    ) -> Bool {
        _ = userSelectedBatterySaver
        return persistedStandardHROnly
    }

    /// Session durability, workout analysis and link recovery are independent
    /// of whether the proprietary full protocol or Battery Saver HR-only radio
    /// mode is active. The radio-mode parameter is intentionally retained so a
    /// regression test covers the full-protocol case that previously stalled.
    nonisolated static func shouldRunLongWearSupervisor(
        longWearEnabled: Bool,
        standardHROnlyMode: Bool
    ) -> Bool {
        _ = standardHROnlyMode
        return longWearEnabled
    }

    nonisolated static func isBLEContinuityRelevant(
        longWearEnabled: Bool,
        activeExplicitWorkout: Bool
    ) -> Bool {
        longWearEnabled || activeExplicitWorkout
    }

    /// A live workout that retained both its in-memory samples and connected
    /// strap link across an app switch needs only a cheap subscription
    /// health check. Journal restore, supervisor reconstruction, range-loss
    /// reconciliation, scanning, and service rediscovery are recovery work for
    /// missing state—not prerequisites for the first returning frame.
    nonisolated static func shouldUseFastWorkoutForegroundResume(
        activeExplicitWorkout: Bool,
        hasLiveSession: Bool,
        linkConnected: Bool
    ) -> Bool {
        activeExplicitWorkout && hasLiveSession && linkConnected
    }

    nonisolated static func shouldPreserveSessionOnUnexpectedDisconnect(
        longWearEnabled: Bool,
        activeExplicitWorkout: Bool,
        userRequestedDisconnect: Bool
    ) -> Bool {
        _ = longWearEnabled
        _ = activeExplicitWorkout
        return !userRequestedDisconnect
    }

    nonisolated static func rangeLossBackfillCanClear(newRows: Int) -> Bool {
        _ = newRows
        return false
    }

    nonisolated static func rangeLossBackfillCanClear(newRows: Int,
                                                      hasRequestedWindow: Bool,
                                                      requestedWindowMetricProgress: Bool,
                                                      ledgerCoverageResolved: Bool = false) -> Bool {
        _ = newRows
        _ = requestedWindowMetricProgress
        // Row count is never completion evidence. Ordinary disconnect recovery
        // clears only when metric-usable timestamps retired the exact durable
        // gap ledger. Exact workout recovery remains owned by SessionStore,
        // which rebuilds that workout and proves its coverage floor.
        return ledgerCoverageResolved && !hasRequestedWindow
    }

    nonisolated static func requestedRecoveryRowProvidesMetricProgress(
        metricUsable: Bool,
        effectiveUnix: UInt32?,
        requestedStart: Double,
        requestedEnd: Double
    ) -> Bool {
        guard metricUsable,
              let effectiveUnix,
              requestedStart > 0,
              requestedEnd >= requestedStart else { return false }
        let timestamp = Double(effectiveUnix)
        return timestamp >= requestedStart && timestamp <= requestedEnd
    }

    private func rangeLossBackfillRetryDelay(now: Date = Date()) -> TimeInterval {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
              let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double else {
            return rangeLossBackfillRetryInterval
        }
        let pendingAge = max(0, now.timeIntervalSince1970 - requestedAt)
        guard pendingAge < rangeLossBackfillReadyForceInterval else {
            return min(rangeLossBackfillRetryInterval, 30)
        }
        return min(rangeLossBackfillRetryInterval,
                   max(15, rangeLossBackfillReadyForceInterval - pendingAge))
    }

    private func shouldForceStaleRangeLossBackfill(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
              let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double else {
            return false
        }
        return now.timeIntervalSince1970 - requestedAt >= rangeLossBackfillRetryInterval
    }

    private func shouldForceReadyRangeLossBackfill(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
              let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double else {
            return false
        }
        return now.timeIntervalSince1970 - requestedAt >= rangeLossBackfillReadyForceInterval
    }

    private func offlineHistoricalSyncMinimumInterval(for reason: String) -> TimeInterval {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else {
            return offlineHistoricalSyncMinimumInterval
        }
        let pendingReason = defaults.string(forKey: OfflineSyncDefaults.rangeLossBackfillReason) ?? ""
        guard reason == pendingReason || reason.contains("range_loss") || reason.contains("long_wear_range_loss") else {
            return offlineHistoricalSyncMinimumInterval
        }
        return rangeLossBackfillRetryInterval
    }

    private func shouldProtectLiveStreamForOfflineSync(now: Date = Date()) -> Bool {
        Self.shouldProtectConnectedLinkForOfflineSync(
            connected: peripheral?.state == .connected,
            connectedAt: connectedAt,
            hasContact: hasContact,
            acceptedSampleCount: session.count,
            lastAcceptedHRAt: lastAcceptedHRAt,
            now: now,
            minimumSamples: autoSaveMinSamples,
            acceptedFreshnessWindow: offlineSyncLiveAcceptedHRProtectionWindow
        )
    }

    /// Historical offload shares the strap command pipe with realtime capture.
    /// Protect every healthy connected stream, not only the optional long-wear
    /// mode. A short connect grace prevents an old pending recovery request from
    /// seizing the pipe before the first fresh pulse can arrive after launch.
    nonisolated static func shouldProtectConnectedLinkForOfflineSync(
        connected: Bool,
        connectedAt: Date?,
        hasContact: Bool,
        acceptedSampleCount: Int,
        lastAcceptedHRAt: Date?,
        now: Date,
        connectGrace: TimeInterval = 60,
        minimumSamples: Int = 10,
        acceptedFreshnessWindow: TimeInterval = 30
    ) -> Bool {
        guard connected else { return false }
        if let connectedAt {
            let age = now.timeIntervalSince(connectedAt)
            if age >= 0, age <= connectGrace { return true }
        }
        guard hasContact,
              acceptedSampleCount >= minimumSamples,
              let lastAcceptedHRAt else { return false }
        let age = now.timeIntervalSince(lastAcceptedHRAt)
        return age >= 0 && age <= acceptedFreshnessWindow
    }

    private func resumeForegroundScanIfNeeded(reason: String) {
        recomputeConnectionStatus(reason: "\(reason)_foreground_resume")
        guard peripheral == nil else { return }
        if hasSavedStrap, status == .connecting {
            _ = reconnectToSavedPeripheralIfPossible(reason: "\(reason)_resume_known_strap")
            return
        }
        guard status == .disconnected || status == .poweredOff else { return }
        startScan(reason: "\(reason)_resume")
    }

    private func applyStandardHROnly(enabled: Bool, persist: Bool, reconnect: Bool, reason: String) {
        let previous = standardHROnlyMode
        proprietaryNotifyFallbackTask?.cancel()
        proprietaryNotifyFallbackTask = nil
        activeProprietaryNotifyUUIDs.removeAll()
        strapStream5NotifyConfirmed = false
        standardHROnlyMode = enabled
        standardHROnlyEnabled = enabled
        if enabled {
            stopR10LivenessWatchdog(reason: "standard_hr_only_\(reason)")
        }
        if persist {
            UserDefaults.standard.set(enabled, forKey: RadioDefaults.standardHROnly)
        }
        if enabled {
            realtimeStartRetries = 0
            historicalAckDisabled = true
            forceFreshScanOnRestore = true
        } else if !historyOnlyProbeEnabled {
            historicalAckDisabled = false
        }
        AtriaDebugLog("ATRIADBG radio_mode mode=%@ persist=%d reconnect=%d reason=%@",
              enabled ? "protected_r10_minimal" : "full_protocol",
              persist ? 1 : 0,
              reconnect ? 1 : 0,
              reason)
        recordRadioMode(enabled ? "protected_r10_minimal" : "full_protocol", reason: reason)
        guard reconnect, previous != enabled, let peripheral else { return }
        txCharacteristic = nil
        heartRateCharacteristic = nil
        dbgTxReady = false
        realtimeArmed = false
        dbgLast = enabled ? "stable HR + R10 pending reconnect" : "full protocol pending reconnect"
        cancelPeripheralConnection(peripheral, reason: "radio_mode_\(reason)")
    }

    static func linkEvidence() -> String {
        let defaults = UserDefaults.standard
        let status = evidenceToken(defaults.string(forKey: LinkDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: LinkDefaults.lastReason) ?? "none")
        let error = evidenceToken(defaults.string(forKey: LinkDefaults.lastError) ?? "none")
        let save = evidenceToken(defaults.string(forKey: LinkDefaults.lastAutoSaveStatus) ?? "none")
        let coexistenceRisk = evidenceToken(defaults.string(forKey: LinkDefaults.officialAppCoexistenceRisk) ?? OfficialAppCoexistenceRisk.advisory.rawValue)
        let coexistenceReason = evidenceToken(defaults.string(forKey: LinkDefaults.officialAppCoexistenceReason) ?? "onboarding_advisory")
        return "ble_link_attempts=\(defaults.integer(forKey: LinkDefaults.attempts)); ble_link_disconnects=\(defaults.integer(forKey: LinkDefaults.disconnects)); ble_link_successes=\(defaults.integer(forKey: LinkDefaults.successes)); ble_link_failures=\(defaults.integer(forKey: LinkDefaults.failures)); ble_link_last_status=\(status); ble_link_last_reason=\(reason); ble_link_last_error=\(error); ble_link_last_autosave=\(save); ble_link_last_autosave_samples=\(defaults.integer(forKey: LinkDefaults.lastAutoSaveSamples)); ble_link_last_autosave_duration_s=\(defaults.integer(forKey: LinkDefaults.lastAutoSaveDuration)); official_app_coexistence_risk=\(coexistenceRisk); official_app_coexistence_reason=\(coexistenceReason)"
    }

    static func sampleGapEvidence() -> String {
        let defaults = UserDefaults.standard
        let status = evidenceToken(defaults.string(forKey: SampleDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: SampleDefaults.lastReason) ?? "none")
        return String(format: "hr_raw_2a37=%d; hr_accepted=%d; hr_zero=%d; hr_artifact_held=%d; hr_artifact_dropped=%d; hr_raw_gaps=%d; hr_accepted_gaps=%d; hr_max_raw_gap_s=%.1f; hr_max_accepted_gap_s=%.1f; hr_sample_last_status=%@; hr_sample_last_reason=%@",
                      defaults.integer(forKey: SampleDefaults.rawNotifications),
                      defaults.integer(forKey: SampleDefaults.acceptedSamples),
                      defaults.integer(forKey: SampleDefaults.zeroSamples),
                      defaults.integer(forKey: SampleDefaults.heldArtifacts),
                      defaults.integer(forKey: SampleDefaults.droppedArtifacts),
                      defaults.integer(forKey: SampleDefaults.rawGaps),
                      defaults.integer(forKey: SampleDefaults.acceptedGaps),
                      defaults.double(forKey: SampleDefaults.maxRawGap),
                      defaults.double(forKey: SampleDefaults.maxAcceptedGap),
                      status,
                      reason)
    }

    static func radioEvidence() -> String {
        let defaults = UserDefaults.standard
        let persistedStandardOnly = defaults.bool(forKey: RadioDefaults.standardHROnly)
        let mode = evidenceToken(defaults.string(forKey: RadioDefaults.mode) ?? (persistedStandardOnly ? "standard_hr_only" : "full_protocol"))
        let reason = evidenceToken(defaults.string(forKey: RadioDefaults.lastReason) ?? "none")
        let passiveStatus = evidenceToken(defaults.string(forKey: RadioDefaults.passiveR10Status) ?? "not_subscribed")
        let passiveLastAt = defaults.object(forKey: RadioDefaults.passiveR10LastValidAt) as? Double
        let passiveAge = passiveLastAt.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        return String(format: "radio_mode=%@; radio_standard_hr_only=%d; radio_custom_notify_skipped=%d; radio_custom_notify_enabled=%d; radio_tx_skipped=%d; radio_realtime_start_skipped=%d; radio_passive_r10_status=%@; radio_passive_r10_valid_frames=%d; radio_passive_r10_last_age_s=%.1f; radio_last_reason=%@",
                      mode,
                      persistedStandardOnly ? 1 : 0,
                      defaults.integer(forKey: RadioDefaults.customNotifySkipped),
                      defaults.integer(forKey: RadioDefaults.customNotifyEnabled),
                      defaults.integer(forKey: RadioDefaults.txSkipped),
                      defaults.integer(forKey: RadioDefaults.realtimeStartSkipped),
                      passiveStatus,
                      defaults.integer(forKey: RadioDefaults.passiveR10ValidFrames),
                      passiveAge,
                      reason)
    }

    static func protocolEvidence() -> String {
        let defaults = UserDefaults.standard
        let lastType = defaults.string(forKey: ProtocolDefaults.lastPacketType) ?? "none"
        let lastKind = evidenceToken(defaults.string(forKey: ProtocolDefaults.lastPacketKind) ?? "none")
        return "protocol_packets=\(defaults.integer(forKey: ProtocolDefaults.packets)); protocol_imu_frames=\(defaults.integer(forKey: ProtocolDefaults.imuFrames)); protocol_diagnostic_frames=\(defaults.integer(forKey: ProtocolDefaults.diagnosticFrames)); protocol_event_frames=\(defaults.integer(forKey: ProtocolDefaults.eventFrames)); protocol_unknown_frames=\(defaults.integer(forKey: ProtocolDefaults.unknownFrames)); protocol_last_type=\(lastType); protocol_last_kind=\(lastKind); protocol_last_len=\(defaults.integer(forKey: ProtocolDefaults.lastPacketLength))"
    }

    static func offlineSyncEvidence() -> String {
        let defaults = UserDefaults.standard
        let status = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.lastStatus) ?? "none")
        let reason = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.lastReason) ?? "none")
        let rangeReason = evidenceToken(defaults.string(forKey: OfflineSyncDefaults.rangeLossBackfillReason) ?? "none")
        let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double
        let startedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt) as? Double
        let requestedAge = requestedAt.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        let startedAge = startedAt.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        let missingWindows = AtriaHistoricalGapLedger.windows(defaults: defaults)
        let oldestCoverage = missingWindows.first.map {
            AtriaHistoricalGapLedger.coveragePercent(for: $0)
        } ?? 0
        return String(format: "offline_sync_enabled=%d; offline_sync_attempts=%d; offline_sync_last_status=%@; offline_sync_last_reason=%@; offline_range_loss_backfill_pending=%d; offline_range_loss_backfill_reason=%@; offline_range_loss_backfill_requested_age_s=%.1f; offline_range_loss_backfill_started_age_s=%.1f; offline_missing_windows=%d; offline_oldest_gap_coverage_percent=%d; offline_metric_layout_verified=%d",
                      defaults.bool(forKey: OfflineSyncDefaults.enabled) ? 1 : 0,
                      defaults.integer(forKey: OfflineSyncDefaults.attempts),
                      status,
                      reason,
                      defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) ? 1 : 0,
                      rangeReason,
                      requestedAge,
                      startedAge,
                      missingWindows.count,
                      oldestCoverage,
                      HistoricalArchive.hasValidatedMetricLayout ? 1 : 0)
    }

    static func watchdogRecoveryEvidence() -> String {
        let defaults = UserDefaults.standard
        let status = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastStatus) ?? "none")
        let source = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastSource) ?? "none")
        let action = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastAction) ?? "none")
        let checkpoint = evidenceToken(defaults.string(forKey: WatchdogRecoveryDefaults.lastCheckpoint) ?? "none")
        let at = defaults.object(forKey: WatchdogRecoveryDefaults.lastAt) as? Double
        let age = at.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        let rrStatus = evidenceToken(defaults.string(forKey: RRPresenceDefaults.status) ?? "none")
        let rrAction = evidenceToken(defaults.string(forKey: RRPresenceDefaults.action) ?? "none")
        let rrLabel = evidenceToken(defaults.string(forKey: RRPresenceDefaults.label) ?? "none")
        let rrAt = defaults.object(forKey: RRPresenceDefaults.at) as? Double
        let rrAge = rrAt.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        return String(format: "watchdog_no_data_recoveries=%d; watchdog_hr_continuity_recoveries=%d; watchdog_accepted_hr_recoveries=%d; watchdog_rr_presence_recoveries=%d; watchdog_last_status=%@; watchdog_last_source=%@; watchdog_last_action=%@; watchdog_last_raw_gap_s=%.1f; watchdog_last_accepted_gap_s=%.1f; watchdog_last_samples=%d; watchdog_last_checkpoint=%@; watchdog_last_age_s=%.1f; rr_presence_status=%@; rr_presence_action=%@; rr_presence_rr_gap_s=%.1f; rr_presence_accepted_gap_s=%.1f; rr_presence_timeout_s=%.1f; rr_presence_samples=%d; rr_presence_rr_values=%d; rr_presence_consecutive=%d; rr_presence_age_s=%.1f; rr_presence_label=%@",
                      defaults.integer(forKey: WatchdogRecoveryDefaults.noDataCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.hrContinuityCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.acceptedHRCount),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.rrPresenceCount),
                      status,
                      source,
                      action,
                      defaults.double(forKey: WatchdogRecoveryDefaults.lastRawGap),
                      defaults.double(forKey: WatchdogRecoveryDefaults.lastAcceptedGap),
                      defaults.integer(forKey: WatchdogRecoveryDefaults.lastSamples),
                      checkpoint,
                      age,
                      rrStatus,
                      rrAction,
                      defaults.double(forKey: RRPresenceDefaults.rrGap),
                      defaults.double(forKey: RRPresenceDefaults.acceptedGap),
                      defaults.double(forKey: RRPresenceDefaults.timeout),
                      defaults.integer(forKey: RRPresenceDefaults.samples),
                      defaults.integer(forKey: RRPresenceDefaults.rrValues),
                      defaults.integer(forKey: RRPresenceDefaults.consecutive),
                      rrAge,
                      rrLabel)
    }

    static func cachedBattery(maxAge: TimeInterval = 86_400,
                              chargeMaxAge: TimeInterval = AtriaBLEManager.activeBatteryChargeEvidenceMaxAge,
                              defaults: UserDefaults = .standard,
                              now: Date = Date(),
                              permitPendingReconnectBaseline: Bool = false,
                              permitActiveNotificationLease: Bool = false) -> (level: Int, source: String, age: TimeInterval, chargeStatus: BatteryChargeStatus, chargeAge: TimeInterval, usable: Bool) {
        let level = defaults.object(forKey: BatteryDefaults.level) as? Int ?? -1
        let at = defaults.object(forKey: BatteryDefaults.at) as? Double
        let requiresFreshConfirmation = defaults.bool(forKey: BatteryDefaults.requiresFreshConfirmation)
        // A CCCD lease is transport evidence, not a level-bearing sample. Keep
        // the original percentage timestamp authoritative so diagnostics,
        // notifications and widget freshness cannot silently turn an aged
        // baseline into a just-now reading merely because the subscription is
        // still active.
        let age = at.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let source = evidenceToken(defaults.string(forKey: BatteryDefaults.source) ?? (level >= 0 ? "cached_2A19" : "none"))
        let rawCharge = defaults.string(forKey: BatteryDefaults.chargeStatus) ?? BatteryChargeStatus.levelOnly.rawValue
        let storedChargeStatus = BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly
        let chargeAt = defaults.object(forKey: BatteryDefaults.chargeAt) as? Double
        let chargeAge = chargeAt.map { max(0, now.timeIntervalSince1970 - $0) } ?? -1
        let chargeFresh = storedChargeStatus == .levelOnly || (chargeAge >= 0 && chargeAge <= chargeMaxAge)
        let effectiveChargeStatus = chargeFresh ? storedChargeStatus : .levelOnly
        let sourceIsEligible = batteryCacheSourceIsDisplayEligible(source)
        let activeNotificationLease = permitActiveNotificationLease
            && persistedBatteryNotificationLeaseSupportsDisplay(
                level: level,
                source: source,
                requiresFreshConfirmation: requiresFreshConfirmation,
                notificationLeaseAt: (defaults.object(forKey: BatteryDefaults.notificationLeaseAt) as? Double)
                    .map(Date.init(timeIntervalSince1970:)),
                notificationConfirmedAt: (defaults.object(forKey: BatteryDefaults.notificationConfirmedAt) as? Double)
                    .map(Date.init(timeIntervalSince1970:)),
                now: now
            )
        // Persisted 0/10/100 values cannot carry their live trajectory proof
        // across process boundaries. These are exactly the values the physical
        // strap has replayed incorrectly, so cached consumers fail closed even
        // when an older build stamped them as recent.
        let rawLevelIsUsable = (11...99).contains(level)
            && age >= 0
            && age <= maxAge
            && sourceIsEligible
            && (!requiresFreshConfirmation || permitPendingReconnectBaseline)
        let usable = rawLevelIsUsable || activeNotificationLease
        return (level, source, age, effectiveChargeStatus, chargeAge, usable)
    }

    /// Cross-process consumers (widgets and asynchronous notification
    /// scheduling) cannot inspect CoreBluetooth objects, but they can verify a
    /// lease that the live app renews only while the same 2A19 subscription is
    /// proven. This never refreshes the level packet's timestamp and never
    /// admits the observed restoration sentinels 0/10/100.
    nonisolated static func persistedBatteryNotificationLeaseSupportsDisplay(
        level: Int,
        source: String,
        requiresFreshConfirmation: Bool,
        notificationLeaseAt: Date?,
        notificationConfirmedAt: Date?,
        now: Date,
        leaseMaximumAge: TimeInterval = batteryDisplayFreshnessLimit,
        confirmationMaximumAge: TimeInterval = batteryRestoredNotificationConfirmationMaximumAge
    ) -> Bool {
        guard (11...99).contains(level),
              batteryReconnectBaselineSourceIsLeaseEligible(source),
              !requiresFreshConfirmation,
              let notificationLeaseAt,
              let notificationConfirmedAt,
              notificationLeaseAt <= now,
              notificationConfirmedAt <= now else { return false }
        return now.timeIntervalSince(notificationLeaseAt) <= leaseMaximumAge
            && now.timeIntervalSince(notificationConfirmedAt) <= confirmationMaximumAge
    }

    nonisolated static func batteryCacheSourceIsDisplayEligible(_ source: String) -> Bool {
        switch source {
        case "live_2A19", "live_battery_event", "live_proprietary_1a":
            return true
        default:
            return false
        }
    }

    /// Invalidates state written by the old two-read confirmation rule. A rapid
    /// >=20-point transition makes *both* stored levels disputed: restoring the
    /// earlier value would merely replace one unverified reading with another.
    /// Leave battery unavailable until a fresh, stable live series is confirmed.
    @discardableResult
    nonisolated static func invalidateImplausibleCachedBatteryTransitionIfNeeded(defaults: UserDefaults = .standard) -> Bool {
        guard let level = defaults.object(forKey: BatteryDefaults.level) as? Int,
              let previous = defaults.object(forKey: BatteryDefaults.previousLevel) as? Int,
              let previousAt = defaults.object(forKey: BatteryDefaults.previousAt) as? Double,
              let dropAt = defaults.object(forKey: BatteryDefaults.dropAt) as? Double,
              abs(previous - level) >= implausibleBatteryDropThreshold,
              dropAt >= previousAt,
              dropAt - previousAt < transitionBatteryMinimumConfirmationSpan(incomingLevel: level) else {
            return false
        }
        defaults.removeObject(forKey: BatteryDefaults.level)
        defaults.removeObject(forKey: BatteryDefaults.at)
        defaults.removeObject(forKey: BatteryDefaults.previousLevel)
        defaults.removeObject(forKey: BatteryDefaults.previousAt)
        defaults.removeObject(forKey: BatteryDefaults.dropDelta)
        defaults.removeObject(forKey: BatteryDefaults.dropAt)
        defaults.removeObject(forKey: BatteryDefaults.chargeStatus)
        defaults.removeObject(forKey: BatteryDefaults.chargeAt)
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.set("disputed_rapid_transition", forKey: BatteryDefaults.source)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        defaults.set(StrapStreamState.unknown.rawValue, forKey: StrapStreamDefaults.state)
        defaults.set(-1, forKey: StrapStreamDefaults.batteryLevel)
        defaults.set("disputed_battery_transition", forKey: StrapStreamDefaults.reason)
        defaults.set(false, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        defaults.removeObject(forKey: StrapStreamDefaults.accessibilityLabel)
        AtriaDebugLog("ATRIADBG battery status=invalidated_cached_transition newer=%d earlier=%d span_s=%.1f action=require_fresh_stable_confirmation",
                      level,
                      previous,
                      dropAt - previousAt)
        return true
    }

    /// Builds predating trajectory validation may have persisted a replayed
    /// 0/10/100 as live truth. Exact sentinel cache entries have no proof of how
    /// they were reached, so remove them at launch while retaining the separate
    /// last-credible mid-range baseline when one exists.
    @discardableResult
    nonisolated static func invalidateUnverifiedCachedBatterySentinelIfNeeded(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let level = defaults.object(forKey: BatteryDefaults.level) as? Int,
              isBatterySentinel(level) else { return false }
        defaults.removeObject(forKey: BatteryDefaults.level)
        defaults.removeObject(forKey: BatteryDefaults.at)
        defaults.removeObject(forKey: BatteryDefaults.chargeStatus)
        defaults.removeObject(forKey: BatteryDefaults.chargeAt)
        defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
        defaults.removeObject(forKey: BatteryDefaults.dropDelta)
        defaults.removeObject(forKey: BatteryDefaults.dropAt)
        defaults.set("disputed_boundary_sentinel", forKey: BatteryDefaults.source)
        defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
        defaults.set(StrapStreamState.unknown.rawValue, forKey: StrapStreamDefaults.state)
        defaults.set(-1, forKey: StrapStreamDefaults.batteryLevel)
        defaults.set("disputed_battery_boundary", forKey: StrapStreamDefaults.reason)
        defaults.set(false, forKey: StrapStreamDefaults.lowBatteryReconnectSuppressed)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressedAt)
        defaults.removeObject(forKey: StrapStreamDefaults.lowBatteryReconnectSuppressionReason)
        defaults.removeObject(forKey: StrapStreamDefaults.accessibilityLabel)
        AtriaDebugLog("ATRIADBG battery status=invalidated_cached_sentinel level=%d action=preserve_last_credible",
                      level)
        return true
    }

    static func cachedBatteryDrop(maxAge: TimeInterval = 6 * 60 * 60) -> (recent: Bool, delta: Int, age: TimeInterval) {
        let defaults = UserDefaults.standard
        let delta = defaults.object(forKey: BatteryDefaults.dropDelta) as? Int ?? 0
        let at = defaults.object(forKey: BatteryDefaults.dropAt) as? Double
        let age = at.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        return (delta > 0 && age >= 0 && age <= maxAge, delta, age)
    }

    static func batteryEvidence() -> String {
        let battery = cachedBattery()
        let drop = cachedBatteryDrop()
        let ageText = battery.age >= 0 ? String(format: "%.0f", battery.age) : "learning"
        let chargeAgeText = battery.chargeAge >= 0 ? String(format: "%.0f", battery.chargeAge) : "learning"
        let dropAgeText = drop.age >= 0 ? String(format: "%.0f", drop.age) : "learning"
        return "battery_level=\(battery.level); battery_source=\(battery.source); battery_age_s=\(ageText); battery_charge_status=\(battery.chargeStatus.rawValue); battery_charge_age_s=\(chargeAgeText); battery_usable=\(battery.usable ? 1 : 0); battery_drop_recent=\(drop.recent ? 1 : 0); battery_drop_delta=\(drop.delta); battery_drop_age_s=\(dropAgeText)"
    }

    private static func currentSampleStatusAndReason() -> (status: String, reason: String) {
        let defaults = UserDefaults.standard
        return (evidenceToken(defaults.string(forKey: SampleDefaults.lastStatus) ?? "none"),
                evidenceToken(defaults.string(forKey: SampleDefaults.lastReason) ?? "none"))
    }

    private static func sampleFields(for saved: SavedSession) -> String {
        let sample = currentSampleStatusAndReason()
        return String(format: "hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f hr_sample_last_status=%@ hr_sample_last_reason=%@",
                      saved.hrRaw2A37Value,
                      saved.hrAcceptedValue,
                      saved.hrZeroValue,
                      saved.hrArtifactHeldValue,
                      saved.hrArtifactDroppedValue,
                      saved.hrRawGapsValue,
                      saved.hrAcceptedGapsValue,
                      saved.hrMaxRawGapValue,
                      saved.hrMaxAcceptedGapValue,
                      sample.status,
                      sample.reason)
    }

    private func workoutCaptureEvidence(for saved: SavedSession,
                                        readiness: WorkoutReadiness) -> WorkoutCaptureEvidence {
        let sample = Self.currentSampleStatusAndReason()
        let sampleFields = Self.sampleFields(for: saved)
        guard !readiness.ready else {
            return WorkoutCaptureEvidence(diagnosis: "candidate_valid",
                                          action: "save_or_validate_workout",
                                          sampleFields: sampleFields)
        }
        if saved.hrZeroValue > 0 || sample.status == "zero_contact" || sample.reason == "hr_zero" || sample.reason == "zero_contact" {
            return WorkoutCaptureEvidence(diagnosis: "contact_loss",
                                          action: "keep_learning_check_fit_contact",
                                          sampleFields: sampleFields)
        }
        let droppedFraction = readiness.duration > 0 ? readiness.droppedGapSeconds / readiness.duration : 0
        if readiness.streamCoveragePercent < 75
            || readiness.maxSampleGap > SavedSession.workoutContinuityGapLimit
            || droppedFraction >= 0.25 {
            return WorkoutCaptureEvidence(diagnosis: "stream_gaps",
                                          action: "keep_learning_reconnect_or_keep_phone_near",
                                          sampleFields: sampleFields)
        }
        if (saved.hrArtifactHeldValue + saved.hrArtifactDroppedValue) > 0 && readiness.thresholdGapBPM > 0 {
            return WorkoutCaptureEvidence(diagnosis: "artifact_filtering_or_motion",
                                          action: "inspect_raw_hr_artifacts",
                                          sampleFields: sampleFields)
        }
        if readiness.thresholdGapBPM > 0 {
            return WorkoutCaptureEvidence(diagnosis: "received_hr_below_threshold",
                                          action: "compare_reference_hr_before_profile_change",
                                          sampleFields: sampleFields)
        }
        if readiness.hrDistributionBelowWorkoutBand {
            return WorkoutCaptureEvidence(diagnosis: "wrist_hr_distribution_below_workout_band",
                                          action: "validate_wrist_hr_underreporting_or_profile_before_more_workouts",
                                          sampleFields: sampleFields)
        }
        if readiness.observedDuration < 10 * 60 {
            return WorkoutCaptureEvidence(diagnosis: "too_short",
                                          action: "keep_collecting",
                                          sampleFields: sampleFields)
        }
        return WorkoutCaptureEvidence(diagnosis: Self.evidenceToken(readiness.primaryBlocker),
                                      action: "keep_learning",
                                      sampleFields: sampleFields)
    }

    static func activeSessionJournalEvidence(includeAge: Bool = true) -> String {
        ActiveSessionJournal.evidence(includeAge: includeAge)
    }

    private static func evidenceToken(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-."))
        return value.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }

    private func recordLinkAttempt(reason: String, peripheral: CBPeripheral?) {
        let defaults = UserDefaults.standard
        let attempts = defaults.integer(forKey: LinkDefaults.attempts) + 1
        defaults.set(attempts, forKey: LinkDefaults.attempts)
        defaults.set("connecting", forKey: LinkDefaults.lastStatus)
        defaults.set(reason, forKey: LinkDefaults.lastReason)
        refreshOfficialAppCoexistenceRisk(reason: "link_attempt")
        AtriaDebugLog("ATRIADBG ble_link status=connecting reason=%@ attempts=%d disconnects=%d failures=%d name=%@",
              reason,
              attempts,
              defaults.integer(forKey: LinkDefaults.disconnects),
              defaults.integer(forKey: LinkDefaults.failures),
              peripheral?.name ?? deviceName)
    }

    private func markPendingKnownReconnect(reason: String) {
        pendingKnownReconnectStartedAt = Date()
        pendingKnownReconnectReason = reason
    }

    private func clearPendingKnownReconnect(reason: String) {
        guard pendingKnownReconnectStartedAt != nil || !pendingKnownReconnectReason.isEmpty else { return }
        pendingKnownReconnectStartedAt = nil
        pendingKnownReconnectReason = ""
        AtriaDebugLog("ATRIADBG ble_link pending_known_reconnect status=cleared reason=%@", reason)
    }

    private func recordLinkConnected(peripheral: CBPeripheral) {
        clearPendingKnownReconnect(reason: "did_connect")
        let defaults = UserDefaults.standard
        // Remember this strap so we can re-arm a standing pending connection to it
        // on every launch / drop without scanning. "Connect once, stay connected."
        defaults.set(peripheral.identifier.uuidString, forKey: LinkDefaults.savedPeripheralUUID)
        let successes = defaults.integer(forKey: LinkDefaults.successes) + 1
        defaults.set(successes, forKey: LinkDefaults.successes)
        defaults.set("connected", forKey: LinkDefaults.lastStatus)
        defaults.set("did_connect", forKey: LinkDefaults.lastReason)
        defaults.set("none", forKey: LinkDefaults.lastError)
        persistOfficialAppCoexistenceRisk(.cleared, reason: "atria_connected")
        AtriaDebugLog("ATRIADBG ble_link status=connected successes=%d attempts=%d disconnects=%d failures=%d mtu=%d name=%@",
              successes,
              defaults.integer(forKey: LinkDefaults.attempts),
              defaults.integer(forKey: LinkDefaults.disconnects),
              defaults.integer(forKey: LinkDefaults.failures),
              dbgMTU,
              peripheral.name ?? deviceName)
        scheduleRangeLossBackfillIfNeeded(reason: "did_connect")
    }

    private func recordLinkObservedConnected(reason: String, peripheral: CBPeripheral) {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: LinkDefaults.lastStatus) != "connected" else { return }
        let successes = defaults.integer(forKey: LinkDefaults.successes) + 1
        defaults.set(successes, forKey: LinkDefaults.successes)
        defaults.set("connected", forKey: LinkDefaults.lastStatus)
        defaults.set(reason, forKey: LinkDefaults.lastReason)
        defaults.set("none", forKey: LinkDefaults.lastError)
        persistOfficialAppCoexistenceRisk(.cleared, reason: "atria_observed_connected")
        AtriaDebugLog("ATRIADBG ble_link status=connected reason=%@ successes=%d attempts=%d disconnects=%d failures=%d name=%@",
              reason,
              successes,
              defaults.integer(forKey: LinkDefaults.attempts),
              defaults.integer(forKey: LinkDefaults.disconnects),
              defaults.integer(forKey: LinkDefaults.failures),
              peripheral.name ?? deviceName)
    }

    private func resetLinkDiagnosticsForDebugLaunch(arguments: [String]) {
        guard arguments.contains("--atria-reset-link-diagnostics") else { return }
        let defaults = UserDefaults.standard
        [
            LinkDefaults.attempts,
            LinkDefaults.disconnects,
            LinkDefaults.successes,
            LinkDefaults.failures,
            LinkDefaults.lastStatus,
            LinkDefaults.lastReason,
            LinkDefaults.lastError,
            LinkDefaults.lastAutoSaveStatus,
            LinkDefaults.lastAutoSaveSamples,
            LinkDefaults.lastAutoSaveDuration,
            LinkDefaults.officialAppCoexistenceRisk,
            LinkDefaults.officialAppCoexistenceReason
        ].forEach { defaults.removeObject(forKey: $0) }
        AtriaDebugLog("ATRIADBG ble_link reset=1 reason=launch_arg")
    }

    private func resetSampleDiagnosticsForDebugLaunch(arguments: [String]) {
        guard arguments.contains("--atria-reset-sample-diagnostics") else { return }
        let defaults = UserDefaults.standard
        sampleDiagnosticsFlushTask?.cancel()
        sampleDiagnosticsFlushTask = nil
        sampleDiagnostics = .empty
        [
            SampleDefaults.rawNotifications,
            SampleDefaults.acceptedSamples,
            SampleDefaults.zeroSamples,
            SampleDefaults.heldArtifacts,
            SampleDefaults.droppedArtifacts,
            SampleDefaults.rawGaps,
            SampleDefaults.acceptedGaps,
            SampleDefaults.maxRawGap,
            SampleDefaults.maxAcceptedGap,
            SampleDefaults.lastStatus,
            SampleDefaults.lastReason,
            HRContinuityDefaults.status,
            HRContinuityDefaults.action,
            HRContinuityDefaults.rawGap,
            HRContinuityDefaults.acceptedGap,
            HRContinuityDefaults.timeout,
            HRContinuityDefaults.samples,
            HRContinuityDefaults.label,
            HRContinuityDefaults.notifying,
            HRContinuityDefaults.at,
            WatchdogRecoveryDefaults.noDataCount,
            WatchdogRecoveryDefaults.hrContinuityCount,
            WatchdogRecoveryDefaults.acceptedHRCount,
            WatchdogRecoveryDefaults.rrPresenceCount,
            WatchdogRecoveryDefaults.lastStatus,
            WatchdogRecoveryDefaults.lastSource,
            WatchdogRecoveryDefaults.lastAction,
            WatchdogRecoveryDefaults.lastRawGap,
            WatchdogRecoveryDefaults.lastAcceptedGap,
            WatchdogRecoveryDefaults.lastSamples,
            WatchdogRecoveryDefaults.lastCheckpoint,
            WatchdogRecoveryDefaults.lastAt,
            RRPresenceDefaults.status,
            RRPresenceDefaults.action,
            RRPresenceDefaults.rrGap,
            RRPresenceDefaults.acceptedGap,
            RRPresenceDefaults.timeout,
            RRPresenceDefaults.samples,
            RRPresenceDefaults.rrValues,
            RRPresenceDefaults.consecutive,
            RRPresenceDefaults.label,
            RRPresenceDefaults.at
        ].forEach { defaults.removeObject(forKey: $0) }
        resetSessionSampleDiagnostics()
        AtriaDebugLog("ATRIADBG hr_sample reset=1 watchdog_recovery_reset=1 reason=launch_arg")
    }

    private func resetRadioDiagnosticsForLaunch() {
        let defaults = UserDefaults.standard
        [
            RadioDefaults.customNotifySkipped,
            RadioDefaults.customNotifyEnabled,
            RadioDefaults.txSkipped,
            RadioDefaults.realtimeStartSkipped,
            RadioDefaults.lastReason
        ].forEach { defaults.removeObject(forKey: $0) }
        recordRadioMode(standardHROnlyMode ? "protected_r10_minimal" : "full_protocol", reason: "launch")
    }

    private func resetProtocolDiagnosticsForDebugLaunch(arguments: [String]) {
        protocolPacketCount = 0
        protocolIMUFrameCount = 0
        resetIMUFeatureStats(resetResearchAggregates: false)
        protocolDiagnosticFrameCount = 0
        protocolEventFrameCount = 0
        protocolUnknownFrameCount = 0
        protocolLastPacketType = "none"
        protocolLastPacketKind = "none"
        protocolLastPacketLength = 0
        guard arguments.contains("--atria-reset-protocol-diagnostics") else { return }
        let defaults = UserDefaults.standard
        [
            ProtocolDefaults.packets,
            ProtocolDefaults.imuFrames,
            ProtocolDefaults.diagnosticFrames,
            ProtocolDefaults.eventFrames,
            ProtocolDefaults.unknownFrames,
            ProtocolDefaults.lastPacketType,
            ProtocolDefaults.lastPacketKind,
            ProtocolDefaults.lastPacketLength
        ].forEach { defaults.removeObject(forKey: $0) }
        AtriaDebugLog("ATRIADBG protocol_diagnostics reset=1 reason=launch_arg")
    }

    private func logActiveMotionIMUCheckPlanIfRequested(arguments: [String]) {
        guard arguments.contains("--atria-active-motion-imu-check") else { return }
        let delay = doubleValue(
            after: "--atria-active-motion-result-after",
            in: arguments,
            default: doubleValue(after: "--atria-log-gate-status-after", in: arguments, default: 150, range: 30...300),
            range: 30...300
        )
        AtriaDebugLog("ATRIADBG active_motion_imu_check status=armed full_protocol=1 reset_protocol_counters=%d metric_promotions=0 script=30s_still_then_30s_wrist_rotations_taps_then_30s_still_then_30s_walking_arm_swing success_signal=protocol_imu_frames_gt_0_or_imu_candidate_or_sleep_motion_hint_count_gt_0 failure_signal=protocol_imu_frames_0_and_sleep_motion_hint_count_0 action=keep_sleep_motion_learning_until_validated",
              arguments.contains("--atria-reset-protocol-diagnostics") ? 1 : 0)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            logActiveMotionIMUCheckResult(delay: delay)
        }
    }

    private func logActiveMotionIMUCheckResult(delay: TimeInterval) {
        let packets = protocolPacketCount
        let imuFrames = protocolIMUFrameCount
        let diagnosticFrames = protocolDiagnosticFrameCount
        let eventFrames = protocolEventFrameCount
        let unknownFrames = protocolUnknownFrameCount
        let signalSeen = imuFrames > 0 || diagnosticFrames > 0 || sleepMotionHintCount > 0
        AtriaDebugLog("ATRIADBG active_motion_imu_check status=%@ delay_s=%.0f protocol_packets=%d protocol_imu_frames=%d protocol_diagnostic_frames=%d protocol_event_frames=%d protocol_unknown_frames=%d protocol_last_type=%@ protocol_last_kind=%@ sleep_motion_hint_count=%d sleep_motion_hint_kinds=%@ strap_motion_validated=0 metric_promotions=0 action=%@",
              signalSeen ? "signal_seen" : "no_strap_motion_signal",
              delay,
              packets,
              imuFrames,
              diagnosticFrames,
              eventFrames,
              unknownFrames,
              protocolLastPacketType,
              Self.evidenceToken(protocolLastPacketKind),
              sleepMotionHintCount,
              sleepMotionHintKinds,
              signalSeen ? "inspect_protocol_before_any_metric_use" : "keep_sleep_motion_learning_until_validated")
    }

    private func recordRadioMode(_ mode: String, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(mode, forKey: RadioDefaults.mode)
        defaults.set(reason, forKey: RadioDefaults.lastReason)
    }

    private nonisolated static func discoveryShouldUseProtectedStandardHR(standardSnapshot: Bool,
                                                                          historyOnlyProbeMode: Bool) -> Bool {
        standardSnapshot && !historyOnlyProbeMode
    }

    private func incrementRadioCounter(_ key: String, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: key) + 1, forKey: key)
        defaults.set(reason, forKey: RadioDefaults.lastReason)
        let skipped = defaults.integer(forKey: RadioDefaults.customNotifySkipped)
        let enabled = defaults.integer(forKey: RadioDefaults.customNotifyEnabled)
        let txSkipped = defaults.integer(forKey: RadioDefaults.txSkipped)
        let realtimeSkipped = defaults.integer(forKey: RadioDefaults.realtimeStartSkipped)
        if key == RadioDefaults.customNotifySkipped
            || key == RadioDefaults.txSkipped
            || key == RadioDefaults.realtimeStartSkipped
            || key == RadioDefaults.customNotifyEnabled {
            AtriaDebugLog("ATRIADBG radio_low_traffic status=%@ mode=%@ custom_notify_skipped=%d custom_notify_enabled=%d tx_skipped=%d realtime_start_skipped=%d reason=%@",
                  enabled == 0 && (skipped > 0 || txSkipped > 0 || realtimeSkipped > 0) ? "ready" : "learning",
                  standardHROnlyMode ? "standard_hr_only" : "full_protocol",
                  skipped,
                  enabled,
                  txSkipped,
                  realtimeSkipped,
                  reason)
        }
    }

    private func restoreActiveSessionJournalIfNeeded(reason: String) {
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        guard Self.isBLEContinuityRelevant(
            longWearEnabled: longWearModeEnabled,
            activeExplicitWorkout: activeExplicitWorkout
        ) else { return }
        guard session.isEmpty else {
            AtriaDebugLog("ATRIADBG active_session_journal status=restore_skipped reason=live_session_active samples=%d", session.count)
            return
        }
        guard activeSessionRestoreInFlightGeneration == nil else {
            AtriaDebugLog("ATRIADBG active_session_journal status=restore_coalesced reason=%@", reason)
            return
        }

        activeSessionRestoreGeneration &+= 1
        let generation = activeSessionRestoreGeneration
        activeSessionRestoreInFlightGeneration = generation
        let maxAge = activeJournalMaxAge
        let maxSamples = activeJournalMaxSamples
        let segmentGapLimit = activeJournalSegmentGapLimit
        let biologicalSex = AthleteProfile.load().biologicalSex
        Task.detached(priority: .userInitiated) { [weak self] in
            let record = ActiveSessionJournal.load()
            let prepared = Self.prepareActiveSessionJournalRestore(
                record,
                now: Date(),
                maxAge: maxAge,
                maxSamples: maxSamples,
                segmentGapLimit: segmentGapLimit,
                biologicalSex: biologicalSex
            )
            await self?.applyPreparedActiveSessionJournalRestore(
                prepared,
                generation: generation,
                reason: reason
            )
        }
    }

    nonisolated static func shouldAcceptActiveSessionJournalRestore(
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        longWearRelevant: Bool,
        hasLiveSession: Bool
    ) -> Bool {
        requestGeneration == currentGeneration
            && longWearRelevant
            && !hasLiveSession
    }

    nonisolated static func prepareActiveSessionJournalRestore(
        _ record: ActiveSessionJournalRecord?,
        now: Date,
        maxAge: TimeInterval,
        maxSamples: Int,
        segmentGapLimit: TimeInterval,
        biologicalSex: AthleteProfile.BiologicalSex
    ) -> ActiveSessionRestorePreparation {
        guard let record else {
            return ActiveSessionRestorePreparation(payload: .terminal(.absent))
        }
        let identity = ActiveSessionRestorePreparation.JournalIdentity(
            id: record.id,
            updatedAt: record.updatedAt,
            schema: record.schema,
            sampleCount: record.samples.count,
            rrSampleCount: record.rrSamples?.count ?? 0
        )
        guard record.schema == ActiveSessionJournal.schema else {
            return ActiveSessionRestorePreparation(
                payload: .terminal(.schemaMismatch(identity: identity))
            )
        }

        let age = now.timeIntervalSince(record.updatedAt)
        guard age <= maxAge else {
            return ActiveSessionRestorePreparation(
                payload: .terminal(.stale(age: age, identity: identity))
            )
        }

        let retainedSamples = Array(
            record.samples
                .filter { now.timeIntervalSince($0.t) <= maxAge }
                .suffix(max(0, maxSamples))
        )
        let retainedRRSamples = (record.rrSamples ?? [])
            .filter { now.timeIntervalSince($0.t) <= maxAge }
        guard let first = retainedSamples.first,
              let last = retainedSamples.last,
              retainedSamples.count > 1 else {
            return ActiveSessionRestorePreparation(
                payload: .terminal(.insufficientSamples(identity: identity))
            )
        }

        let researchAggregates = validatedResearchAggregates(from: record)
        let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "All-day wear"
            : record.label
        let scopedRRSamples = retainedRRSamples.filter {
            $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1)
        }

        if age >= segmentGapLimit {
            let saved = SavedSession(
                id: record.id,
                start: first.t,
                end: last.t,
                label: label,
                points: retainedSamples.map {
                    SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm)
                },
                hrv: nil,
                rrPoints: scopedRRSamples.isEmpty ? nil : scopedRRSamples.map {
                    SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t), ms: $0.ms)
                },
                hrvReferenceValidated: false,
                motionHintCount: nil,
                motionHintKinds: nil,
                motionEvidenceSource: "unavailable",
                motionEvidenceValidated: false,
                motionShortCount: nil,
                motionShortMean: nil,
                motionShortMin: nil,
                motionShortMax: nil,
                motionShortOverOneCount: nil,
                strapStepResearchCount: researchAggregates.map(\.strapSteps).flatMap { $0 > 0 ? $0 : nil },
                strapStepResearchAgreement: nil,
                strapStepResearchState: researchAggregates?.strapStepState,
                sensorResearchProbeFrames: researchAggregates?.sensorProbeFrames,
                spo2ResearchCandidateFrames: researchAggregates?.spo2CandidateFrames,
                skinTempResearchCandidateFrames: researchAggregates?.skinTempCandidateFrames,
                skinTempResearchCandidateValueSum: researchAggregates?.skinTempCandidateValueSum,
                skinTempResearchCandidateValueCount: researchAggregates?.skinTempCandidateValueCount,
                biologicalSex: biologicalSex,
                hrRaw2A37: record.rawHRNotifications,
                hrAccepted: record.acceptedHRSamples,
                hrZero: record.zeroHRSamples,
                hrArtifactHeld: record.heldArtifacts,
                hrArtifactDropped: record.droppedArtifacts,
                hrRawGaps: record.rawHRGaps,
                hrAcceptedGaps: record.acceptedHRGaps,
                hrMaxRawGap: record.maxRawHRGap,
                hrMaxAcceptedGap: record.maxAcceptedHRGap,
                strengthSets: record.strengthSets,
                excludedIntervals: record.excludedIntervals,
                eventTimeZoneIdentifier: record.eventTimeZoneIdentifier
            )
            return ActiveSessionRestorePreparation(payload: .staleSegment(
                ActiveSessionRestorePreparation.StaleSegmentPayload(
                    savedSession: saved,
                    now: now,
                    age: age,
                    researchAggregatesWereMalformed: researchAggregates == nil
                )
            ))
        }

        let session = retainedSamples.map { HRSample(t: $0.t, bpm: $0.bpm) }
        let rrArchive = scopedRRSamples.map {
            RRInterval(t: $0.t, ms: Double($0.ms), expectedHR: nil)
        }
        let recentValid = Array(session.suffix(5).map(\.bpm))
        let live = ActiveSessionRestorePreparation.LivePayload(
            record: record,
            now: now,
            age: age,
            session: session,
            sessionPoints: retainedSamples.map {
                SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm)
            },
            stats: preparedHeartRateStats(for: retainedSamples),
            lastHeartRates: Array(session.suffix(60).map(\.bpm)),
            recentValid: recentValid,
            displayHeartRate: preparedMedian(recentValid) ?? last.bpm,
            rrArchive: rrArchive,
            rrPoints: scopedRRSamples.map {
                SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t), ms: $0.ms)
            },
            recentRRBeatTimes: rrArchive.compactMap {
                now.timeIntervalSince($0.t) <= recentRRBeatWindowSeconds ? $0.t : nil
            },
            researchAggregates: researchAggregates
        )
        return ActiveSessionRestorePreparation(payload: .live(live))
    }

    private nonisolated static func preparedHeartRateStats(
        for samples: [ActiveSessionJournalRecord.Sample]
    ) -> ActiveSessionRestorePreparation.HeartRateStats {
        guard !samples.isEmpty else {
            return .init(minimum: nil, maximum: nil, total: 0, count: 0, mean: 0, m2: 0)
        }
        var minimum = Int.max
        var maximum = Int.min
        var total = 0
        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for sample in samples {
            minimum = min(minimum, sample.bpm)
            maximum = max(maximum, sample.bpm)
            total += sample.bpm
            count += 1
            let value = Double(sample.bpm)
            let delta = value - mean
            mean += delta / Double(count)
            m2 += delta * (value - mean)
        }
        return .init(
            minimum: minimum == Int.max ? nil : minimum,
            maximum: maximum == Int.min ? nil : maximum,
            total: total,
            count: count,
            mean: mean,
            m2: m2
        )
    }

    private nonisolated static func preparedMedian(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func applyPreparedActiveSessionJournalRestore(
        _ prepared: ActiveSessionRestorePreparation,
        generation: UInt64,
        reason: String
    ) {
        if activeSessionRestoreInFlightGeneration == generation {
            activeSessionRestoreInFlightGeneration = nil
        }
        guard Self.shouldAcceptActiveSessionJournalRestore(
            requestGeneration: generation,
            currentGeneration: activeSessionRestoreGeneration,
            longWearRelevant: Self.isBLEContinuityRelevant(
                longWearEnabled: longWearModeEnabled,
                activeExplicitWorkout: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
            ),
            hasLiveSession: !session.isEmpty
        ) else {
            AtriaDebugLog("ATRIADBG active_session_journal status=restore_rejected reason=%@ request_generation=%llu current_generation=%llu long_wear=%d live_samples=%d",
                          reason,
                          generation,
                          activeSessionRestoreGeneration,
                          longWearModeEnabled ? 1 : 0,
                          session.count)
            return
        }

        switch prepared.payload {
        case .terminal(.absent):
            AtriaDebugLog("ATRIADBG active_session_journal status=absent reason=%@", reason)
            return
        case let .terminal(.schemaMismatch(identity)):
            clearPreparedActiveSessionJournalIfUnchanged(identity, reason: "schema_mismatch")
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_scheduled reason=schema_mismatch schema=%d", identity.schema)
            return
        case let .terminal(.stale(age, identity)):
            clearPreparedActiveSessionJournalIfUnchanged(identity, reason: "stale")
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_scheduled reason=stale age_s=%.0f max_age_s=%.0f samples=%d",
                  age, activeJournalMaxAge, identity.sampleCount)
            return
        case let .terminal(.insufficientSamples(identity)):
            clearPreparedActiveSessionJournalIfUnchanged(identity, reason: "insufficient_samples")
            AtriaDebugLog("ATRIADBG active_session_journal status=clear_scheduled reason=insufficient_samples samples=%d", identity.sampleCount)
            return
        case let .staleSegment(payload):
            if payload.researchAggregatesWereMalformed {
                AtriaDebugLog("ATRIADBG active_session_journal status=research_aggregates_rejected reason=malformed")
            }
            let saved = payload.savedSession
            let persisted = persistFinishedSession(saved, reason: "stale_journal_restore")
            resetLiveSessionState(start: payload.now)
            AtriaDebugLog("ATRIADBG active_session_journal status=%@ reason=stale_restore age_s=%.0f threshold_s=%.1f samples=%d rr_values=%d duration_s=%.0f action=%@",
                  persisted ? "closed" : "close_failed",
                  payload.age,
                  activeJournalSegmentGapLimit,
                  saved.points.count,
                  saved.rrSampleCount,
                  saved.duration,
                  persisted ? "start_fresh_before_diagnostics" : "retain_store_for_retry")
            return
        case let .live(payload):
            applyPreparedLiveActiveSessionRestore(payload, reason: reason)
        }
    }

    private func clearPreparedActiveSessionJournalIfUnchanged(
        _ identity: ActiveSessionRestorePreparation.JournalIdentity,
        reason: String
    ) {
        Task.detached(priority: .utility) {
            let cleared = ActiveSessionJournal.clearIfUnchanged(
                id: identity.id,
                updatedAt: identity.updatedAt,
                schema: identity.schema,
                sampleCount: identity.sampleCount,
                rrSampleCount: identity.rrSampleCount
            )
            AtriaDebugLog(
                "ATRIADBG active_session_journal status=%@ reason=%@ samples=%d",
                cleared ? "cleared" : "clear_skipped_newer_checkpoint",
                reason,
                identity.sampleCount
            )
        }
    }

    private func applyPreparedLiveActiveSessionRestore(
        _ payload: ActiveSessionRestorePreparation.LivePayload,
        reason: String
    ) {
        let record = payload.record
        let now = payload.now
        if payload.researchAggregates == nil {
            AtriaDebugLog("ATRIADBG active_session_journal status=research_aggregates_rejected reason=malformed")
        }
        guard let first = payload.session.first, let last = payload.session.last else { return }

        liveSessionID = record.id
        liveSessionEventTimeZoneIdentifier = record.eventTimeZoneIdentifier ?? TimeZone.current.identifier
        sessionStart = first.t
        session = payload.session
        sessionOriginTime = first.t
        sessionPointsCache = payload.sessionPoints
        sessionActiveCaloriesCache = nil
        sessionMinHeartRate = payload.stats.minimum
        sessionMaxHeartRate = payload.stats.maximum
        sessionHeartRateTotal = payload.stats.total
        sessionHeartRateAggregateCount = payload.stats.count
        sessionHeartRateMean = payload.stats.mean
        sessionHeartRateM2 = payload.stats.m2
        publishSessionSampleCountIfNeeded(now: now, force: true)
        replaceLastHeartRates(payload.lastHeartRates)
        recentValid = payload.recentValid
        assignIfChanged(\.heartRate, payload.displayHeartRate)
        assignIfChanged(\.hasContact, true)
        rrArchive = payload.rrArchive
        rrPointsCache = payload.rrPoints
        noteRRArchiveDidChange()
        recentRRBeatTimes = payload.recentRRBeatTimes
        lastRRBeatTime = rrArchive.last?.t
        lastAcceptedHRAt = last.t
        lastRawHRNotificationAt = last.t
        lastStandardHR = (last.bpm, last.t)
        sessionRawHRNotifications = record.rawHRNotifications
        sessionAcceptedHRSamples = record.acceptedHRSamples
        sessionZeroHRSamples = record.zeroHRSamples
        sessionHeldArtifacts = record.heldArtifacts
        sessionDroppedArtifacts = record.droppedArtifacts
        sessionRawHRGaps = record.rawHRGaps
        sessionAcceptedHRGaps = record.acceptedHRGaps
        sessionMaxRawHRGap = record.maxRawHRGap
        sessionMaxAcceptedHRGap = record.maxAcceptedHRGap
        let researchAggregates = payload.researchAggregates ?? .zero
        researchProbeFrameCount = researchAggregates.sensorProbeFrames
        researchProbeOxygenCandidateFrames = researchAggregates.spo2CandidateFrames
        researchProbeTemperatureCandidateFrames = researchAggregates.skinTempCandidateFrames
        researchProbeTemperatureCandidateValueSum = researchAggregates.skinTempCandidateValueSum
        researchProbeTemperatureCandidateValueCount = researchAggregates.skinTempCandidateValueCount
        let restoredStepTotals = r10MotionPipeline.seedSynchronously(
            committedRawSteps: researchAggregates.strapRawSteps
        )
        strapStepResearchCount = max(researchAggregates.strapSteps, restoredStepTotals.steps)
        strapStepResearchPeakCount = max(researchAggregates.strapRawSteps, restoredStepTotals.rawSteps)
        strapStepResearchState = researchAggregates.strapStepState ?? "research_unvalidated"
        publishLiveStrapStepResearchIfNeeded(now: now, force: true)
        assignIfChanged(\.liveStrapStepResearchState, strapStepResearchState)
        activeJournalDirtySamples = 0
        lastActiveJournalSavedSessionSampleCount = session.count
        lastActiveJournalSavedRRArchiveCount = rrArchive.count
        lastActiveJournalPersistedSampleCount = session.count
        lastActiveJournalPersistedRRCount = rrArchive.count
        lastActiveJournalSavedResearchAggregates = researchAggregates
        if !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureLabel = record.label
        }
        let duration = last.t.timeIntervalSince(first.t)
        AtriaDebugLog("ATRIADBG active_session_journal status=restored reason=%@ samples=%d rr_values=%d duration_s=%.0f age_s=%.0f label=%@",
              reason, session.count, rrArchive.count, duration, payload.age, captureLabel)
    }

    private func invalidateActiveSessionJournalRestoreForLiveData() {
        guard activeSessionRestoreInFlightGeneration != nil else { return }
        activeSessionRestoreGeneration &+= 1
    }

    private func persistActiveSessionJournalIfNeeded(reason: String,
                                                     force: Bool,
                                                     refreshTimestampIfUnchanged: Bool = false) {
        guard longWearModeEnabled || AtriaPendingWorkoutIntent.isActiveForBLEContinuity() else { return }
        guard !session.isEmpty else { return }
        let researchAggregates = ResearchAggregates(
            sensorProbeFrames: researchProbeFrameCount,
            spo2CandidateFrames: researchProbeOxygenCandidateFrames,
            skinTempCandidateFrames: researchProbeTemperatureCandidateFrames,
            skinTempCandidateValueSum: researchProbeTemperatureCandidateValueSum,
            skinTempCandidateValueCount: researchProbeTemperatureCandidateValueCount,
            strapSteps: strapStepResearchCount,
            strapRawSteps: strapStepResearchPeakCount,
            strapStepState: strapStepResearchState
        )
        if force,
           !refreshTimestampIfUnchanged,
           !activeJournalSaveInFlight,
           activeJournalDirtySamples == 0,
           lastActiveJournalSavedSessionSampleCount == session.count,
           lastActiveJournalSavedRRArchiveCount == rrArchive.count,
           lastActiveJournalSavedResearchAggregates == researchAggregates {
            return
        }
        let flushSampleInterval = foregroundInteractiveMode
            ? activeJournalInteractiveFlushSampleInterval
            : activeJournalFlushSampleInterval
        let minimumFlushInterval = foregroundInteractiveMode
            ? activeJournalInteractiveFlushMinimumInterval
            : activeJournalUnattendedFlushMinimumInterval
        let governedMinimumFlushInterval = min(minimumFlushInterval * effectiveThermalCadenceMultiplier,
                                               activeJournalFreshnessFlushCeiling)
        let now = Date()
        if !force {
            activeJournalDirtySamples += 1
            guard activeJournalDirtySamples >= flushSampleInterval else { return }
            if let lastActiveJournalSaveAt,
               now.timeIntervalSince(lastActiveJournalSaveAt) < governedMinimumFlushInterval {
                activeJournalPendingSave = true
                return
            }
        }
        guard !activeJournalSaveInFlight else {
            activeJournalPendingSave = true
            activeJournalPendingTimestampRefresh = activeJournalPendingTimestampRefresh
                || refreshTimestampIfUnchanged
            return
        }
        guard let first = session.first, let finalSample = session.last else { return }
        // Live sessions roll well before the journal's age/count caps. Routine
        // checkpoints therefore need only the append-only tail; this avoids an
        // O(session) scan and copy on the main actor every minute.
        let previousJournalSampleCount = min(lastActiveJournalSavedSessionSampleCount, session.count)
        let previousJournalRRCount = min(lastActiveJournalSavedRRArchiveCount, rrArchive.count)
        let sessionSnapshot = session[previousJournalSampleCount...].map {
            ActiveSessionJournalRecord.Sample(t: $0.t, bpm: $0.bpm)
        }
        let rrArchiveSnapshot = rrArchive[previousJournalRRCount...].lazy
            .filter { $0.t >= first.t && $0.t <= finalSample.t.addingTimeInterval(1) }
            .map { ActiveSessionJournalRecord.RRSample(t: $0.t, ms: Int($0.ms.rounded())) }
        activeJournalSaveInFlight = true
        activeJournalPendingSave = false
        let rrDelta = Array(rrArchiveSnapshot)
        let previousPersistedSampleCount = lastActiveJournalPersistedSampleCount
        let previousPersistedRRCount = lastActiveJournalPersistedRRCount
        let sourceSessionCount = session.count
        let sourceRRCount = rrArchive.count
        let liveSessionID = liveSessionID
        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        let rawHRNotifications = sessionRawHRNotifications
        let acceptedHRSamples = sessionAcceptedHRSamples
        let zeroHRSamples = sessionZeroHRSamples
        let heldArtifacts = sessionHeldArtifacts
        let droppedArtifacts = sessionDroppedArtifacts
        let rawHRGaps = sessionRawHRGaps
        let acceptedHRGaps = sessionAcceptedHRGaps
        let maxRawHRGap = sessionMaxRawHRGap
        let maxAcceptedHRGap = sessionMaxAcceptedHRGap
        let batteryLevel = batteryLevel
        let thermalState = Self.thermalStateLabel(ProcessInfo.processInfo.thermalState)
        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let powerMode = effectivePowerThermalMode
        let cadenceMultiplier = effectiveThermalCadenceMultiplier
        let eventTimeZoneIdentifier = liveSessionEventTimeZoneIdentifier
        DispatchQueue.global(qos: .utility).async {
            // Strength metadata is mirrored in the latest segment, so the hot
            // save path does not need to reconstruct the all-day journal.
            let mirroredStrengthState = ActiveSessionJournal.latestMirroredStrengthState()
            let mirroredStrengthSets = mirroredStrengthState?.strengthSets
            let mirroredExcludedIntervals = mirroredStrengthState?.excludedIntervals
            let record = ActiveSessionJournalRecord(
                schema: ActiveSessionJournal.schema,
                id: liveSessionID,
                label: label,
                startedAt: first.t,
                updatedAt: now,
                samples: sessionSnapshot,
                rrSamples: rrDelta,
                rawHRNotifications: rawHRNotifications,
                acceptedHRSamples: acceptedHRSamples,
                zeroHRSamples: zeroHRSamples,
                heldArtifacts: heldArtifacts,
                droppedArtifacts: droppedArtifacts,
                rawHRGaps: rawHRGaps,
                acceptedHRGaps: acceptedHRGaps,
                maxRawHRGap: maxRawHRGap,
                maxAcceptedHRGap: maxAcceptedHRGap,
                batteryLevel: batteryLevel,
                thermalState: thermalState,
                lowPowerMode: lowPowerMode,
                powerMode: powerMode,
                cadenceMultiplier: cadenceMultiplier,
                strengthSets: mirroredStrengthSets,
                excludedIntervals: mirroredExcludedIntervals,
                eventTimeZoneIdentifier: eventTimeZoneIdentifier,
                sensorResearchProbeFrames: researchAggregates.sensorProbeFrames,
                spo2ResearchCandidateFrames: researchAggregates.spo2CandidateFrames,
                skinTempResearchCandidateFrames: researchAggregates.skinTempCandidateFrames,
                skinTempResearchCandidateValueSum: researchAggregates.skinTempCandidateValueSum,
                skinTempResearchCandidateValueCount: researchAggregates.skinTempCandidateValueCount,
                strapStepResearchCount: researchAggregates.strapSteps > 0 ? researchAggregates.strapSteps : nil,
                strapStepResearchRawCount: researchAggregates.strapRawSteps > 0 ? researchAggregates.strapRawSteps : nil,
                strapStepResearchState: researchAggregates.strapSteps > 0 ? researchAggregates.strapStepState : nil
            )
            let duration = finalSample.t.timeIntervalSince(first.t)
            do {
                let saveResult = try ActiveSessionJournal.saveIncremental(
                    record,
                    sampleStartIndex: previousPersistedSampleCount,
                    rrSampleStartIndex: previousPersistedRRCount,
                    maxAge: self.activeJournalMaxAge,
                    maxSamples: self.activeJournalMaxSamples
                )
                DispatchQueue.main.async {
                    self.activeJournalSaveInFlight = false
                    self.activeJournalDirtySamples = 0
                    self.lastActiveJournalSaveAt = now
                    self.lastActiveJournalSavedSessionSampleCount = sourceSessionCount
                    self.lastActiveJournalSavedRRArchiveCount = sourceRRCount
                    self.lastActiveJournalPersistedSampleCount = saveResult.sampleCount
                    self.lastActiveJournalPersistedRRCount = saveResult.rrSampleCount
                    self.lastActiveJournalSavedResearchAggregates = researchAggregates
                    AtriaDebugLog("ATRIADBG active_session_journal status=saved reason=%@ samples=%d rr_values=%d duration_s=%.0f dirty=0 label=%@",
                          reason, record.samples.count, record.rrSamples?.count ?? 0, duration, record.label)
                    if self.activeJournalPendingSave {
                        let refreshTimestamp = self.activeJournalPendingTimestampRefresh
                        self.activeJournalPendingSave = false
                        self.activeJournalPendingTimestampRefresh = false
                        self.activeJournalDirtySamples = max(self.activeJournalDirtySamples, flushSampleInterval)
                        self.persistActiveSessionJournalIfNeeded(
                            reason: "pending_flush",
                            force: refreshTimestamp,
                            refreshTimestampIfUnchanged: refreshTimestamp
                        )
                    }
                }
            } catch {
                if error is ActiveSessionJournal.IncrementalSaveError {
                    // A stale/corrupt cursor must not poison every future
                    // checkpoint. Reset durable state and let the immediate
                    // retry establish one complete bounded baseline.
                    ActiveSessionJournal.clear()
                }
                DispatchQueue.main.async {
                    self.activeJournalSaveInFlight = false
                    self.activeJournalDirtySamples = max(self.activeJournalDirtySamples, flushSampleInterval)
                    if error is ActiveSessionJournal.IncrementalSaveError {
                        self.lastActiveJournalSavedSessionSampleCount = 0
                        self.lastActiveJournalSavedRRArchiveCount = 0
                        self.lastActiveJournalPersistedSampleCount = 0
                        self.lastActiveJournalPersistedRRCount = 0
                        self.activeJournalPendingSave = true
                    }
                    AtriaDebugLog("ATRIADBG active_session_journal status=save_failed reason=%@ samples=%d error=%@",
                          reason, sessionSnapshot.count, error.localizedDescription)
                    if self.activeJournalPendingSave {
                        let refreshTimestamp = self.activeJournalPendingTimestampRefresh
                        self.activeJournalPendingSave = false
                        self.activeJournalPendingTimestampRefresh = false
                        self.persistActiveSessionJournalIfNeeded(
                            reason: "pending_retry",
                            force: refreshTimestamp,
                            refreshTimestampIfUnchanged: refreshTimestamp
                        )
                    }
                }
            }
        }
    }

    private func persistActiveSessionJournalForRRIfNeeded(reason: String, now: Date) {
        guard Self.shouldPersistRRJournal(
            longWearEnabled: longWearModeEnabled,
            activeExplicitWorkout: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        ) else { return }
        guard rrArchive.count > lastActiveJournalSavedRRArchiveCount else { return }
        guard !activeJournalSaveInFlight else {
            activeJournalPendingSave = true
            return
        }
        let minimumInterval = Self.rrJournalMinimumInterval(
            cadenceMultiplier: effectiveThermalCadenceMultiplier
        )
        if lastActiveJournalSavedRRArchiveCount > 0,
           let lastActiveJournalSaveAt,
           now.timeIntervalSince(lastActiveJournalSaveAt) < minimumInterval {
            activeJournalPendingSave = true
            return
        }
        persistActiveSessionJournalIfNeeded(reason: reason, force: true)
    }

    nonisolated static func shouldPersistRRJournal(longWearEnabled: Bool,
                                                   activeExplicitWorkout: Bool) -> Bool {
        longWearEnabled || activeExplicitWorkout
    }

    nonisolated static func rrJournalMinimumInterval(cadenceMultiplier: Double,
                                                     baseInterval: TimeInterval = 60) -> TimeInterval {
        min(75, max(30, baseInterval * max(1, cadenceMultiplier)))
    }

    private func configuredLongWearCheckpointInterval() -> TimeInterval {
        let configured = UserDefaults.standard.object(forKey: LongWearDefaults.checkpointInterval) as? Double ?? 60
        return max(10, min(configured, 3_600))
    }

    private func currentEventDrivenCheckpointInterval() -> TimeInterval {
        let configured = configuredLongWearCheckpointInterval()
        let base = foregroundInteractiveMode ? configured : max(minimumEventDrivenCheckpointInterval, configured)
        return base * effectiveThermalCadenceMultiplier
    }

    private nonisolated static func prunedJournalSamples(from samples: [HRSample],
                                                         now: Date,
                                                         maxAge: TimeInterval,
                                                         maxSamples: Int) -> ArraySlice<HRSample> {
        let capped = samples.suffix(maxSamples)
        guard let firstRecentIndex = capped.firstIndex(where: { now.timeIntervalSince($0.t) <= maxAge }) else {
            return []
        }
        return capped[firstRecentIndex...]
    }

    private nonisolated static func prunedJournalRRSamples(from samples: [RRInterval],
                                                           now: Date,
                                                           first: Date,
                                                           last: Date,
                                                           maxAge: TimeInterval,
                                                           maxSamples: Int) -> ArraySlice<RRInterval> {
        let capped = samples.suffix(maxSamples)
        guard let firstRecentIndex = capped.firstIndex(where: {
            now.timeIntervalSince($0.t) <= maxAge && $0.t >= first
        }) else {
            return []
        }
        return capped[firstRecentIndex...].prefix { $0.t <= last.addingTimeInterval(1) }
    }

    func flushActiveSessionJournal(reason: String) {
        persistActiveSessionJournalIfNeeded(reason: reason, force: true)
    }

    func flushLifecycleRealtimeState(reason: String,
                                     completion: (() -> Void)? = nil) {
        flushSampleDiagnostics()
        flushActiveSessionJournal(reason: reason)
        if let completion {
            finishWhenActiveJournalFlushSettles(reason: reason,
                                                startedAt: Date(),
                                                completion: completion)
        }
        AtriaDebugLog("ATRIADBG lifecycle_realtime_flush status=requested reason=%@ raw=%d accepted=%d in_flight=%d",
                      reason,
                      sampleDiagnostics.rawNotifications,
                      sampleDiagnostics.acceptedSamples,
                      activeJournalSaveInFlight ? 1 : 0)
    }

    private func finishWhenActiveJournalFlushSettles(reason: String,
                                                     startedAt: Date,
                                                     completion: @escaping () -> Void) {
        guard activeJournalSaveInFlight else {
            AtriaDebugLog("ATRIADBG lifecycle_realtime_flush status=completed reason=%@ elapsed_ms=%d",
                          reason,
                          Int(Date().timeIntervalSince(startedAt) * 1_000))
            completion()
            return
        }
        guard Date().timeIntervalSince(startedAt) < 3 else {
            AtriaDebugLog("ATRIADBG lifecycle_realtime_flush status=timed_out reason=%@ elapsed_ms=%d action=background_task_release",
                          reason,
                          Int(Date().timeIntervalSince(startedAt) * 1_000))
            completion()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finishWhenActiveJournalFlushSettles(reason: reason,
                                                startedAt: startedAt,
                                                completion: completion)
        }
    }

    private func scheduleDebugActiveJournalFlush(after seconds: TimeInterval) {
        debugActiveJournalFlushTask?.cancel()
        AtriaDebugLog("ATRIADBG active_session_journal debug_flush_schedule delay_s=%.1f", seconds)
        debugActiveJournalFlushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            flushActiveSessionJournal(reason: "debug_timer")
        }
    }

    private func recordLinkFailure(reason: String, error: Error?) {
        let defaults = UserDefaults.standard
        let failures = defaults.integer(forKey: LinkDefaults.failures) + 1
        let errorText = error?.localizedDescription ?? "nil"
        defaults.set(failures, forKey: LinkDefaults.failures)
        defaults.set("failed", forKey: LinkDefaults.lastStatus)
        defaults.set(reason, forKey: LinkDefaults.lastReason)
        defaults.set(errorText, forKey: LinkDefaults.lastError)
        if failures >= 2 || defaults.integer(forKey: LinkDefaults.successes) == 0 {
            persistOfficialAppCoexistenceRisk(.suspected, reason: "connect_failure_\(reason)")
        }
        AtriaDebugLog("ATRIADBG ble_link status=failed reason=%@ error=%@ attempts=%d disconnects=%d failures=%d action=fresh_scan",
              reason,
              errorText,
              defaults.integer(forKey: LinkDefaults.attempts),
              defaults.integer(forKey: LinkDefaults.disconnects),
              failures)
    }

    private func refreshOfficialAppCoexistenceRisk(reason: String) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: LinkDefaults.officialAppCoexistenceRisk) == nil {
            persistOfficialAppCoexistenceRisk(.advisory, reason: reason)
        } else {
            assignIfChanged(\.officialAppCoexistenceRisk, Self.officialAppCoexistenceRisk(defaults: defaults))
        }
    }

    private func persistOfficialAppCoexistenceRisk(_ risk: OfficialAppCoexistenceRisk,
                                                    reason: String) {
        let defaults = UserDefaults.standard
        let previous = Self.officialAppCoexistenceRisk(defaults: defaults)
        defaults.set(risk.rawValue, forKey: LinkDefaults.officialAppCoexistenceRisk)
        defaults.set(reason, forKey: LinkDefaults.officialAppCoexistenceReason)
        assignIfChanged(\.officialAppCoexistenceRisk, risk)
        guard previous != risk else { return }
        AtriaDebugLog("ATRIADBG official_app_coexistence status=%@ reason=%@ action=%@",
                      risk.rawValue,
                      reason,
                      risk == .suspected ? "show_user_uninstall_guidance" : "continue")
    }

    /// Zombie-link recovery requests a stronger intent from the same coalescer
    /// used by every soft watchdog. The coalescer performs at most one cancel;
    /// didDisconnectPeripheral then restores the known strap and subscriptions.
    private func forceHardReconnectForPacketStall(peripheral target: CBPeripheral, reason: String) {
        let now = Date()
        lastStallHardReconnectAt = now
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: KeepaliveDefaults.stallReconnects) + 1,
                     forKey: KeepaliveDefaults.stallReconnects)
        defaults.set(now.timeIntervalSince1970, forKey: KeepaliveDefaults.lastStallReconnectAt)
        defaults.synchronize()
        preserveLongWearRangeLossRecovery(reason: reason)
        AtriaDebugLog("ATRIADBG ble_link status=hard_reconnect reason=%@ action=coalesce_rebuild_request stall_reconnects=%d",
                      reason,
                      defaults.integer(forKey: KeepaliveDefaults.stallReconnects))
        requestFreshScanReconnect(peripheral: target,
                                  reason: reason,
                                  intent: .rebuildConnection)
    }

    private func requestFreshScanReconnect(peripheral target: CBPeripheral,
                                           reason: String,
                                           intent: AutomaticRecoveryIntent = .repairPipeline) {
        let defaults = UserDefaults.standard
        let streamState = defaults.string(forKey: StrapStreamDefaults.state)
        let streamBattery = defaults.object(forKey: StrapStreamDefaults.batteryLevel) as? Int ?? batteryLevel
        let cachedBatteryUsable = Self.cachedBattery(maxAge: Self.batteryDisplayFreshnessLimit).usable
        if streamState == StrapStreamState.lowBatteryShutoff.rawValue,
           streamBattery >= 0,
           streamBattery <= Self.lowBatteryBroadcastShutoffThreshold,
           cachedBatteryUsable,
           !batteryIsCharging {
            pendingRecoveryReconnectReason = nil
            pendingRecoveryIntent = .repairPipeline
            markLowBatteryReconnectSuppressed(reason: "low_battery_shutoff_fresh_scan", defaults: defaults)
            defaults.synchronize()
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_suppressed reason=%@ stream_state=%@ battery=%d action=keep_link_for_battery_reads",
                          reason,
                          streamState ?? "missing",
                          streamBattery)
            return
        }
        pendingRecoveryReconnectReason = reason
        pendingRecoveryIntent = Self.mergedRecoveryIntent(pendingRecoveryIntent, intent)
        if freshScanFallbackTask != nil {
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_coalesced reason=%@ pending_reason=%@ intent=%@ attempt=%d action=wait_existing_backoff",
                  reason,
                  pendingRecoveryReconnectReason ?? "unknown",
                  String(describing: pendingRecoveryIntent),
                  recoveryReconnectAttempt)
            return
        }
        recoveryReconnectAttempt += 1
        let delay = recoveryReconnectDelay(attempt: recoveryReconnectAttempt)
        AtriaDebugLog("ATRIADBG ble_link status=reconnect_request reason=%@ attempt=%d delay_s=%.2f action=backoff_connect_known_then_scan",
              reason,
              recoveryReconnectAttempt,
              delay)
        freshScanFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            let scheduledReason = self.pendingRecoveryReconnectReason ?? reason
            let scheduledIntent = self.pendingRecoveryIntent
            self.pendingRecoveryReconnectReason = nil
            self.pendingRecoveryIntent = .repairPipeline
            self.freshScanFallbackTask = nil
            guard target.state != .connecting else {
                AtriaDebugLog("ATRIADBG ble_link status=reconnect_skipped reason=%@ current_status=connecting",
                      scheduledReason)
                return
            }
            self.realtimeArmed = false
            self.txCharacteristic = nil
            self.heartRateCharacteristic = nil
            self.dbgTxReady = false
            if target.state == .disconnected || target.state == .disconnecting {
                self.peripheral = target
                self.recordLinkAttempt(reason: "\(scheduledReason)_known_peripheral", peripheral: target)
                self.recomputeConnectionStatus(reason: "event")
                self.central.connect(target, options: nil)
                self.startReconnectWatchdog(reason: "\(scheduledReason)_known_peripheral", peripheral: target)
                AtriaDebugLog("ATRIADBG ble_link status=reconnect_backoff reason=%@ attempt=%d action=connect_known_peripheral",
                      scheduledReason,
                      self.recoveryReconnectAttempt)
                return
            }
            if target.state == .connected {
                if scheduledIntent == .rebuildConnection {
                    self.forceFreshScanAfterDisconnect = false
                    AtriaDebugLog("ATRIADBG ble_link status=reconnect_backoff reason=%@ intent=rebuild action=cancel_once_then_reconnect_known",
                                  scheduledReason)
                    self.cancelPeripheralConnection(target,
                                                    reason: "\(scheduledReason)_rebuild")
                    return
                }
                // Universal backstop: the link is STILL up (a watchdog fired on a
                // transient data gap, not a real drop). Never cancel a healthy
                // connection or show Disconnected — re-discover services to restart
                // the data pipeline and heal the displayed status. A genuinely dead
                // radio link is detected by iOS supervision -> didDisconnectPeripheral.
                self.peripheral = target
                if self.status != .connected { self.recomputeConnectionStatus(reason: "event") }
                target.discoverServices(discoveryServicesForCurrentMode)
                AtriaDebugLog("ATRIADBG ble_link status=reconnect_skipped reason=%@ action=reassert_live_link",
                      scheduledReason)
                return
            }
            self.forceFreshScanAfterDisconnect = true
            self.cancelPeripheralConnection(target,
                                            reason: "\(scheduledReason)_fresh_scan_fallback")
            if self.peripheral === target {
                self.peripheral = nil
            }
            self.recomputeConnectionStatus(reason: "event")
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_backoff reason=%@ attempt=%d action=fresh_scan_fallback",
                  scheduledReason,
                  self.recoveryReconnectAttempt)
            self.startScan(reason: "\(scheduledReason)_fallback")
        }
    }

    private func recoveryReconnectDelay(attempt: Int) -> TimeInterval {
        let cappedAttempt = min(max(attempt, 1), 6)
        let base = min(60, pow(2.0, Double(cappedAttempt - 1)))
        let jitter = Double.random(in: 0.8...1.2)
        return base * jitter * effectiveThermalCadenceMultiplier
    }

    private func resetRecoveryReconnectBackoff(reason: String) {
        guard recoveryReconnectAttempt > 0
                || pendingRecoveryReconnectReason != nil
                || pendingRecoveryIntent != .repairPipeline else { return }
        recoveryReconnectAttempt = 0
        pendingRecoveryReconnectReason = nil
        pendingRecoveryIntent = .repairPipeline
        freshScanFallbackTask?.cancel()
        freshScanFallbackTask = nil
        AtriaDebugLog("ATRIADBG ble_link status=reconnect_backoff_reset reason=%@", reason)
    }

    private func recordRealGattData(at now: Date, source: String) {
        lastGattActivityAt = now
        if Self.shouldResetRecoveryBackoff(for: .characteristicValue) {
            resetRecoveryReconnectBackoff(reason: "real_gatt_data_\(source)")
        }
    }

    enum FailedConnectRecoveryDisposition: Equatable {
        case reconnectKnownAfterBackoff
        case waitForExistingConnect
        case scan
    }

    nonisolated static func failedConnectRecoveryDisposition(isSavedPeripheral: Bool,
                                                              isActuallyConnecting: Bool) -> FailedConnectRecoveryDisposition {
        guard isSavedPeripheral else { return .scan }
        return isActuallyConnecting ? .waitForExistingConnect : .reconnectKnownAfterBackoff
    }

    func applyLaunchAutomation(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard !launchAutomationApplied else { return }
        launchAutomationApplied = true
        resetLinkDiagnosticsForDebugLaunch(arguments: arguments)
        resetSampleDiagnosticsForDebugLaunch(arguments: arguments)
        resetProtocolDiagnosticsForDebugLaunch(arguments: arguments)
        resetRadioDiagnosticsForLaunch()
        applyCoexistenceRiskForDebugLaunch(arguments: arguments)
        applyOfflineSyncForDebugLaunch(arguments: arguments)
        UserDefaults.standard.set(false, forKey: CheckpointDefaults.armed)
        UserDefaults.standard.removeObject(forKey: CheckpointDefaults.interval)
        UserDefaults.standard.removeObject(forKey: CheckpointDefaults.label)
        UserDefaults.standard.removeObject(forKey: CheckpointDefaults.source)

        if arguments.contains("--atria-full-protocol-mode") {
            UserDefaults.standard.set(false, forKey: LongWearDefaults.enabled)
            longWearModeEnabled = false
            updateSessionPointCacheMode()
            forceFreshScanOnRestore = true
            stopLongWearMode(reason: "full_protocol_launch_arg")
            applyStandardHROnly(enabled: false, persist: true, reconnect: true, reason: "full_protocol_launch_arg")
            AtriaDebugLog("ATRIADBG full_protocol_mode request=launch_arg action=disable_long_wear_and_low_radio")
        } else if strapStepCalibrationCaptureUntil != nil {
            // Passive calibration only opens the validated-frame archive. The
            // protected stream was established by normal production startup;
            // leave its mode, connection, subscriptions and command state alone.
            AtriaDebugLog("ATRIADBG strap_step_calibration status=resumed transport=existing_protected_r10 mode_change=0 reconnect=0 cccd_changes=0 battery_reads=0 offline_sync=0 commands=0")
        } else if arguments.contains("--atria-long-wear-mode") {
            UserDefaults.standard.set(true, forKey: LongWearDefaults.enabled)
            longWearModeEnabled = true
            updateSessionPointCacheMode()
            AtriaDebugLog("ATRIADBG long_wear_mode request=launch_arg action=enable_persisted")
        }
        if let retriesIndex = arguments.firstIndex(of: "--atria-realtime-start-retries"),
           arguments.indices.contains(arguments.index(after: retriesIndex)),
           let retries = Int(arguments[arguments.index(after: retriesIndex)]) {
            realtimeStartRetries = max(0, min(retries, 12))
            AtriaDebugLog("ATRIADBG realtimeConfig start_retries=%d", realtimeStartRetries)
        }
        if arguments.contains("--atria-log-hr-consistency") {
            hrConsistencyEnabled = true
            AtriaDebugLog("ATRIADBG hr_consistency_config enabled=1 max_pair_age_s=5.0 recent_window=20 ready_recent_pairs=10 recent_max_delta_ready=2 recent_mean_delta_ready=1.0")
        }
        if arguments.contains("--atria-log-live-packets") {
            livePacketSummaryLoggingEnabled = true
            AtriaDebugLog("ATRIADBG live_packet_logging enabled=1 mode=summary")
        }
        if arguments.contains("--atria-log-ble-frames") {
            verboseBLEFrameLogging = true
            AtriaDebugLog("ATRIADBG ble_frame_logging enabled=1 reason=launch_arg")
        }
        if arguments.contains("--atria-store-ble-frames") {
            storeProprietaryFrames = true
            storeProprietaryFramesMode = true
            AtriaDebugLog("ATRIADBG ble_frame_history enabled=1 reason=launch_arg")
        }
        protocolDiagnosticsPersistenceEnabled =
            arguments.contains("--atria-active-motion-imu-check")
            || arguments.contains("--atria-reset-protocol-diagnostics")
            || verboseBLEFrameLogging
        if arguments.contains("--atria-standard-hr-only") {
            applyStandardHROnly(enabled: true, persist: false, reconnect: false, reason: "launch_arg")
            AtriaDebugLog("ATRIADBG protected_r10_minimal enabled=1 full_realtime_start=skipped stream5_r10=enabled history_ack=disabled")
        }
        if arguments.contains("--atria-log-hr-artifact-policy") {
            logHRArtifactPolicySelfTest()
        }
        if let flushIndex = arguments.firstIndex(of: "--atria-flush-active-journal-after"),
           arguments.indices.contains(arguments.index(after: flushIndex)),
           let seconds = Double(arguments[arguments.index(after: flushIndex)]) {
            scheduleDebugActiveJournalFlush(after: max(1, min(seconds, 300)))
        }
        if let watchdogIndex = arguments.firstIndex(of: "--atria-force-no-data-watchdog-after"),
           arguments.indices.contains(arguments.index(after: watchdogIndex)),
           let seconds = Double(arguments[arguments.index(after: watchdogIndex)]) {
            scheduleDebugNoDataWatchdog(after: max(1, min(seconds, 300)))
        }
        if let watchdogIndex = arguments.firstIndex(of: "--atria-force-accepted-hr-watchdog-after"),
           arguments.indices.contains(arguments.index(after: watchdogIndex)),
           let seconds = Double(arguments[arguments.index(after: watchdogIndex)]) {
            scheduleDebugAcceptedHRWatchdog(after: max(1, min(seconds, 300)))
        }
        if let watchdogIndex = arguments.firstIndex(of: "--atria-force-hr-continuity-watchdog-after"),
           arguments.indices.contains(arguments.index(after: watchdogIndex)),
           let seconds = Double(arguments[arguments.index(after: watchdogIndex)]) {
            scheduleDebugHRContinuityWatchdog(after: max(0, min(seconds, 300)))
        }
        if let watchdogIndex = arguments.firstIndex(of: "--atria-force-rr-presence-watchdog-after"),
           arguments.indices.contains(arguments.index(after: watchdogIndex)),
           let seconds = Double(arguments[arguments.index(after: watchdogIndex)]) {
            scheduleDebugRRPresenceWatchdog(after: max(0, min(seconds, 300)))
        }
        if let missingIndex = arguments.firstIndex(of: "--atria-force-missing-2a37-after"),
           arguments.indices.contains(arguments.index(after: missingIndex)),
           let seconds = Double(arguments[arguments.index(after: missingIndex)]) {
            armDebugMissingHeartRateCharacteristic(after: max(0, min(seconds, 300)))
        }
        if arguments.contains("--atria-log-hr-continuity-watchdog-state") {
            logHRContinuityWatchdogState(reason: "launch_arg")
        }
        if let restartIndex = arguments.firstIndex(of: "--atria-realtime-restart-zero-rr-seconds"),
           arguments.indices.contains(arguments.index(after: restartIndex)),
           let seconds = Double(arguments[arguments.index(after: restartIndex)]) {
            realtimeRestartAfterZeroRRSeconds = max(0, min(seconds, 300))
            AtriaDebugLog("ATRIADBG realtimeConfig restart_zero_rr_s=%.1f", realtimeRestartAfterZeroRRSeconds)
        }
        if let reassertIndex = arguments.firstIndex(of: "--atria-realtime-reassert-zero-rr-seconds"),
           arguments.indices.contains(arguments.index(after: reassertIndex)),
           let seconds = Double(arguments[arguments.index(after: reassertIndex)]) {
            realtimeReassertStartAfterZeroRRSeconds = max(0, min(seconds, 300))
            AtriaDebugLog("ATRIADBG realtimeConfig reassert_zero_rr_s=%.1f", realtimeReassertStartAfterZeroRRSeconds)
        }
        if let modeIndex = arguments.firstIndex(of: "--atria-probe-command-mode"),
           arguments.indices.contains(arguments.index(after: modeIndex)) {
            let rawMode = arguments[arguments.index(after: modeIndex)].lowercased()
            probeCommandMode = rawMode == CommandWriteMode.withResponse.rawValue ? .withResponse : .withoutResponse
        }
        if let delayIndex = arguments.firstIndex(of: "--atria-probe-command-delay"),
           arguments.indices.contains(arguments.index(after: delayIndex)),
           let seconds = Double(arguments[arguments.index(after: delayIndex)]) {
            probeCommandDelaySeconds = max(0, min(seconds, 300))
        }
        if let intervalIndex = arguments.firstIndex(of: "--atria-probe-sweep-interval"),
           arguments.indices.contains(arguments.index(after: intervalIndex)),
           let seconds = Double(arguments[arguments.index(after: intervalIndex)]) {
            probeSweepIntervalSeconds = max(5, min(seconds, 300))
        }
        if let commandIndex = arguments.firstIndex(of: "--atria-probe-command"),
           arguments.indices.contains(arguments.index(after: commandIndex)) {
            let rawHex = arguments[arguments.index(after: commandIndex)]
            probeCommand = Self.parseHexBytes(rawHex)
            if let probeCommand, let first = probeCommand.first {
                let data = probeCommand.dropFirst().map { String(format: "%02x", $0) }.joined()
                AtriaDebugLog("ATRIADBG realtimeConfig probe_cmd=%02x data=%@ delay_s=%.1f mode=%@",
                      first, data, probeCommandDelaySeconds, probeCommandMode.rawValue)
            } else {
                AtriaDebugLog("ATRIADBG realtimeConfig probe_cmd_invalid=%@", rawHex)
            }
        }
        if let sweepIndex = arguments.firstIndex(of: "--atria-probe-sweep"),
           arguments.indices.contains(arguments.index(after: sweepIndex)) {
            let rawSweep = arguments[arguments.index(after: sweepIndex)]
            probeSweepCommands = rawSweep
                .split(separator: ",")
                .compactMap { Self.parseHexBytes(String($0)) }
                .filter { !$0.isEmpty }
            let labels = probeSweepCommands.enumerated().map { index, command in
                "\(index):\(Self.hex(command))"
            }.joined(separator: ",")
            AtriaDebugLog("ATRIADBG realtimeConfig probe_sweep=%@ interval_s=%.1f",
                  labels, probeSweepIntervalSeconds)
        }
        if arguments.contains("--atria-disable-history-ack") {
            historicalAckDisabled = true
            AtriaDebugLog("ATRIADBG realtimeConfig history_ack=disabled")
        }
        if let modeIndex = arguments.firstIndex(of: "--atria-history-ack-mode"),
           arguments.indices.contains(arguments.index(after: modeIndex)) {
            let mode = arguments[arguments.index(after: modeIndex)]
            let supportedModes = ["trim", "enddata", "index", "unix", "zero", "none"]
            if supportedModes.contains(mode) {
                historyAckMode = mode
            }
            AtriaDebugLog("ATRIADBG realtimeConfig history_ack_mode=%@", historyAckMode)
        }
        if arguments.contains("--atria-history-recent-sweep") {
            historyRecentSweepEnabled = true
            if let offsetsIndex = arguments.firstIndex(of: "--atria-history-recent-offsets"),
               arguments.indices.contains(arguments.index(after: offsetsIndex)) {
                let rawOffsets = arguments[arguments.index(after: offsetsIndex)]
                let parsed = rawOffsets
                    .split(separator: ",")
                    .compactMap { UInt32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .filter { $0 <= 86_400 }
                if !parsed.isEmpty {
                    historyRecentSweepOffsets = parsed
                }
            }
            AtriaDebugLog("ATRIADBG realtimeConfig history_recent_sweep=1 offsets=%@",
                  historyRecentSweepOffsets.map(String.init).joined(separator: ","))
        }
        if arguments.contains("--atria-history-clock-handshake") || arguments.contains("--atria-history-clock-sync") {
            historyClockSyncEnabled = true
            AtriaDebugLog("ATRIADBG realtimeConfig history_clock_handshake=1 set_clock_forms=8,9 get_clock_payloads=empty,00")
        }
        if arguments.contains("--atria-history-selector-sweep") {
            historySelectorSweepEnabled = true
            if let modeIndex = arguments.firstIndex(of: "--atria-history-selector-mode"),
               arguments.indices.contains(arguments.index(after: modeIndex)) {
                let mode = arguments[arguments.index(after: modeIndex)]
                let supportedModes = [
                    "current-unix-bare",
                    "current-unix-prefix0",
                    "current-unix-prefix1",
                    "current-unix-all",
                    "current-record8",
                    "known-block-record8",
                    "range-window24",
                    "record-shape-all",
                ]
                if supportedModes.contains(mode) {
                    historySelectorMode = mode
                }
            }
            AtriaDebugLog("ATRIADBG realtimeConfig history_selector_sweep=1 mode=%@", historySelectorMode)
        }
        if value(after: "--atria-history-selector-range-index", in: arguments) != nil {
            let index = intValue(after: "--atria-history-selector-range-index",
                                 in: arguments,
                                 default: 0,
                                 range: 0...255)
            historySelectorRangeIndex = index
            AtriaDebugLog("ATRIADBG realtimeConfig history_selector_range_index=%d", index)
        }
        if arguments.contains("--atria-history-range-sweep") {
            historyDataRangeSweepEnabled = true
            if let payloadsIndex = arguments.firstIndex(of: "--atria-history-range-payloads"),
               arguments.indices.contains(arguments.index(after: payloadsIndex)) {
                let rawPayloads = arguments[arguments.index(after: payloadsIndex)]
                let parsed = rawPayloads
                    .split(separator: ",")
                    .compactMap { Self.parseHexBytes(String($0)) }
                    .filter { !$0.isEmpty }
                if !parsed.isEmpty {
                    historyDataRangeSweepPayloads = parsed
                }
            }
            let labels = historyDataRangeSweepPayloads.enumerated().map { index, payload in
                "\(index):\(Self.hex(payload))"
            }.joined(separator: ",")
            AtriaDebugLog("ATRIADBG realtimeConfig history_range_sweep=1 payloads=%@", labels)
        }
        if let initIndex = arguments.firstIndex(of: "--atria-history-init-sweep"),
           arguments.indices.contains(arguments.index(after: initIndex)) {
            let rawSweep = arguments[arguments.index(after: initIndex)]
            historyInitSweepCommands = rawSweep
                .split(separator: ",")
                .compactMap { Self.parseHexBytes(String($0)) }
                .filter { !$0.isEmpty }
            let labels = historyInitSweepCommands.enumerated().map { index, command in
                "\(index):\(Self.hex(command))"
            }.joined(separator: ",")
            AtriaDebugLog("ATRIADBG realtimeConfig history_init_sweep=%@", labels)
        }
        if arguments.contains("--atria-history-skip-range") {
            historySkipDataRangeRequest = true
            AtriaDebugLog("ATRIADBG realtimeConfig history_skip_range=1")
        }
        if arguments.contains("--atria-history-only-probe") {
            historyOnlyProbeEnabled = true
            historyOnlyProbeMode = true
            realtimeStartRetries = 0
            AtriaDebugLog("ATRIADBG realtimeConfig history_only_probe=1 realtime_start=skipped cmd22=%d init_sweep=%d range_sweep=%d selector_sweep=%d mode=%@",
                  historySkipDataRangeRequest ? 0 : 1,
                  historyInitSweepCommands.isEmpty ? 0 : 1,
                  historyDataRangeSweepEnabled ? 1 : 0,
                  historySelectorSweepEnabled ? 1 : 0,
                  historySelectorMode)
        }
        if let label = value(after: "--atria-capture-label", in: arguments),
           !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureLabel = label
        }
        if arguments.contains("--atria-morning-hrv-force") {
            morningHRVForce = true
        }
        let hasExplicitSessionPersistence =
            arguments.contains("--atria-auto-save-session-after") ||
            arguments.contains("--atria-auto-save-session-every") ||
            arguments.contains("--atria-checkpoint-session-every")
        if let saveIndex = arguments.firstIndex(of: "--atria-auto-save-session-after"),
           arguments.indices.contains(arguments.index(after: saveIndex)),
           let seconds = Double(arguments[arguments.index(after: saveIndex)]) {
            scheduleDelayedSessionSave(after: max(1, min(seconds, 86_400)))
        }
        if let saveEveryIndex = arguments.firstIndex(of: "--atria-auto-save-session-every"),
           arguments.indices.contains(arguments.index(after: saveEveryIndex)),
           let seconds = Double(arguments[arguments.index(after: saveEveryIndex)]) {
            schedulePeriodicSessionSave(every: max(10, min(seconds, 86_400)))
        }
        if let checkpointEveryIndex = arguments.firstIndex(of: "--atria-checkpoint-session-every"),
           arguments.indices.contains(arguments.index(after: checkpointEveryIndex)),
           let seconds = Double(arguments[arguments.index(after: checkpointEveryIndex)]) {
            scheduleSessionCheckpoint(every: max(10, min(seconds, 86_400)),
                                      fallbackLabel: "Checkpoint",
                                      source: "launch_arg")
        }
        if let manualCheckpointIndex = arguments.firstIndex(of: "--atria-manual-checkpoint-after"),
           arguments.indices.contains(arguments.index(after: manualCheckpointIndex)),
           let seconds = Double(arguments[arguments.index(after: manualCheckpointIndex)]) {
            scheduleDebugManualCheckpoint(after: max(1, min(seconds, 3_600)))
        }
        if !hasExplicitSessionPersistence && !longWearModeEnabled {
            scheduleSessionCheckpoint(every: 300,
                                      fallbackLabel: "Unattended checkpoint",
                                      source: "default_foreground")
        }
        if arguments.contains("--atria-morning-hrv-check") {
            configureMorningHRVCapture(arguments: arguments)
            return
        }
        guard arguments.contains("--atria-auto-capture") else { return }
        if let labelIndex = arguments.firstIndex(of: "--atria-capture-label"),
           arguments.indices.contains(arguments.index(after: labelIndex)) {
            captureLabel = arguments[arguments.index(after: labelIndex)]
        }
        if captureLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureLabel = "gate-b-auto"
        }
        strictLiveRRCapture = arguments.contains("--atria-strict-live-rr-capture")
        autoStopCaptureWhenReady = arguments.contains("--atria-stop-when-ready")
        if let delayIndex = arguments.firstIndex(of: "--atria-auto-capture-delay"),
           arguments.indices.contains(arguments.index(after: delayIndex)),
           let seconds = Double(arguments[arguments.index(after: delayIndex)]) {
            autoCaptureDelaySeconds = max(0, min(seconds, 3_600))
        }
        if let thresholdIndex = arguments.firstIndex(of: "--atria-auto-capture-when-rr"),
           arguments.indices.contains(arguments.index(after: thresholdIndex)),
           let threshold = Double(arguments[arguments.index(after: thresholdIndex)]) {
            autoCaptureRRThreshold = max(0, min(threshold, 1))
        }
        if let windowIndex = arguments.firstIndex(of: "--atria-auto-capture-rr-window"),
           arguments.indices.contains(arguments.index(after: windowIndex)),
           let seconds = Double(arguments[arguments.index(after: windowIndex)]) {
            autoCaptureRRWindowSeconds = max(1, min(seconds, 300))
        }
        if let minFramesIndex = arguments.firstIndex(of: "--atria-auto-capture-rr-min-frames"),
           arguments.indices.contains(arguments.index(after: minFramesIndex)),
           let frames = Int(arguments[arguments.index(after: minFramesIndex)]) {
            autoCaptureRRMinFrames = max(1, min(frames, 1_000))
        }
        if let maxGapIndex = arguments.firstIndex(of: "--atria-auto-capture-max-rr-gap"),
           arguments.indices.contains(arguments.index(after: maxGapIndex)),
           let seconds = Double(arguments[arguments.index(after: maxGapIndex)]) {
            autoCaptureMaxRRGapSeconds = max(0, min(seconds, 60))
        }
        if let timeoutIndex = arguments.firstIndex(of: "--atria-auto-capture-rr-timeout"),
           arguments.indices.contains(arguments.index(after: timeoutIndex)),
           let seconds = Double(arguments[arguments.index(after: timeoutIndex)]) {
            autoCaptureRRTimeoutSeconds = max(0, min(seconds, 3_600))
        }
        if let attemptsIndex = arguments.firstIndex(of: "--atria-auto-capture-max-attempts"),
           arguments.indices.contains(arguments.index(after: attemptsIndex)),
           let attempts = Int(arguments[arguments.index(after: attemptsIndex)]) {
            autoCaptureMaxAttempts = max(1, min(attempts, 50))
        }
        if let stopIndex = arguments.firstIndex(of: "--atria-auto-stop-after"),
           arguments.indices.contains(arguments.index(after: stopIndex)),
           let seconds = Double(arguments[arguments.index(after: stopIndex)]) {
            autoStopCaptureAfterSeconds = max(0, min(seconds, 3_600))
        }
        if !isRecording {
            scheduleAutoCapture()
        }
    }

    func scheduleLiveWorkoutDiagnosticsIfRequested(rest: Int, maxHR: Int, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let raw = value(after: "--atria-log-live-workout-every", in: arguments),
              let requestedSeconds = Double(raw) else { return }
        let seconds = max(5, min(requestedSeconds, 3_600))
        let label = captureLabel.isEmpty ? "Live workout" : captureLabel
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        liveWorkoutDiagnosticTask?.cancel()
        AtriaDebugLog("ATRIADBG live_workout schedule interval_s=%.1f rest_hr=%d max_hr=%d threshold_hr=%d label=%@",
              seconds, rest, maxHR, threshold, label)
        liveWorkoutDiagnosticTask = Task { @MainActor in
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                guard session.count >= autoSaveMinSamples else {
                    AtriaDebugLog("ATRIADBG live_workout status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@",
                          session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
                    index += 1
                    continue
                }
                guard let saved = snapshotSession(label: label) else {
                    AtriaDebugLog("ATRIADBG live_workout status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@",
                          session.count, rest, maxHR, threshold, index, label)
                    index += 1
                    continue
                }
                persistActiveSessionJournalIfNeeded(reason: "live_workout_diagnostic", force: true)
                let readiness = saved.workoutReadiness(rest: rest, maxHR: maxHR)
                let capture = workoutCaptureEvidence(for: saved, readiness: readiness)
                AtriaDebugLog("ATRIADBG live_workout tick=%d status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d samples=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d threshold_gap_bpm=%d avg_over_rest=%d peak_over_rest=%d elevated_s=%.0f elevated_fraction=%.3f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f hr_distribution_below_workout_band=%d next_action=%@ ready=%d capture_diagnosis=%@ capture_action=%@ %@ label=%@",
                      index,
                      readiness.status,
                      readiness.reason,
                      readiness.primaryBlocker,
                      readiness.streamCoveragePercent,
                      saved.points.count,
                      readiness.duration,
                      readiness.observedDuration,
                      readiness.droppedGapSeconds,
                      readiness.maxSampleGap,
                      readiness.gapCount,
                      readiness.avgHR,
                      readiness.peakHR,
                      rest,
                      maxHR,
                      readiness.thresholdHR,
                      readiness.thresholdGapBPM,
                      readiness.avgOverRest,
                      readiness.peakOverRest,
                      readiness.elevatedSeconds,
                      readiness.elevatedFraction,
                      readiness.requiredElevatedSeconds,
                      readiness.longestElevatedBout,
                      readiness.requiredElevatedBout,
                      readiness.hrDistributionBelowWorkoutBand ? 1 : 0,
                      readiness.nextAction,
                      readiness.ready ? 1 : 0,
                      capture.diagnosis,
                      capture.action,
                      capture.sampleFields,
                      label)
                index += 1
            }
        }
    }

    func scheduleWorkoutAutoSaveIfRequested(rest: Int, maxHR: Int, arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let raw = value(after: "--atria-auto-save-workout-when-ready", in: arguments),
              let requestedSeconds = Double(raw) else { return }
        let seconds = max(5, min(requestedSeconds, 300))
        let label = captureLabel.isEmpty ? "Auto workout" : captureLabel
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        workoutAutoSaveTask?.cancel()
        AtriaDebugLog("ATRIADBG workout_auto_save schedule interval_s=%.1f rest_hr=%d max_hr=%d threshold_hr=%d label=%@",
              seconds, rest, maxHR, threshold, label)
        workoutAutoSaveTask = Task { @MainActor in
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                guard session.count >= autoSaveMinSamples else {
                    AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@",
                          session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
                    index += 1
                    continue
                }
                guard let snapshot = snapshotSession(label: label) else {
                    AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@",
                          session.count, rest, maxHR, threshold, index, label)
                    index += 1
                    continue
                }
                persistActiveSessionJournalIfNeeded(reason: "workout_auto_save_check", force: true)
                let readiness = snapshot.workoutReadiness(rest: rest, maxHR: maxHR)
                guard readiness.ready else {
                    let capture = workoutCaptureEvidence(for: snapshot, readiness: readiness)
                    AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=%@ primary_blocker=%@ stream_coverage_percent=%d tick=%d samples=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d threshold_gap_bpm=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f hr_distribution_below_workout_band=%d next_action=%@ capture_diagnosis=%@ capture_action=%@ %@ label=%@",
                          readiness.reason,
                          readiness.primaryBlocker,
                          readiness.streamCoveragePercent,
                          index,
                          snapshot.points.count,
                          readiness.duration,
                          readiness.observedDuration,
                          readiness.droppedGapSeconds,
                          readiness.maxSampleGap,
                          readiness.gapCount,
                          readiness.avgHR,
                          readiness.peakHR,
                          rest,
                          maxHR,
                          readiness.thresholdHR,
                          readiness.thresholdGapBPM,
                          readiness.elevatedSeconds,
                          readiness.requiredElevatedSeconds,
                          readiness.longestElevatedBout,
                          readiness.requiredElevatedBout,
                          readiness.hrDistributionBelowWorkoutBand ? 1 : 0,
                          readiness.nextAction,
                          capture.diagnosis,
                          capture.action,
                          capture.sampleFields,
                          label)
                    index += 1
                    continue
                }
                guard let saved = finishSession(label: label) else {
                    AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=finish_failed samples=%d label=%@", session.count, label)
                    index += 1
                    continue
                }
                let persisted = persistFinishedSession(saved, reason: "workout_auto_save")
                let savedReadiness = saved.workoutReadiness(rest: rest, maxHR: maxHR)
                let capture = workoutCaptureEvidence(for: saved, readiness: savedReadiness)
                AtriaDebugLog("ATRIADBG workout_auto_save status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d tick=%d samples=%d duration_s=%.0f observed_duration_s=%.0f dropped_gap_s=%.0f max_gap_s=%.1f gap_count=%d avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d threshold_gap_bpm=%d elevated_s=%.0f required_elevated_s=%.0f longest_bout_s=%.0f required_bout_s=%.0f hr_distribution_below_workout_band=%d next_action=%@ capture_diagnosis=%@ capture_action=%@ %@ hrv=%@ label=%@",
                      persisted ? "saved" : "store_failed",
                      savedReadiness.reason,
                      savedReadiness.primaryBlocker,
                      savedReadiness.streamCoveragePercent,
                      index,
                      saved.points.count,
                      savedReadiness.duration,
                      savedReadiness.observedDuration,
                      savedReadiness.droppedGapSeconds,
                      savedReadiness.maxSampleGap,
                      savedReadiness.gapCount,
                      savedReadiness.avgHR,
                      savedReadiness.peakHR,
                      rest,
                      maxHR,
                      savedReadiness.thresholdHR,
                      savedReadiness.thresholdGapBPM,
                      savedReadiness.elevatedSeconds,
                      savedReadiness.requiredElevatedSeconds,
                      savedReadiness.longestElevatedBout,
                      savedReadiness.requiredElevatedBout,
                      savedReadiness.hrDistributionBelowWorkoutBand ? 1 : 0,
                      savedReadiness.nextAction,
                      capture.diagnosis,
                      capture.action,
                      capture.sampleFields,
                      saved.hrv.map(String.init) ?? "learning",
                      label)
                break
            }
        }
    }

    private func scheduleLongWearSupervisor(config: LongWearSupervisorConfig) {
        if longWearSupervisorTask != nil, activeLongWearSupervisorConfig == config {
            AtriaDebugLog("ATRIADBG long_wear_supervisor schedule action=keep_existing base_tick_s=%.1f label=%@",
                          config.baseTickInterval,
                          config.label)
            return
        }
        longWearSupervisorTask?.cancel()
        activeLongWearSupervisorConfig = config
        UserDefaults.standard.set(true, forKey: CheckpointDefaults.armed)
        UserDefaults.standard.set(config.checkpointInterval, forKey: CheckpointDefaults.interval)
        UserDefaults.standard.set(config.label, forKey: CheckpointDefaults.label)
        UserDefaults.standard.set("long_wear_supervisor", forKey: CheckpointDefaults.source)
        AtriaDebugLog("ATRIADBG long_wear_supervisor schedule base_tick_s=%.1f checkpoint_s=%.1f diagnostic_s=%.1f auto_save_s=%.1f no_data_timeout_s=%.1f hr_continuity_timeout_s=%.1f rr_presence_timeout_s=%.1f accepted_hr_timeout_s=%.1f label=%@",
              config.baseTickInterval,
              config.checkpointInterval,
              config.diagnosticInterval,
              config.autoSaveInterval,
              config.noDataTimeout,
              config.hrContinuityTimeout,
              config.rrPresenceTimeout,
              config.acceptedHRTimeout,
              config.label)
        longWearSupervisorTask = Task { @MainActor in
            var checkpointIndex = 1
            var diagnosticIndex = 1
            var autoSaveIndex = 1
            var rrPresenceConsecutive = 0
            var lastDiagnosticAt = Date()
            var lastAutoSaveAt = Date()
            var lastThermalAnalysisDeferralLogAt: Date?
            var lastThermalCheckpointDeferralLogAt: Date?
            var lastHRContinuityActionAt: Date?
            var lastRRPresenceActionAt: Date?
            while !Task.isCancelled {
                let governedTick = config.baseTickInterval * effectiveThermalCadenceMultiplier
                try? await Task.sleep(for: .seconds(governedTick))
                if Task.isCancelled { break }
                // The supervisor protects session durability and link health in
                // both radio modes. Full protocol is now the protected default
                // because it carries R10 motion/steps; retaining the legacy
                // HR-only gate silently disabled checkpoints, workout analysis
                // and watchdog recovery whenever background steps were enabled.
                guard Self.shouldRunLongWearSupervisor(
                    longWearEnabled: longWearModeEnabled,
                    standardHROnlyMode: standardHROnlyMode
                ) else { continue }
                guard status == .connected else { continue }
                let now = Date()
                let cadenceMultiplier = effectiveThermalCadenceMultiplier
                // Refresh means subscribe once or keep awaiting the existing
                // standard notification. Production never performs an explicit
                // 2A19 read here.
                if Self.shouldRequestBatteryRefresh(lastRequestedAt: lastBatteryReadRequestedAt,
                                                    now: now) {
                    requestStrapStatusRead(reason: "long_wear_battery_freshness")
                }
                scheduleStaleArmedRangeLossBackfillReconciliation(reason: "long_wear_supervisor_tick",
                                                                  now: now)

                let thermalPressure = powerThermalGovernor.shouldDeferNonEssentialAnalysis
                let canonicalCheckpointInterval = thermalPressure
                    ? Self.thermalJournalCheckpointInterval
                    : config.checkpointInterval * cadenceMultiplier
                if Self.shouldRunCanonicalCheckpoint(now: now,
                                                     lastCheckpointAt: lastCanonicalCheckpointAt,
                                                     minimumInterval: canonicalCheckpointInterval) {
                    if thermalPressure {
                        lastCanonicalCheckpointAt = now
                        persistActiveSessionJournalIfNeeded(
                            reason: "thermal_pressure_minimal_checkpoint",
                            force: true,
                            refreshTimestampIfUnchanged: true
                        )
                        if lastThermalCheckpointDeferralLogAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                            lastThermalCheckpointDeferralLogAt = now
                            AtriaDebugLog("ATRIADBG long_wear_supervisor thermal_checkpoint_deferral status=minimal_journal_only mode=%@ multiplier=%.1f samples=%d label=%@",
                                  effectivePowerThermalMode,
                                  cadenceMultiplier,
                                  session.count,
                                  config.label)
                        }
                    } else {
                        runLongWearSupervisorCheckpoint(index: checkpointIndex,
                                                        label: config.label,
                                                        now: now)
                    }
                    checkpointIndex += 1
                }

                let deferSessionAnalysis = powerThermalGovernor.shouldDeferNonEssentialAnalysis
                if deferSessionAnalysis,
                   (lastThermalAnalysisDeferralLogAt.map { now.timeIntervalSince($0) >= 300 } ?? true) {
                    lastThermalAnalysisDeferralLogAt = now
                    AtriaDebugLog("ATRIADBG long_wear_supervisor thermal_analysis_deferral status=deferred mode=%@ multiplier=%.1f low_power=%d thermal=%@ samples=%d label=%@",
                          effectivePowerThermalMode,
                          cadenceMultiplier,
                          ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
                          Self.thermalStateLabel(ProcessInfo.processInfo.thermalState),
                          session.count,
                          config.label)
                }

                let diagnosticDue = !deferSessionAnalysis
                    && now.timeIntervalSince(lastDiagnosticAt) >= config.diagnosticInterval * cadenceMultiplier
                let autoSaveDue = !deferSessionAnalysis
                    && now.timeIntervalSince(lastAutoSaveAt) >= config.autoSaveInterval * cadenceMultiplier
                let sharedAnalysis: LongWearSessionAnalysis
                if (diagnosticDue || autoSaveDue), session.count >= autoSaveMinSamples {
                    let snapshot = snapshotSession(label: config.label)
                    sharedAnalysis = LongWearSessionAnalysis(snapshot: snapshot,
                                                             readiness: snapshot?.workoutReadiness(rest: config.rest,
                                                                                                    maxHR: config.maxHR))
                } else {
                    sharedAnalysis = LongWearSessionAnalysis(snapshot: nil, readiness: nil)
                }

                if diagnosticDue {
                    runLongWearSupervisorDiagnostic(index: diagnosticIndex,
                                                    label: config.label,
                                                    rest: config.rest,
                                                    maxHR: config.maxHR,
                                                    analysis: sharedAnalysis)
                    diagnosticIndex += 1
                    lastDiagnosticAt = now
                }

                if autoSaveDue {
                    if runLongWearSupervisorAutoSave(index: autoSaveIndex,
                                                     label: config.label,
                                                     rest: config.rest,
                                                     maxHR: config.maxHR,
                                                     analysis: sharedAnalysis) {
                        break
                    }
                    autoSaveIndex += 1
                    lastAutoSaveAt = now
                }

                // Crash fix (handoff #1): bound the live session so its four
                // parallel arrays can't grow unbounded across an all-day stream.
                // Independent of workout readiness (the autosave above only fires
                // for a detected workout, never during pure resting/overnight wear
                // — the reported crash window). Skipped under thermal suspend, which
                // already parks non-essential work; the roll resumes next tick.
                if !powerThermalGovernor.shouldSuspendNonEssentialWork {
                    rollLongWearLiveSessionIfOversized(now: now,
                                                       reason: "long_wear_retention_roll")
                }

                // Anchor the no-data gap to ANY GATT activity (battery included),
                // not just the HR stream — battery reads recur on a live link, so
                // the gap only grows when the link is genuinely silent everywhere.
                if let reference = Self.latestLinkActivity([lastRawHRNotificationAt,
                                                            lastGattActivityAt,
                                                            connectedAt]) {
                    let gap = now.timeIntervalSince(reference)
                    if gap >= config.noDataTimeout {
                        recoverNoDataWatchdog(label: config.label,
                                               status: "stale",
                                               gap: gap,
                                               timeout: config.noDataTimeout)
                    }
                }

                if let reference = Self.latestLinkActivity([lastRawHRNotificationAt,
                                                            lastAcceptedHRAt,
                                                            connectedAt]) {
                    let rawGap = now.timeIntervalSince(reference)
                    if rawGap >= config.hrContinuityTimeout,
                       lastHRContinuityActionAt.map({ now.timeIntervalSince($0) >= config.hrContinuityTimeout * cadenceMultiplier }) ?? true {
                        lastHRContinuityActionAt = now
                        performHRContinuityWatchdogAction(status: "stale",
                                                          rawGap: rawGap,
                                                          acceptedGap: lastAcceptedHRAt.map { now.timeIntervalSince($0) },
                                                          timeout: config.hrContinuityTimeout,
                                                          label: config.label)
                    }
                }

                if let reference = Self.latestLinkActivity([lastAcceptedHRAt, connectedAt]) {
                    let acceptedGap = now.timeIntervalSince(reference)
                    let rawGap = lastRawHRNotificationAt.map { now.timeIntervalSince($0) }
                    let contactStatus = ["zero_contact", "hr_zero"]
                    if acceptedGap >= config.acceptedHRTimeout {
                        if let rawGap,
                           rawGap < config.acceptedHRTimeout,
                           contactStatus.contains(sampleDiagnostics.lastStatus) || contactStatus.contains(sampleDiagnostics.lastReason) {
                            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=stale_contact accepted_gap_s=%.1f raw_gap_s=%.1f timeout_s=%.1f samples=%d action=wait_for_contact source=supervisor",
                                  acceptedGap,
                                  rawGap,
                                  config.acceptedHRTimeout,
                                  session.count)
                        } else {
                            recoverAcceptedHRWatchdog(label: config.label,
                                                      status: "stale",
                                                      acceptedGap: acceptedGap,
                                                      rawGap: rawGap,
                                                      timeout: config.acceptedHRTimeout)
                        }
                    }
                }

                guard session.count >= autoSaveMinSamples, let lastAcceptedHRAt else { continue }
                let acceptedGap = now.timeIntervalSince(lastAcceptedHRAt)
                guard acceptedGap <= max(config.baseTickInterval * cadenceMultiplier + 5, 20) else {
                    rrPresenceConsecutive = 0
                    continue
                }
                let rrReference: Date
                let recoveryStatus: String
                if rrArchive.isEmpty, let firstSample = session.first?.t {
                    rrReference = firstSample
                    recoveryStatus = "segment_hr_only"
                } else {
                    rrReference = lastStandardRRAt ?? lastRRBeatTime ?? session.first?.t ?? connectedAt ?? lastAcceptedHRAt
                    recoveryStatus = "hr_only"
                }
                let rrGap = now.timeIntervalSince(rrReference)
                guard rrGap >= config.rrPresenceTimeout else {
                    rrPresenceConsecutive = 0
                    continue
                }
                guard lastRRPresenceActionAt.map({ now.timeIntervalSince($0) >= max(60, config.rrPresenceTimeout * cadenceMultiplier) }) ?? true else {
                    continue
                }
                rrPresenceConsecutive += 1
                lastRRPresenceActionAt = now
                recoverRRPresenceWatchdog(label: config.label,
                                          status: recoveryStatus,
                                          rrGap: rrGap,
                                          acceptedGap: acceptedGap,
                                          timeout: config.rrPresenceTimeout,
                                          consecutive: rrPresenceConsecutive)
            }
        }
    }

    private func runLongWearSupervisorCheckpoint(index: Int, label: String, now: Date) {
        let minimumInterval = configuredLongWearCheckpointInterval() * effectiveThermalCadenceMultiplier
        guard Self.shouldRunCanonicalCheckpoint(now: now,
                                                lastCheckpointAt: lastCanonicalCheckpointAt,
                                                minimumInterval: minimumInterval) else {
            return
        }
        guard session.count >= autoSaveMinSamples else {
            UserDefaults.standard.set("skipped_insufficient_samples", forKey: CheckpointDefaults.lastStatus)
            UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
            UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
            UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=insufficient_samples samples=%d min_samples=%d label=%@ checkpoint_index=%d source=long_wear_supervisor",
                  session.count, autoSaveMinSamples, label, index)
            return
        }
        guard let saved = snapshotSession(label: label) else {
            UserDefaults.standard.set("skipped_snapshot_failed", forKey: CheckpointDefaults.lastStatus)
            UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
            UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
            UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=snapshot_failed samples=%d label=%@ checkpoint_index=%d source=long_wear_supervisor",
                  session.count, label, index)
            return
        }
        lastCanonicalCheckpointAt = now
        let checkpointPersisted = onSessionCheckpoint?(saved) == true
        persistActiveSessionJournalIfNeeded(reason: "session_checkpoint_supervisor", force: true)
        UserDefaults.standard.set(checkpointPersisted ? "saved" : "store_failed", forKey: CheckpointDefaults.lastStatus)
        UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
        UserDefaults.standard.set(saved.points.count, forKey: CheckpointDefaults.lastSamples)
        UserDefaults.standard.set(Int(saved.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ samples=%d rr_samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d hrv=%@ label=%@ checkpoint_index=%d mode=upsert source=long_wear_supervisor",
              checkpointPersisted ? "saved" : "store_failed",
              saved.points.count,
              saved.rrSampleCount,
              saved.duration,
              saved.avg,
              saved.peak,
              saved.hrv.map(String.init) ?? "learning",
              label,
              index)
    }

    nonisolated static func shouldRunCanonicalCheckpoint(now: Date,
                                                        lastCheckpointAt: Date?,
                                                        minimumInterval: TimeInterval) -> Bool {
        guard let lastCheckpointAt else { return true }
        return now.timeIntervalSince(lastCheckpointAt) >= minimumInterval
    }

    private func runLongWearSupervisorDiagnostic(index: Int,
                                                 label: String,
                                                 rest: Int,
                                                 maxHR: Int,
                                                 analysis: LongWearSessionAnalysis) {
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        guard session.count >= autoSaveMinSamples else {
            AtriaDebugLog("ATRIADBG live_workout status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
            return
        }
        guard let saved = analysis.snapshot,
              let readiness = analysis.readiness else {
            AtriaDebugLog("ATRIADBG live_workout status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, rest, maxHR, threshold, index, label)
            return
        }
        persistActiveSessionJournalIfNeeded(reason: "live_workout_diagnostic_supervisor", force: true)
        let capture = workoutCaptureEvidence(for: saved, readiness: readiness)
        AtriaDebugLog("ATRIADBG live_workout tick=%d status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d elevated_s=%.0f required_elevated_s=%.0f next_action=%@ ready=%d capture_diagnosis=%@ capture_action=%@ %@ label=%@ source=long_wear_supervisor",
              index,
              readiness.status,
              readiness.reason,
              readiness.primaryBlocker,
              readiness.streamCoveragePercent,
              saved.points.count,
              readiness.duration,
              readiness.avgHR,
              readiness.peakHR,
              rest,
              maxHR,
              readiness.thresholdHR,
              readiness.elevatedSeconds,
              readiness.requiredElevatedSeconds,
              readiness.nextAction,
              readiness.ready ? 1 : 0,
              capture.diagnosis,
              capture.action,
              capture.sampleFields,
              label)
    }

    private func runLongWearSupervisorAutoSave(index: Int,
                                               label: String,
                                               rest: Int,
                                               maxHR: Int,
                                               analysis: LongWearSessionAnalysis) -> Bool {
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        guard session.count >= autoSaveMinSamples else {
            AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
            return false
        }
        guard let snapshot = analysis.snapshot,
              let readiness = analysis.readiness else {
            AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, rest, maxHR, threshold, index, label)
            return false
        }
        persistActiveSessionJournalIfNeeded(reason: "workout_auto_save_check_supervisor", force: true)
        guard readiness.ready else {
            let capture = workoutCaptureEvidence(for: snapshot, readiness: readiness)
            AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=%@ primary_blocker=%@ stream_coverage_percent=%d tick=%d samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d elevated_s=%.0f required_elevated_s=%.0f next_action=%@ capture_diagnosis=%@ capture_action=%@ %@ label=%@ source=long_wear_supervisor",
                  readiness.reason,
                  readiness.primaryBlocker,
                  readiness.streamCoveragePercent,
                  index,
                  snapshot.points.count,
                  readiness.duration,
                  readiness.avgHR,
                  readiness.peakHR,
                  rest,
                  maxHR,
                  readiness.thresholdHR,
                  readiness.elevatedSeconds,
                  readiness.requiredElevatedSeconds,
                  readiness.nextAction,
                  capture.diagnosis,
                  capture.action,
                  capture.sampleFields,
                  label)
            return false
        }
        let saved = snapshot
        let persisted = persistFinishedSession(saved, reason: "workout_auto_save_supervisor")
        let savedReadiness = readiness
        persistActiveSessionJournalIfNeeded(reason: "workout_auto_save_snapshot_supervisor", force: true)
        AtriaDebugLog("ATRIADBG workout_auto_save status=%@ reason=%@ primary_blocker=%@ stream_coverage_percent=%d tick=%d samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d rest_hr=%d max_hr=%d threshold_hr=%d hrv=%@ label=%@ source=long_wear_supervisor mode=snapshot_keep_live",
              persisted ? "saved" : "store_failed",
              savedReadiness.reason,
              savedReadiness.primaryBlocker,
              savedReadiness.streamCoveragePercent,
              index,
              saved.points.count,
              saved.duration,
              saved.avg,
              saved.peak,
              rest,
              maxHR,
              savedReadiness.thresholdHR,
              saved.hrv.map(String.init) ?? "learning",
              label)
        return false
    }

    private func scheduleNoDataWatchdogIfNeeded(timeout: TimeInterval,
                                                interval: TimeInterval,
                                                label: String) {
        noDataWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG no_data_watchdog schedule timeout_s=%.1f interval_s=%.1f label=%@",
              timeout, interval, label)
        noDataWatchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard longWearModeEnabled, standardHROnlyMode else { continue }
                guard status == .connected else { continue }
                let now = Date()
                guard let reference = Self.latestLinkActivity([lastRawHRNotificationAt,
                                                               lastGattActivityAt,
                                                               connectedAt]) else { continue }
                let gap = now.timeIntervalSince(reference)
                guard gap >= timeout else { continue }

                recoverNoDataWatchdog(label: label,
                                       status: "stale",
                                       gap: gap,
                                       timeout: timeout)
            }
        }
    }

    private func scheduleDebugNoDataWatchdog(after seconds: TimeInterval) {
        debugNoDataWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG no_data_watchdog debug_force_schedule delay_s=%.1f", seconds)
        debugNoDataWatchdogTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let now = Date()
            let gap = (lastRawHRNotificationAt ?? connectedAt).map { now.timeIntervalSince($0) } ?? 0
            recoverNoDataWatchdog(label: captureLabel.isEmpty ? "All-day wear" : captureLabel,
                                   status: "forced",
                                   gap: gap,
                                   timeout: 0)
        }
    }

    private func recoverNoDataWatchdog(label: String,
                                       status recoveryStatus: String,
                                       gap: TimeInterval,
                                       timeout: TimeInterval) {
        if dutyCycleState == .sparseSentinel {
            AtriaDebugLog("ATRIADBG no_data_watchdog status=sparse_expected_silence action=suppressed_duty_cycle")
            return
        }
        if historyOnlyProbeMode {
            AtriaDebugLog("ATRIADBG no_data_watchdog status=%@ gap_s=%.1f timeout_s=%.1f samples=%d checkpoint=skipped action=suppressed_history_only_probe",
                  recoveryStatus,
                  gap,
                  timeout,
                  session.count)
            return
        }
        let snapshot: SavedSession?
        if powerThermalGovernor.shouldDeferNonEssentialAnalysis {
            snapshot = nil
            persistActiveSessionJournalIfNeeded(
                reason: "no_data_watchdog_thermal_heartbeat",
                force: true,
                refreshTimestampIfUnchanged: true
            )
            UserDefaults.standard.set("journal_only_thermal_pressure", forKey: CheckpointDefaults.lastStatus)
            AtriaDebugLog("ATRIADBG session_checkpoint status=deferred reason=no_data_watchdog_thermal_pressure samples=%d rr_samples=%d source=watchdog",
                          session.count,
                          rrArchive.count)
        } else {
            snapshot = snapshotSession(label: label)
            if let snapshot {
                let checkpointPersisted = onSessionCheckpoint?(snapshot) == true
                persistActiveSessionJournalIfNeeded(reason: "no_data_watchdog_checkpoint", force: true)
                UserDefaults.standard.set(checkpointPersisted ? "saved_no_data_watchdog" : "store_failed_no_data_watchdog", forKey: CheckpointDefaults.lastStatus)
                UserDefaults.standard.set(snapshot.points.count, forKey: CheckpointDefaults.lastSamples)
                UserDefaults.standard.set(Int(snapshot.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
                AtriaDebugLog("ATRIADBG session_checkpoint status=%@ reason=no_data_watchdog samples=%d rr_samples=%d duration_s=%.0f label=%@ source=watchdog",
                      checkpointPersisted ? "saved" : "store_failed",
                      snapshot.points.count,
                      snapshot.rrSampleCount,
                      snapshot.duration,
                      snapshot.label)
            } else {
                clearUnsavableActiveJournalIfNeeded(reason: "no_data_watchdog_unsavable")
            }
        }
        preserveLongWearRangeLossRecovery(reason: "no_data_watchdog")
        guard let peripheral else { return }
        guard beginStalledStreamRepair(source: "no_data") else {
            persistWatchdogRecovery(source: "no_data",
                                    status: recoveryStatus,
                                    action: "repair_cooldown",
                                    rawGap: gap,
                                    acceptedGap: nil,
                                    samples: session.count,
                                    checkpoint: snapshot == nil ? "skipped" : "saved")
            return
        }
        persistWatchdogRecovery(source: "no_data",
                                status: recoveryStatus,
                                action: "fresh_scan_reconnect",
                                rawGap: gap,
                                acceptedGap: nil,
                                samples: session.count,
                                checkpoint: snapshot == nil ? "skipped" : "saved")
        AtriaDebugLog("ATRIADBG no_data_watchdog status=%@ gap_s=%.1f timeout_s=%.1f samples=%d checkpoint=%@ action=fresh_scan_reconnect",
              recoveryStatus,
              gap,
              timeout,
              session.count,
              snapshot == nil ? "skipped" : "saved")
        // Never tear down a still-connected link. A no-data gap while the
        // peripheral is CB-connected is recovered by re-subscribing / re-
        // discovering — mirror the accepted_hr/hr_continuity escape hatch. iOS's
        // own connection supervision (didDisconnectPeripheral) is the only thing
        // that should declare a real drop; the watchdog must not cancel a live
        // peripheral or show "Disconnected" while it is connected.
        if peripheral.state == .connected {
            if status != .connected { recomputeConnectionStatus(reason: "event") }
            if let ch = heartRateCharacteristic,
               ch.properties.contains(.notify),
               !ch.isNotifying {
                peripheral.setNotifyValue(true, for: ch)
            } else {
                peripheral.discoverServices(discoveryServicesForCurrentMode)
            }
            persistWatchdogRecovery(source: "no_data",
                                    status: recoveryStatus,
                                    action: "reassert_keep_connection",
                                    rawGap: gap,
                                    acceptedGap: nil,
                                    samples: session.count,
                                    checkpoint: "skipped")
            AtriaDebugLog("ATRIADBG no_data_watchdog status=%@ gap_s=%.1f action=reassert_keep_connection samples=%d",
                  recoveryStatus, gap, session.count)
            return
        }
        requestFreshScanReconnect(peripheral: peripheral, reason: "no_data_watchdog")
    }

    private func scheduleHRContinuityWatchdogIfNeeded(timeout: TimeInterval,
                                                      interval: TimeInterval,
                                                      label: String) {
        hrContinuityWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG hr_continuity_watchdog schedule timeout_s=%.1f interval_s=%.1f label=%@ source=2A37 action=read_or_reassert_notify",
              timeout, interval, label)
        hrContinuityWatchdogTask = Task { @MainActor in
            var lastNudgeAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard longWearModeEnabled, standardHROnlyMode else { continue }
                guard status == .connected else { continue }
                let now = Date()
                guard let reference = Self.latestLinkActivity([lastRawHRNotificationAt,
                                                               lastAcceptedHRAt,
                                                               connectedAt]) else { continue }
                let rawGap = now.timeIntervalSince(reference)
                guard rawGap >= timeout else { continue }
                if let lastNudgeAt, now.timeIntervalSince(lastNudgeAt) < timeout {
                    continue
                }
                lastNudgeAt = now

                performHRContinuityWatchdogAction(status: "stale",
                                                  rawGap: rawGap,
                                                  acceptedGap: lastAcceptedHRAt.map { now.timeIntervalSince($0) },
                                                  timeout: timeout,
                                                  label: label)
            }
        }
    }

    private func scheduleDebugHRContinuityWatchdog(after seconds: TimeInterval) {
        debugHRContinuityWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG hr_continuity_watchdog debug_force_schedule delay_s=%.1f", seconds)
        debugHRContinuityWatchdogTask = Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            let now = Date()
            let rawGap = (lastRawHRNotificationAt ?? connectedAt).map { now.timeIntervalSince($0) } ?? 0
            let acceptedGap = lastAcceptedHRAt.map { now.timeIntervalSince($0) }
            performHRContinuityWatchdogAction(status: "forced",
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: 0,
                                              label: captureLabel.isEmpty ? "All-day wear" : captureLabel)
        }
    }

    private func scheduleDebugMissingHeartRateCharacteristic(after seconds: TimeInterval) {
        guard !debugMissingHeartRateCharacteristicFired else { return }
        debugMissingHeartRateCharacteristicFired = true
        debugMissingHeartRateCharacteristicTask?.cancel()
        AtriaDebugLog("ATRIADBG missing_2a37_debug schedule delay_s=%.1f", seconds)
        debugMissingHeartRateCharacteristicTask = Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            let hadCharacteristic = heartRateCharacteristic != nil
            heartRateCharacteristic = nil
            let now = Date()
            let rawGap = (lastRawHRNotificationAt ?? connectedAt).map { now.timeIntervalSince($0) } ?? 0
            let acceptedGap = lastAcceptedHRAt.map { now.timeIntervalSince($0) }
            AtriaDebugLog("ATRIADBG missing_2a37_debug status=forced had_characteristic=%d peripheral_state=%@ raw_gap_s=%.1f accepted_gap_s=%@",
                  hadCharacteristic ? 1 : 0,
                  peripheral.map { String(describing: $0.state.rawValue) } ?? "missing",
                  rawGap,
                  acceptedGap.map { String(format: "%.1f", $0) } ?? "missing")
            performHRContinuityWatchdogAction(status: "forced_missing_2a37",
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: 12,
                                              label: captureLabel.isEmpty ? "All-day wear" : captureLabel)
        }
    }

    private func armDebugMissingHeartRateCharacteristic(after seconds: TimeInterval) {
        debugMissingHeartRateCharacteristicAfterDiscovery = seconds
        AtriaDebugLog("ATRIADBG missing_2a37_debug armed delay_after_discovery_s=%.1f", seconds)
        if heartRateCharacteristic != nil {
            scheduleDebugMissingHeartRateCharacteristic(after: min(seconds, 3))
        }
    }

    private func scheduleDebugMissingHeartRateCharacteristicAfterDiscoveryIfNeeded() {
        guard let seconds = debugMissingHeartRateCharacteristicAfterDiscovery,
              !debugMissingHeartRateCharacteristicFired else { return }
        scheduleDebugMissingHeartRateCharacteristic(after: min(seconds, 3))
    }

    private func scheduleDebugRRPresenceWatchdog(after seconds: TimeInterval) {
        debugRRPresenceWatchdogTask?.cancel()
        debugRRPresenceWatchdogDueAt = Date().addingTimeInterval(max(0, seconds))
        debugRRPresenceWatchdogFired = false
        AtriaDebugLog("ATRIADBG rr_presence_watchdog debug_force_schedule delay_s=%.1f", seconds)
        let canRunImmediately = peripheral != nil
            || heartRateCharacteristic != nil
            || connectedAt != nil
        if canRunImmediately {
            debugRRPresenceWatchdogDueAt = Date()
            fireDebugRRPresenceWatchdogIfDue(now: Date(), source: "schedule_preflight")
            return
        }
        debugRRPresenceWatchdogTask = Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            self.fireDebugRRPresenceWatchdogIfDue(now: Date(), source: "timer")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            Task { @MainActor [weak self] in
                self?.fireDebugRRPresenceWatchdogIfDue(now: Date(), source: "dispatch_timer")
            }
        }
    }

    private func fireDebugRRPresenceWatchdogIfDue(now: Date, source: String) {
        guard let dueAt = debugRRPresenceWatchdogDueAt,
              !debugRRPresenceWatchdogFired,
              now >= dueAt else { return }
        debugRRPresenceWatchdogFired = true
        debugRRPresenceWatchdogDueAt = nil
        debugRRPresenceWatchdogTask?.cancel()
        debugRRPresenceWatchdogTask = nil
        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        let canUseBLEState = peripheral != nil
            || heartRateCharacteristic != nil
            || connectedAt != nil
        guard canUseBLEState else {
            AtriaDebugLog("ATRIADBG rr_presence_watchdog debug_force_execute status=skipped reason=missing_ble_state source=%@", source)
            logRRWatchdogRecovery(status: "debug_force_missing_ble_state",
                                  action: "wait_missing_ble_state",
                                  rrGap: 30,
                                  acceptedGap: 0,
                                  timeout: 30,
                                  consecutive: 0,
                                  label: label,
                                  notifying: nil)
            return
        }
        let acceptedGap = lastAcceptedHRAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
        AtriaDebugLog("ATRIADBG rr_presence_watchdog debug_force_execute status=running source=%@ connected=%d peripheral=%d heart_rate_char=%d",
                      source,
                      status == .connected ? 1 : 0,
                      peripheral == nil ? 0 : 1,
                      heartRateCharacteristic == nil ? 0 : 1)
        recoverRRPresenceWatchdog(label: label,
                                  status: "segment_hr_only",
                                  rrGap: 30,
                                  acceptedGap: acceptedGap,
                                  timeout: 30,
                                  consecutive: 1)
    }

    private func performHRContinuityWatchdogAction(status actionStatus: String,
                                                   rawGap: TimeInterval,
                                                   acceptedGap: TimeInterval?,
                                                   timeout: TimeInterval,
                                                   label: String) {
        if dutyCycleState == .sparseSentinel {
            AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=sparse_expected_silence action=suppressed_duty_cycle")
            return
        }
        if historyOnlyProbeMode {
            persistHRContinuityWatchdogResult(status: actionStatus,
                                              action: "suppressed_history_only_probe",
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: timeout,
                                              samples: session.count,
                                              label: label,
                                              notifying: heartRateCharacteristic?.isNotifying)
            AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=%@ raw_gap_s=%.1f accepted_gap_s=%@ timeout_s=%.1f samples=%d action=suppressed_history_only_probe notifying=%@ label=%@",
                  actionStatus,
                  rawGap,
                  acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  heartRateCharacteristic.map { $0.isNotifying ? "1" : "0" } ?? "missing",
                  label)
            return
        }
        guard let peripheral else {
            persistHRContinuityWatchdogResult(status: actionStatus,
                                              action: "wait_missing_peripheral",
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: timeout,
                                              samples: session.count,
                                              label: label,
                                              notifying: nil)
            AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=%@ raw_gap_s=%.1f accepted_gap_s=%@ timeout_s=%.1f samples=%d action=wait_missing_peripheral label=%@",
                  actionStatus,
                  rawGap,
                  acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  label)
            return
        }
        guard beginStalledStreamRepair(source: "hr_continuity") else {
            persistHRContinuityWatchdogResult(status: actionStatus,
                                              action: "repair_cooldown",
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: timeout,
                                              samples: session.count,
                                              label: label,
                                              notifying: heartRateCharacteristic?.isNotifying)
            persistWatchdogRecovery(source: "hr_continuity",
                                    status: actionStatus,
                                    action: "repair_cooldown",
                                    rawGap: rawGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: "not_applicable")
            return
        }
        guard let characteristic = heartRateCharacteristic else {
            let action: String
            let now = Date()
            if timeout > 0,
               let lastMissingHeartRateDiscoveryAt,
               now.timeIntervalSince(lastMissingHeartRateDiscoveryAt) >= timeout,
               rawGap >= max(timeout * 2, timeout + 6) {
                persistActiveSessionJournalIfNeeded(reason: "hr_continuity_missing_2a37_reconnect", force: true)
                persistWatchdogRecovery(source: "hr_continuity",
                                        status: actionStatus,
                                        action: "fresh_scan_missing_2a37",
                                        rawGap: rawGap,
                                        acceptedGap: acceptedGap,
                                        samples: session.count,
                                        checkpoint: "journal_saved")
                requestFreshScanReconnect(peripheral: peripheral, reason: "missing_2a37_characteristic")
                action = "fresh_scan_missing_2a37"
            } else if peripheral.state == .connected {
                lastMissingHeartRateDiscoveryAt = now
                peripheral.discoverServices([UUIDs.heartRateService])
                action = "rediscover_2a37_service"
            } else {
                action = "wait_missing_2a37_char"
            }
            persistHRContinuityWatchdogResult(status: actionStatus,
                                              action: action,
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: timeout,
                                              samples: session.count,
                                              label: label,
                                              notifying: nil)
            AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=%@ raw_gap_s=%.1f accepted_gap_s=%@ timeout_s=%.1f samples=%d action=%@ label=%@",
                  actionStatus,
                  rawGap,
                  acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  action,
                  label)
            return
        }

        // Only tear down the BLE link as a last resort. While the peripheral is
        // still connected, a silent 2A37 gap is almost always brief skin-contact
        // loss or radio latency — re-subscribing recovers it without the
        // expensive scan/connect/rediscover cycle that, in the background, iOS
        // throttles heavily (causing long collection gaps) and that churns the
        // connection state in the foreground (causing UI lag). Reserve the
        // fresh-scan teardown for a genuinely dead link or an extreme gap; real
        // disconnects are already handled by didDisconnectPeripheral.
        let linkConnected = peripheral.state == .connected
        let teardownGap = linkConnected ? max(timeout * 4, 60) : max(timeout * 2, timeout + 6)
        if timeout > 0, rawGap >= teardownGap {
            persistActiveSessionJournalIfNeeded(reason: "hr_continuity_watchdog_reconnect", force: true)
            if session.count < 2 {
                clearUnsavableActiveJournalIfNeeded(reason: "hr_continuity_watchdog_unsavable")
            }
            let action = "fresh_scan_reconnect"
            persistHRContinuityWatchdogResult(status: actionStatus,
                                              action: action,
                                              rawGap: rawGap,
                                              acceptedGap: acceptedGap,
                                              timeout: timeout,
                                              samples: session.count,
                                              label: label,
                                              notifying: characteristic.isNotifying)
            persistWatchdogRecovery(source: "hr_continuity",
                                    status: actionStatus,
                                    action: action,
                                    rawGap: rawGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: "journal_saved")
            AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=%@ raw_gap_s=%.1f accepted_gap_s=%@ timeout_s=%.1f samples=%d action=%@ notifying=%d label=%@",
                  actionStatus,
                  rawGap,
                  acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  action,
                  characteristic.isNotifying ? 1 : 0,
                  label)
            requestFreshScanReconnect(peripheral: peripheral, reason: "hr_continuity_watchdog")
            return
        }

        let canNotify = characteristic.properties.contains(.notify)
        let canRead = characteristic.properties.contains(.read)
        if canNotify {
            resetHeartRateNotifyIfNeeded(peripheral: peripheral,
                                         characteristic: characteristic,
                                         reason: "hr_continuity_watchdog")
        }
        if canRead {
            peripheral.readValue(for: characteristic)
        }
        let action: String
        if canRead {
            action = "read_reassert_notify"
        } else if canNotify {
            action = "reassert_notify"
        } else {
            action = "no_supported_operation"
        }
        persistHRContinuityWatchdogResult(status: actionStatus,
                                          action: action,
                                          rawGap: rawGap,
                                          acceptedGap: acceptedGap,
                                          timeout: timeout,
                                          samples: session.count,
                                          label: label,
                                          notifying: characteristic.isNotifying)
        persistWatchdogRecovery(source: "hr_continuity",
                                status: actionStatus,
                                action: action,
                                rawGap: rawGap,
                                acceptedGap: acceptedGap,
                                samples: session.count,
                                checkpoint: "not_applicable")
        AtriaDebugLog("ATRIADBG hr_continuity_watchdog status=%@ raw_gap_s=%.1f accepted_gap_s=%@ timeout_s=%.1f samples=%d action=%@ notifying=%d label=%@",
              actionStatus,
              rawGap,
              acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
              timeout,
              session.count,
              action,
              characteristic.isNotifying ? 1 : 0,
              label)
    }

    private func persistHRContinuityWatchdogResult(status: String,
                                                   action: String,
                                                   rawGap: TimeInterval,
                                                   acceptedGap: TimeInterval?,
                                                   timeout: TimeInterval,
                                                   samples: Int,
                                                   label: String,
                                                   notifying: Bool?) {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: HRContinuityDefaults.status)
        defaults.set(action, forKey: HRContinuityDefaults.action)
        defaults.set(rawGap, forKey: HRContinuityDefaults.rawGap)
        if let acceptedGap {
            defaults.set(acceptedGap, forKey: HRContinuityDefaults.acceptedGap)
        } else {
            defaults.removeObject(forKey: HRContinuityDefaults.acceptedGap)
        }
        defaults.set(timeout, forKey: HRContinuityDefaults.timeout)
        defaults.set(samples, forKey: HRContinuityDefaults.samples)
        defaults.set(label, forKey: HRContinuityDefaults.label)
        if let notifying {
            defaults.set(notifying, forKey: HRContinuityDefaults.notifying)
        } else {
            defaults.removeObject(forKey: HRContinuityDefaults.notifying)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: HRContinuityDefaults.at)
    }

    private func logHRContinuityWatchdogState(reason: String) {
        let defaults = UserDefaults.standard
        let status = defaults.string(forKey: HRContinuityDefaults.status) ?? "missing"
        let action = defaults.string(forKey: HRContinuityDefaults.action) ?? "missing"
        let rawGap = defaults.object(forKey: HRContinuityDefaults.rawGap) as? Double
        let acceptedGap = defaults.object(forKey: HRContinuityDefaults.acceptedGap) as? Double
        let timeout = defaults.object(forKey: HRContinuityDefaults.timeout) as? Double
        let samples = defaults.object(forKey: HRContinuityDefaults.samples) as? Int ?? 0
        let label = defaults.string(forKey: HRContinuityDefaults.label) ?? "missing"
        let notifying = defaults.object(forKey: HRContinuityDefaults.notifying) as? Bool
        let at = defaults.object(forKey: HRContinuityDefaults.at) as? Double
        let age = at.map { Date().timeIntervalSince1970 - $0 }
        AtriaDebugLog("ATRIADBG hr_continuity_watchdog persisted=1 reason=%@ status=%@ raw_gap_s=%@ accepted_gap_s=%@ timeout_s=%@ samples=%d action=%@ notifying=%@ age_s=%@ label=%@",
              reason,
              status,
              rawGap.map { String(format: "%.1f", $0) } ?? "missing",
              acceptedGap.map { String(format: "%.1f", $0) } ?? "missing",
              timeout.map { String(format: "%.1f", $0) } ?? "missing",
              samples,
              action,
              notifying.map { $0 ? "1" : "0" } ?? "missing",
              age.map { String(format: "%.1f", $0) } ?? "missing",
              label)
    }

    private func scheduleRRPresenceWatchdogIfNeeded(timeout: TimeInterval,
                                                    interval: TimeInterval,
                                                    label: String) {
        rrPresenceWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG rr_presence_watchdog schedule timeout_s=%.1f interval_s=%.1f label=%@ source=2A37 action=hold_hr_connection_reassert_2a37 hrv_policy=learning_only",
              timeout, interval, label)
        rrPresenceWatchdogTask = Task { @MainActor in
            var consecutive = 0
            var lastActionAt: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard longWearModeEnabled, standardHROnlyMode else { continue }
                guard status == .connected else { continue }
                guard session.count >= autoSaveMinSamples else { continue }
                let now = Date()
                guard let lastAcceptedHRAt else { continue }
                let acceptedGap = now.timeIntervalSince(lastAcceptedHRAt)
                guard acceptedGap <= max(interval + 5, 20) else {
                    consecutive = 0
                    continue
                }
                let rrReference: Date
                let recoveryStatus: String
                if rrArchive.isEmpty, let firstSample = session.first?.t {
                    rrReference = firstSample
                    recoveryStatus = "segment_hr_only"
                } else {
                    rrReference = lastStandardRRAt ?? lastRRBeatTime ?? session.first?.t ?? connectedAt ?? lastAcceptedHRAt
                    recoveryStatus = "hr_only"
                }
                let rrGap = now.timeIntervalSince(rrReference)
                guard rrGap >= timeout else {
                    consecutive = 0
                    continue
                }
                if let lastActionAt, now.timeIntervalSince(lastActionAt) < max(60, timeout) {
                    continue
                }
                consecutive += 1
                lastActionAt = now
                recoverRRPresenceWatchdog(label: label,
                                          status: recoveryStatus,
                                          rrGap: rrGap,
                                          acceptedGap: acceptedGap,
                                          timeout: timeout,
                                          consecutive: consecutive)
            }
        }
    }

    private func recoverRRPresenceWatchdog(label: String,
                                           status recoveryStatus: String,
                                           rrGap: TimeInterval,
                                           acceptedGap: TimeInterval,
                                           timeout: TimeInterval,
                                           consecutive: Int) {
        if dutyCycleState == .sparseSentinel {
            AtriaDebugLog("ATRIADBG rr_presence_watchdog status=sparse_expected_silence action=suppressed_duty_cycle")
            return
        }
        if historyOnlyProbeMode {
            persistRRPresenceWatchdogResult(status: recoveryStatus,
                                            action: "suppressed_history_only_probe",
                                            rrGap: rrGap,
                                            acceptedGap: acceptedGap,
                                            timeout: timeout,
                                            samples: session.count,
                                            rrValues: rrArchive.count,
                                            consecutive: consecutive,
                                            label: label)
            AtriaDebugLog("ATRIADBG rr_presence_watchdog status=%@ rr_gap_s=%.1f accepted_gap_s=%.1f timeout_s=%.1f samples=%d rr_values=%d consecutive=%d action=suppressed_history_only_probe hrv_policy=learning_only label=%@",
                  recoveryStatus,
                  rrGap,
                  acceptedGap,
                  timeout,
                  session.count,
                  rrArchive.count,
                  consecutive,
                  label)
            return
        }
        persistActiveSessionJournalIfNeeded(reason: "rr_presence_watchdog_checkpoint", force: true)
        let action: String
        guard let peripheral, let characteristic = heartRateCharacteristic else {
            if let peripheral, peripheral.state == .connected {
                lastMissingHeartRateDiscoveryAt = Date()
                peripheral.discoverServices([UUIDs.heartRateService])
                action = "rediscover_2a37_service"
            } else {
                action = "wait_missing_2a37"
            }
            persistRRPresenceWatchdogResult(status: recoveryStatus,
                                            action: action,
                                            rrGap: rrGap,
                                            acceptedGap: acceptedGap,
                                            timeout: timeout,
                                            samples: session.count,
                                            rrValues: rrArchive.count,
                                            consecutive: consecutive,
                                            label: label)
            persistWatchdogRecovery(source: "rr_presence",
                                    status: recoveryStatus,
                                    action: action,
                                    rawGap: rrGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: "journal_saved")
            logRRWatchdogRecovery(status: recoveryStatus,
                                  action: action,
                                  rrGap: rrGap,
                                  acceptedGap: acceptedGap,
                                  timeout: timeout,
                                  consecutive: consecutive,
                                  label: label,
                                  notifying: nil)
            AtriaDebugLog("ATRIADBG rr_presence_watchdog status=%@ rr_gap_s=%.1f accepted_gap_s=%.1f timeout_s=%.1f samples=%d rr_values=%d consecutive=%d action=%@ hrv_policy=learning_only label=%@",
                  recoveryStatus,
                  rrGap,
                  acceptedGap,
                  timeout,
                  session.count,
                  rrArchive.count,
                  consecutive,
                  action,
                  label)
            return
        }

        let canNotify = characteristic.properties.contains(.notify)
        let canRead = characteristic.properties.contains(.read)
        if canNotify && !characteristic.isNotifying {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if canRead {
            peripheral.readValue(for: characteristic)
        }
        if canRead {
            action = "read_reassert_notify"
        } else if canNotify {
            action = "reassert_notify"
        } else {
            action = "no_supported_operation"
        }
        persistRRPresenceWatchdogResult(status: recoveryStatus,
                                        action: action,
                                        rrGap: rrGap,
                                        acceptedGap: acceptedGap,
                                        timeout: timeout,
                                        samples: session.count,
                                        rrValues: rrArchive.count,
                                        consecutive: consecutive,
                                        label: label)
        persistWatchdogRecovery(source: "rr_presence",
                                status: recoveryStatus,
                                action: action,
                                rawGap: rrGap,
                                acceptedGap: acceptedGap,
                                samples: session.count,
                                checkpoint: "journal_saved")
        logRRWatchdogRecovery(status: recoveryStatus,
                              action: action,
                              rrGap: rrGap,
                              acceptedGap: acceptedGap,
                              timeout: timeout,
                              consecutive: consecutive,
                              label: label,
                              notifying: characteristic.isNotifying)
        AtriaDebugLog("ATRIADBG rr_presence_watchdog status=%@ rr_gap_s=%.1f accepted_gap_s=%.1f timeout_s=%.1f samples=%d rr_values=%d consecutive=%d action=%@ notifying=%d hrv_policy=learning_only label=%@",
              recoveryStatus,
              rrGap,
              acceptedGap,
              timeout,
              session.count,
              rrArchive.count,
              consecutive,
              action,
              characteristic.isNotifying ? 1 : 0,
              label)
    }

    private func logRRWatchdogRecovery(status: String,
                                       action: String,
                                       rrGap: TimeInterval,
                                       acceptedGap: TimeInterval,
                                       timeout: TimeInterval,
                                       consecutive: Int,
                                       label: String,
                                       notifying: Bool?) {
        let rearmed: Set<String> = ["rediscover_2a37_service", "read_reassert_notify", "reassert_notify"]
        let watchdogStatus = rearmed.contains(action) ? "rearmed" : status
        AtriaDebugLog("ATRIADBG rr_watchdog status=%@ rr_gap_s=%.1f gap_s=%.1f accepted_gap_s=%.1f timeout_s=%.1f samples=%d rr_values=%d consecutive=%d action=%@ notifying=%@ label=%@",
              watchdogStatus,
              rrGap,
              rrGap,
              acceptedGap,
              timeout,
              session.count,
              rrArchive.count,
              consecutive,
              action,
              notifying.map { $0 ? "1" : "0" } ?? "missing",
              label)
    }

    private func persistRRPresenceWatchdogResult(status: String,
                                                 action: String,
                                                 rrGap: TimeInterval,
                                                 acceptedGap: TimeInterval,
                                                 timeout: TimeInterval,
                                                 samples: Int,
                                                 rrValues: Int,
                                                 consecutive: Int,
                                                 label: String) {
        let defaults = UserDefaults.standard
        defaults.set(status, forKey: RRPresenceDefaults.status)
        defaults.set(action, forKey: RRPresenceDefaults.action)
        defaults.set(rrGap, forKey: RRPresenceDefaults.rrGap)
        defaults.set(acceptedGap, forKey: RRPresenceDefaults.acceptedGap)
        defaults.set(timeout, forKey: RRPresenceDefaults.timeout)
        defaults.set(samples, forKey: RRPresenceDefaults.samples)
        defaults.set(rrValues, forKey: RRPresenceDefaults.rrValues)
        defaults.set(consecutive, forKey: RRPresenceDefaults.consecutive)
        defaults.set(label, forKey: RRPresenceDefaults.label)
        defaults.set(Date().timeIntervalSince1970, forKey: RRPresenceDefaults.at)
    }

    private func refreshRRPresenceOnRealInterval(at now: Date,
                                                 source: String,
                                                 rrGap: TimeInterval) {
        let refreshInterval: TimeInterval = 5
        if let lastRRPresenceRefreshAt,
           now.timeIntervalSince(lastRRPresenceRefreshAt) < refreshInterval {
            return
        }
        lastRRPresenceRefreshAt = now
        let acceptedGap = lastAcceptedHRAt.map { max(0, now.timeIntervalSince($0)) } ?? -1
        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        persistRRPresenceWatchdogResult(status: "rr_present",
                                        action: "observe_real_rr_\(source)",
                                        rrGap: max(0, rrGap),
                                        acceptedGap: acceptedGap,
                                        timeout: 0,
                                        samples: session.count,
                                        rrValues: rrArchive.count,
                                        consecutive: 0,
                                        label: label)
    }

    private func scheduleAcceptedHRWatchdogIfNeeded(timeout: TimeInterval,
                                                    interval: TimeInterval,
                                                    label: String) {
        acceptedHRWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG accepted_hr_watchdog schedule timeout_s=%.1f interval_s=%.1f label=%@",
              timeout, interval, label)
        acceptedHRWatchdogTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard longWearModeEnabled, standardHROnlyMode else { continue }
                guard status == .connected else { continue }
                let now = Date()
                guard let reference = Self.latestLinkActivity([lastAcceptedHRAt, connectedAt]) else { continue }
                let acceptedGap = now.timeIntervalSince(reference)
                guard acceptedGap >= timeout else { continue }

                let lastSampleStatus = sampleDiagnostics.lastStatus
                let lastSampleReason = sampleDiagnostics.lastReason
                let rawGap = lastRawHRNotificationAt.map { now.timeIntervalSince($0) }
                if let rawGap,
                   rawGap < timeout,
                   ["zero_contact", "hr_zero"].contains(lastSampleStatus)
                    || ["zero_contact", "hr_zero"].contains(lastSampleReason) {
                    AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=stale_contact accepted_gap_s=%.1f raw_gap_s=%.1f timeout_s=%.1f samples=%d action=wait_for_contact",
                          acceptedGap,
                          rawGap,
                          timeout,
                          session.count)
                    continue
                }

                recoverAcceptedHRWatchdog(label: label,
                                          status: "stale",
                                          acceptedGap: acceptedGap,
                                          rawGap: rawGap,
                                          timeout: timeout)
            }
        }
    }

    private func scheduleDebugAcceptedHRWatchdog(after seconds: TimeInterval) {
        debugAcceptedHRWatchdogTask?.cancel()
        AtriaDebugLog("ATRIADBG accepted_hr_watchdog debug_force_schedule delay_s=%.1f", seconds)
        debugAcceptedHRWatchdogTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            let now = Date()
            let acceptedGap = (lastAcceptedHRAt ?? connectedAt).map { now.timeIntervalSince($0) } ?? 0
            let rawGap = lastRawHRNotificationAt.map { now.timeIntervalSince($0) }
            recoverAcceptedHRWatchdog(label: captureLabel.isEmpty ? "All-day wear" : captureLabel,
                                      status: "forced",
                                      acceptedGap: acceptedGap,
                                      rawGap: rawGap,
                                      timeout: 0)
        }
    }

    private func recoverAcceptedHRWatchdog(label: String,
                                           status recoveryStatus: String,
                                           acceptedGap: TimeInterval,
                                           rawGap: TimeInterval?,
                                           timeout: TimeInterval) {
        if dutyCycleState == .sparseSentinel {
            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=sparse_expected_silence action=suppressed_duty_cycle")
            return
        }
        if historyOnlyProbeMode {
            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=%@ accepted_gap_s=%.1f raw_gap_s=%@ timeout_s=%.1f samples=%d checkpoint=skipped action=suppressed_history_only_probe",
                  recoveryStatus,
                  acceptedGap,
                  rawGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count)
            return
        }
        let snapshot: SavedSession?
        if powerThermalGovernor.shouldDeferNonEssentialAnalysis {
            snapshot = nil
            persistActiveSessionJournalIfNeeded(
                reason: "accepted_hr_watchdog_thermal_heartbeat",
                force: true,
                refreshTimestampIfUnchanged: true
            )
            UserDefaults.standard.set("journal_only_thermal_pressure", forKey: CheckpointDefaults.lastStatus)
            AtriaDebugLog("ATRIADBG session_checkpoint status=deferred reason=accepted_hr_watchdog_thermal_pressure samples=%d rr_samples=%d source=watchdog",
                          session.count,
                          rrArchive.count)
        } else {
            snapshot = snapshotSession(label: label)
            if let snapshot {
                let checkpointPersisted = onSessionCheckpoint?(snapshot) == true
                persistActiveSessionJournalIfNeeded(reason: "accepted_hr_watchdog_checkpoint", force: true)
                UserDefaults.standard.set(checkpointPersisted ? "saved_accepted_hr_watchdog" : "store_failed_accepted_hr_watchdog", forKey: CheckpointDefaults.lastStatus)
                UserDefaults.standard.set(snapshot.points.count, forKey: CheckpointDefaults.lastSamples)
                UserDefaults.standard.set(Int(snapshot.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
                AtriaDebugLog("ATRIADBG session_checkpoint status=%@ reason=accepted_hr_watchdog samples=%d rr_samples=%d duration_s=%.0f label=%@ source=watchdog",
                      checkpointPersisted ? "saved" : "store_failed",
                      snapshot.points.count,
                      snapshot.rrSampleCount,
                      snapshot.duration,
                      snapshot.label)
            } else {
                clearUnsavableActiveJournalIfNeeded(reason: "accepted_hr_watchdog_unsavable")
            }
        }
        guard let peripheral else {
            persistWatchdogRecovery(source: "accepted_hr",
                                    status: recoveryStatus,
                                    action: "wait_missing_peripheral",
                                    rawGap: rawGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: snapshot == nil ? "skipped" : "saved")
            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=%@ accepted_gap_s=%.1f raw_gap_s=%@ timeout_s=%.1f samples=%d checkpoint=%@ action=wait_missing_peripheral",
                  recoveryStatus,
                  acceptedGap,
                  rawGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  snapshot == nil ? "skipped" : "saved")
            return
        }
        guard beginStalledStreamRepair(source: "accepted_hr") else {
            persistWatchdogRecovery(source: "accepted_hr",
                                    status: recoveryStatus,
                                    action: "repair_cooldown",
                                    rawGap: rawGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: snapshot == nil ? "skipped" : "saved")
            return
        }

        // Keep a live link alive. If the strap is still connected and raw 2A37
        // packets are recent, stale *accepted* HR is a data-quality issue (poor
        // contact / artifact rejection) that a full reconnect cannot fix any
        // faster than re-subscribing — and the teardown churns the link and
        // drops collection. Reserve the fresh-scan teardown for a dead link or
        // an extreme gap.
        let linkConnected = peripheral.state == .connected
        let rawRecent = (rawGap ?? .greatestFiniteMagnitude) < max(timeout * 4, 90)
        if linkConnected, rawRecent {
            if let characteristic = heartRateCharacteristic,
               characteristic.properties.contains(.notify),
               !characteristic.isNotifying {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            persistWatchdogRecovery(source: "accepted_hr",
                                    status: recoveryStatus,
                                    action: "reassert_keep_connection",
                                    rawGap: rawGap,
                                    acceptedGap: acceptedGap,
                                    samples: session.count,
                                    checkpoint: snapshot == nil ? "skipped" : "saved")
            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=%@ accepted_gap_s=%.1f raw_gap_s=%@ timeout_s=%.1f samples=%d checkpoint=%@ action=reassert_keep_connection",
                  recoveryStatus,
                  acceptedGap,
                  rawGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count,
                  snapshot == nil ? "skipped" : "saved")
            return
        }

        persistWatchdogRecovery(source: "accepted_hr",
                                status: recoveryStatus,
                                action: "fresh_scan_reconnect",
                                rawGap: rawGap,
                                acceptedGap: acceptedGap,
                                samples: session.count,
                                checkpoint: snapshot == nil ? "skipped" : "saved")
        AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=%@ accepted_gap_s=%.1f raw_gap_s=%@ timeout_s=%.1f samples=%d checkpoint=%@ action=fresh_scan_reconnect",
              recoveryStatus,
              acceptedGap,
              rawGap.map { String(format: "%.1f", $0) } ?? "missing",
              timeout,
              session.count,
              snapshot == nil ? "skipped" : "saved")
        preserveLongWearRangeLossRecovery(reason: "accepted_hr_watchdog")
        requestFreshScanReconnect(peripheral: peripheral, reason: "accepted_hr_watchdog")
    }

    private func persistWatchdogRecovery(source: String,
                                         status: String,
                                         action: String,
                                         rawGap: TimeInterval?,
                                         acceptedGap: TimeInterval?,
                                         samples: Int,
                                         checkpoint: String) {
        let defaults = UserDefaults.standard
        switch source {
        case "no_data":
            defaults.set(defaults.integer(forKey: WatchdogRecoveryDefaults.noDataCount) + 1,
                         forKey: WatchdogRecoveryDefaults.noDataCount)
        case "hr_continuity":
            defaults.set(defaults.integer(forKey: WatchdogRecoveryDefaults.hrContinuityCount) + 1,
                         forKey: WatchdogRecoveryDefaults.hrContinuityCount)
        case "accepted_hr":
            defaults.set(defaults.integer(forKey: WatchdogRecoveryDefaults.acceptedHRCount) + 1,
                         forKey: WatchdogRecoveryDefaults.acceptedHRCount)
        case "rr_presence":
            defaults.set(defaults.integer(forKey: WatchdogRecoveryDefaults.rrPresenceCount) + 1,
                         forKey: WatchdogRecoveryDefaults.rrPresenceCount)
        default:
            break
        }
        defaults.set(status, forKey: WatchdogRecoveryDefaults.lastStatus)
        defaults.set(source, forKey: WatchdogRecoveryDefaults.lastSource)
        defaults.set(action, forKey: WatchdogRecoveryDefaults.lastAction)
        defaults.set(rawGap ?? -1, forKey: WatchdogRecoveryDefaults.lastRawGap)
        defaults.set(acceptedGap ?? -1, forKey: WatchdogRecoveryDefaults.lastAcceptedGap)
        defaults.set(samples, forKey: WatchdogRecoveryDefaults.lastSamples)
        defaults.set(checkpoint, forKey: WatchdogRecoveryDefaults.lastCheckpoint)
        defaults.set(Date().timeIntervalSince1970, forKey: WatchdogRecoveryDefaults.lastAt)
    }

    private func configureMorningHRVCapture(arguments: [String]) {
        let now = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        let inMorningWindow = (4...11).contains(hour)
        let eligible = inMorningWindow || morningHRVForce
        let reason: String
        if inMorningWindow {
            reason = "morning_window"
        } else if morningHRVForce {
            reason = "debug_force"
        } else {
            reason = "outside_morning_window"
        }

        captureLabel = value(after: "--atria-capture-label", in: arguments) ?? "morning-hrv"
        autoCaptureDelaySeconds = doubleValue(after: "--atria-auto-capture-delay", in: arguments, default: 20, range: 0...3_600)
        autoCaptureRRThreshold = doubleValue(after: "--atria-auto-capture-when-rr", in: arguments, default: 0.90, range: 0...1)
        autoCaptureRRWindowSeconds = doubleValue(after: "--atria-auto-capture-rr-window", in: arguments, default: 30, range: 1...300)
        autoCaptureRRMinFrames = intValue(after: "--atria-auto-capture-rr-min-frames", in: arguments, default: 20, range: 1...1_000)
        autoCaptureMaxRRGapSeconds = doubleValue(after: "--atria-auto-capture-max-rr-gap", in: arguments, default: 3, range: 0...60)
        autoCaptureRRTimeoutSeconds = doubleValue(after: "--atria-auto-capture-rr-timeout", in: arguments, default: 180, range: 0...3_600)
        autoCaptureMaxAttempts = intValue(after: "--atria-auto-capture-max-attempts", in: arguments, default: 3, range: 1...50)
        autoStopCaptureAfterSeconds = doubleValue(after: "--atria-auto-stop-after", in: arguments, default: 305, range: 0...3_600)
        autoStopCaptureWhenReady = true

        AtriaDebugLog("ATRIADBG morning_hrv_check eligible=%d reason=%@ local_time=%02d:%02d label=%@ rr_threshold=%.2f rr_window_s=%.1f rr_min_frames=%d rr_max_gap_s=%.1f timeout_s=%.1f stop_after_s=%.1f still_source=rr_continuity motion_source=unavailable hrv_state=learning_until_ready",
              eligible ? 1 : 0, reason, hour, minute, captureLabel,
              autoCaptureRRThreshold, autoCaptureRRWindowSeconds,
              autoCaptureRRMinFrames, autoCaptureMaxRRGapSeconds,
              autoCaptureRRTimeoutSeconds, autoStopCaptureAfterSeconds)

        guard eligible else {
            AtriaDebugLog("ATRIADBG morning_hrv_skip reason=%@ hrv_state=learning", reason)
            return
        }
        scheduleAutoCapture()
    }

    private func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        let next = arguments.index(after: index)
        guard arguments.indices.contains(next) else { return nil }
        return arguments[next]
    }

    private func doubleValue(after flag: String, in arguments: [String], default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let raw = value(after: flag, in: arguments), let value = Double(raw) else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func intValue(after flag: String, in arguments: [String], default defaultValue: Int, range: ClosedRange<Int>) -> Int {
        guard let raw = value(after: flag, in: arguments), let value = Int(raw) else {
            return defaultValue
        }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func scheduleDelayedSessionSave(after seconds: TimeInterval) {
        delayedSessionSaveTask?.cancel()
        AtriaDebugLog("ATRIADBG session_auto_save schedule delay_s=%.1f label=%@", seconds, captureLabel.isEmpty ? "Auto-saved" : captureLabel)
        delayedSessionSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            let label = captureLabel.isEmpty ? "Auto-saved" : captureLabel
            guard session.count >= autoSaveMinSamples else {
                AtriaDebugLog("ATRIADBG session_auto_save status=skipped reason=insufficient_samples samples=%d min_samples=%d label=%@",
                      session.count, autoSaveMinSamples, label)
                return
            }
            guard let saved = finishSession(label: label) else {
                AtriaDebugLog("ATRIADBG session_auto_save status=skipped reason=finish_failed samples=%d label=%@",
                      session.count, label)
                return
            }
            let persisted = persistFinishedSession(saved, reason: "session_auto_save")
            AtriaDebugLog("ATRIADBG session_auto_save status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@",
                  persisted ? "saved" : "store_failed",
                  saved.points.count,
                  saved.rrSampleCount,
                  saved.motionHintCountValue,
                  saved.motionHintKindsValue,
                  saved.motionEvidenceSourceValue,
                  saved.motionEvidenceValidatedValue ? 1 : 0,
                  saved.motionShortCountValue,
                  Self.formatDouble(saved.motionShortMeanValue),
                  Self.formatDouble(saved.motionShortMinValue),
                  Self.formatDouble(saved.motionShortMaxValue),
                  saved.motionShortOverOneCountValue,
                  saved.duration,
                  saved.avg,
                  saved.peak,
                  saved.restingStable,
                  saved.hrv.map(String.init) ?? "learning",
                  label)
        }
    }

    private func schedulePeriodicSessionSave(every seconds: TimeInterval) {
        delayedSessionSaveTask?.cancel()
        let label = captureLabel.isEmpty ? "Auto-saved" : captureLabel
        AtriaDebugLog("ATRIADBG session_auto_save schedule interval_s=%.1f label=%@", seconds, label)
        delayedSessionSaveTask = Task { @MainActor in
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                let chunkLabel = "\(label) chunk \(index)"
                guard session.count >= autoSaveMinSamples else {
                    AtriaDebugLog("ATRIADBG session_auto_save status=skipped reason=insufficient_samples samples=%d min_samples=%d label=%@ interval_index=%d",
                          session.count, autoSaveMinSamples, chunkLabel, index)
                    continue
                }
                guard let saved = finishSession(label: chunkLabel) else {
                    AtriaDebugLog("ATRIADBG session_auto_save status=skipped reason=finish_failed samples=%d label=%@ interval_index=%d",
                          session.count, chunkLabel, index)
                    continue
                }
                let persisted = persistFinishedSession(saved, reason: "session_auto_save_periodic")
                AtriaDebugLog("ATRIADBG session_auto_save status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ interval_index=%d mode=periodic",
                      persisted ? "saved" : "store_failed",
                      saved.points.count,
                      saved.rrSampleCount,
                      saved.motionHintCountValue,
                      saved.motionHintKindsValue,
                      saved.motionEvidenceSourceValue,
                      saved.motionEvidenceValidatedValue ? 1 : 0,
                      saved.motionShortCountValue,
                      Self.formatDouble(saved.motionShortMeanValue),
                      Self.formatDouble(saved.motionShortMinValue),
                      Self.formatDouble(saved.motionShortMaxValue),
                      saved.motionShortOverOneCountValue,
                      saved.duration,
                      saved.avg,
                      saved.peak,
                      saved.restingStable,
                      saved.hrv.map(String.init) ?? "learning",
                      chunkLabel,
                      index)
                index += 1
            }
        }
    }

    private func scheduleSessionCheckpoint(every seconds: TimeInterval,
                                           fallbackLabel: String,
                                           source: String) {
        delayedSessionSaveTask?.cancel()
        let label = captureLabel.isEmpty ? fallbackLabel : captureLabel
        UserDefaults.standard.set(true, forKey: CheckpointDefaults.armed)
        UserDefaults.standard.set(seconds, forKey: CheckpointDefaults.interval)
        UserDefaults.standard.set(label, forKey: CheckpointDefaults.label)
        UserDefaults.standard.set(source, forKey: CheckpointDefaults.source)
        AtriaDebugLog("ATRIADBG session_checkpoint schedule interval_s=%.1f label=%@ source=%@", seconds, label, source)
        delayedSessionSaveTask = Task { @MainActor in
            var index = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                if Task.isCancelled { break }
                guard session.count >= autoSaveMinSamples else {
                    UserDefaults.standard.set("skipped_insufficient_samples", forKey: CheckpointDefaults.lastStatus)
                    UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
                    UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
                    UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
                    AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=insufficient_samples samples=%d min_samples=%d label=%@ checkpoint_index=%d source=%@",
                          session.count, autoSaveMinSamples, label, index, source)
                    continue
                }
                if powerThermalGovernor.shouldDeferNonEssentialAnalysis {
                    lastCanonicalCheckpointAt = Date()
                    persistActiveSessionJournalIfNeeded(
                        reason: "scheduled_checkpoint_thermal_heartbeat",
                        force: true,
                        refreshTimestampIfUnchanged: true
                    )
                    UserDefaults.standard.set("journal_only_thermal_pressure", forKey: CheckpointDefaults.lastStatus)
                    index += 1
                    continue
                }
                guard let saved = snapshotSession(label: label) else {
                    UserDefaults.standard.set("skipped_snapshot_failed", forKey: CheckpointDefaults.lastStatus)
                    UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
                    UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
                    UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
                    AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=snapshot_failed samples=%d label=%@ checkpoint_index=%d source=%@",
                          session.count, label, index, source)
                    continue
                }
                let checkpointPersisted = onSessionCheckpoint?(saved) == true
                persistActiveSessionJournalIfNeeded(reason: "session_checkpoint", force: true)
                UserDefaults.standard.set(checkpointPersisted ? "saved" : "store_failed", forKey: CheckpointDefaults.lastStatus)
                UserDefaults.standard.set(index, forKey: CheckpointDefaults.lastIndex)
                UserDefaults.standard.set(saved.points.count, forKey: CheckpointDefaults.lastSamples)
                UserDefaults.standard.set(Int(saved.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
                AtriaDebugLog("ATRIADBG session_checkpoint status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ checkpoint_index=%d mode=upsert source=%@",
                      checkpointPersisted ? "saved" : "store_failed",
                      saved.points.count,
                      saved.rrSampleCount,
                      saved.motionHintCountValue,
                      saved.motionHintKindsValue,
                      saved.motionEvidenceSourceValue,
                      saved.motionEvidenceValidatedValue ? 1 : 0,
                      saved.motionShortCountValue,
                      Self.formatDouble(saved.motionShortMeanValue),
                      Self.formatDouble(saved.motionShortMinValue),
                      Self.formatDouble(saved.motionShortMaxValue),
                      saved.motionShortOverOneCountValue,
                      saved.hrRaw2A37Value,
                      saved.hrAcceptedValue,
                      saved.hrZeroValue,
                      saved.hrArtifactHeldValue,
                      saved.hrArtifactDroppedValue,
                      saved.hrRawGapsValue,
                      saved.hrAcceptedGapsValue,
                      saved.hrMaxRawGapValue,
                      saved.hrMaxAcceptedGapValue,
                      saved.duration,
                      saved.avg,
                      saved.peak,
                      saved.restingStable,
                      saved.hrv.map(String.init) ?? "learning",
                      label,
                      index,
                      source)
                index += 1
            }
        }
    }

    private func scheduleDebugManualCheckpoint(after seconds: TimeInterval) {
        debugManualCheckpointTask?.cancel()
        let label = captureLabel.isEmpty ? "Manual checkpoint" : captureLabel
        AtriaDebugLog("ATRIADBG manual_checkpoint schedule delay_s=%.1f label=%@ source=launch_arg", seconds, label)
        debugManualCheckpointTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if Task.isCancelled { return }
            guard session.count >= autoSaveMinSamples else {
                UserDefaults.standard.set("skipped_manual_insufficient_samples", forKey: CheckpointDefaults.lastStatus)
                UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
                UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
                AtriaDebugLog("ATRIADBG manual_checkpoint status=skipped reason=insufficient_samples samples=%d min_samples=%d label=%@ source=launch_arg",
                      session.count,
                      autoSaveMinSamples,
                      label)
                return
            }
            guard let saved = snapshotSession(label: label) else {
                UserDefaults.standard.set("skipped_manual_snapshot_failed", forKey: CheckpointDefaults.lastStatus)
                UserDefaults.standard.set(session.count, forKey: CheckpointDefaults.lastSamples)
                UserDefaults.standard.set(0, forKey: CheckpointDefaults.lastDuration)
                AtriaDebugLog("ATRIADBG manual_checkpoint status=skipped reason=snapshot_failed samples=%d label=%@ source=launch_arg",
                      session.count,
                      label)
                return
            }
            let checkpointPersisted = onSessionCheckpoint?(saved) == true
            persistActiveSessionJournalIfNeeded(reason: "manual_checkpoint", force: true)
            UserDefaults.standard.set(checkpointPersisted ? "saved_manual" : "store_failed_manual", forKey: CheckpointDefaults.lastStatus)
            UserDefaults.standard.set(saved.points.count, forKey: CheckpointDefaults.lastSamples)
            UserDefaults.standard.set(Int(saved.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
            AtriaDebugLog("ATRIADBG manual_checkpoint status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ mode=upsert source=launch_arg reset_live_session=0",
                  checkpointPersisted ? "saved" : "store_failed",
                  saved.points.count,
                  saved.rrSampleCount,
                  saved.motionHintCountValue,
                  saved.motionHintKindsValue,
                  saved.motionEvidenceSourceValue,
                  saved.motionEvidenceValidatedValue ? 1 : 0,
                  saved.motionShortCountValue,
                  Self.formatDouble(saved.motionShortMeanValue),
                  Self.formatDouble(saved.motionShortMinValue),
                  Self.formatDouble(saved.motionShortMaxValue),
                  saved.motionShortOverOneCountValue,
                  saved.hrRaw2A37Value,
                  saved.hrAcceptedValue,
                  saved.hrZeroValue,
                  saved.hrArtifactHeldValue,
                  saved.hrArtifactDroppedValue,
                  saved.hrRawGapsValue,
                  saved.hrAcceptedGapsValue,
                  saved.hrMaxRawGapValue,
                  saved.hrMaxAcceptedGapValue,
                  saved.duration,
                  saved.avg,
                  saved.peak,
                  saved.restingStable,
                  saved.hrv.map(String.init) ?? "learning",
                  label)
        }
    }

    private func scheduleAutoCapture() {
        autoCaptureAttempt = 0
        scheduleAutoCaptureAttempt(reason: "initial")
    }

    private func scheduleAutoCaptureAttempt(reason: String) {
        autoCaptureScheduledAt = Date()
        autoCapturePending = true
        resetRRAvailabilityWindow(&autoCaptureRRWindow, head: &autoCaptureRRWindowHead)
        lastAutoCaptureRRGateLogAt = nil
        AtriaDebugLog("ATRIADBG autoCapture schedule label=%@ reason=%@ attempt_next=%d max_attempts=%d delay_s=%.1f rr_threshold=%.2f rr_window_s=%.1f rr_min_frames=%d rr_max_gap_s=%.1f rr_timeout_s=%.1f stop_when_ready=%d stop_after_s=%.1f strict_live_rr=%d",
              captureLabel, reason, autoCaptureAttempt + 1, autoCaptureMaxAttempts,
              autoCaptureDelaySeconds, autoCaptureRRThreshold,
              autoCaptureRRWindowSeconds, autoCaptureRRMinFrames,
              autoCaptureMaxRRGapSeconds, autoCaptureRRTimeoutSeconds,
              autoStopCaptureWhenReady ? 1 : 0, autoStopCaptureAfterSeconds,
              strictLiveRRCapture ? 1 : 0)
        if autoCaptureRRThreshold > 0 {
            if autoCaptureRRTimeoutSeconds > 0 {
                autoCaptureTimeoutTask?.cancel()
                autoCaptureTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(autoCaptureRRTimeoutSeconds))
                    startAutoCaptureIfNeeded(reason: "timeout")
                }
            }
            return
        }
        Task { @MainActor in
            if autoCaptureDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(autoCaptureDelaySeconds))
            }
            startAutoCaptureIfNeeded(reason: "delay")
        }
    }

    private func startAutoCaptureIfNeeded(reason: String) {
        guard autoCapturePending, !isRecording else { return }
        guard autoCaptureAttempt < autoCaptureMaxAttempts else {
            autoCapturePending = false
            autoCaptureTimeoutTask?.cancel()
            autoCaptureTimeoutTask = nil
            AtriaDebugLog("ATRIADBG autoCapture exhausted label=%@ attempts=%d max_attempts=%d reason=%@",
                  captureLabel, autoCaptureAttempt, autoCaptureMaxAttempts, reason)
            return
        }
        autoCaptureAttempt += 1
        autoCapturePending = false
        autoCaptureTimeoutTask?.cancel()
        autoCaptureTimeoutTask = nil
        AtriaDebugLog("ATRIADBG autoCapture start label=%@ attempt=%d max_attempts=%d reason=%@ delay_s=%.1f rr_threshold=%.2f stop_when_ready=%d stop_after_s=%.1f",
              captureLabel, autoCaptureAttempt, autoCaptureMaxAttempts,
              reason, autoCaptureDelaySeconds, autoCaptureRRThreshold,
              autoStopCaptureWhenReady ? 1 : 0, autoStopCaptureAfterSeconds)
        toggleRecording()
    }

    private func rearmAutoCaptureAfterAbort(reason: String) {
        guard autoCaptureRRThreshold > 0 else { return }
        guard autoCaptureAttempt < autoCaptureMaxAttempts else {
            AtriaDebugLog("ATRIADBG autoCapture exhausted label=%@ attempts=%d max_attempts=%d reason=%@",
                  captureLabel, autoCaptureAttempt, autoCaptureMaxAttempts, reason)
            return
        }
        scheduleAutoCaptureAttempt(reason: reason)
    }

    private func appendAdaptiveAutoCaptureObservation(now: Date, rrnum: Int, source: String) -> Bool {
        guard autoCapturePending, autoCaptureRRThreshold > 0, !isRecording else { return false }
        guard autoCaptureScheduledAt != nil else { return false }
        guard shouldTrackRRAvailability(source: source, rrCount: rrnum) else { return false }
        if shouldSkipRealtimeZeroRRTracking(now: now,
                                           rrCount: rrnum,
                                           source: source,
                                           lastTrackedAt: &lastRealtimeZeroRRAutoCaptureUpdateAt) {
            return false
        }
        autoCaptureRRWindow.append((t: now, hasRR: rrnum > 0, source: source))
        return true
    }

    private func evaluateAdaptiveAutoCapture(now: Date) {
        guard autoCapturePending, autoCaptureRRThreshold > 0, !isRecording else { return }
        guard let scheduledAt = autoCaptureScheduledAt else { return }
        let summary = pruneRRWindow(&autoCaptureRRWindow,
                                    head: &autoCaptureRRWindowHead,
                                    now: now,
                                    maxAge: autoCaptureRRWindowSeconds)

        let totalFrames = summary.frames
        let rrFrames = summary.rrFrames
        let fraction = summary.fraction
        let frameMaxRRGap = summary.frameMaxGap
        let beatMaxRRGap = maxRRBeatGap(since: max(scheduledAt, now.addingTimeInterval(-autoCaptureRRWindowSeconds)),
                                        now: now)
        let maxRRGap = beatMaxRRGap ?? frameMaxRRGap
        let sourceLabel = summary.sourceLabel
        let gapEligible = autoCaptureMaxRRGapSeconds <= 0 || maxRRGap <= autoCaptureMaxRRGapSeconds
        let elapsed = now.timeIntervalSince(scheduledAt)
        let gateEligible = elapsed >= autoCaptureDelaySeconds && totalFrames >= autoCaptureRRMinFrames

        let shouldLogGate: Bool
        if let lastAutoCaptureRRGateLogAt {
            shouldLogGate = now.timeIntervalSince(lastAutoCaptureRRGateLogAt) >= 5
        } else {
            shouldLogGate = true
        }
        if gateEligible, shouldLogGate {
            lastAutoCaptureRRGateLogAt = now
            AtriaDebugLog("ATRIADBG autoCapture rr_gate source=%@ elapsed_s=%.1f fraction=%.3f rr_frames=%d total_frames=%d threshold=%.3f max_rr_gap_s=%.1f frame_max_rr_gap_s=%.1f beat_timeline=%d max_gap_threshold_s=%.1f gap_ok=%d window_s=%.1f min_frames=%d",
                  sourceLabel,
                  elapsed, fraction, rrFrames, totalFrames, autoCaptureRRThreshold,
                  maxRRGap, frameMaxRRGap, beatMaxRRGap == nil ? 0 : 1,
                  autoCaptureMaxRRGapSeconds, gapEligible ? 1 : 0,
                  autoCaptureRRWindowSeconds, autoCaptureRRMinFrames)
        }

        guard gateEligible, fraction >= autoCaptureRRThreshold, gapEligible else { return }
        startAutoCaptureIfNeeded(reason: String(format: "rr_fraction_%.3f", fraction))
    }

    private func updateAdaptiveAutoCapture(now: Date, rrnum: Int, source: String) {
        guard appendAdaptiveAutoCaptureObservation(now: now, rrnum: rrnum, source: source) else { return }
        if realtimePacketBatchDepth > 0, source == "0x28" {
            realtimeBatchPendingAutoCaptureAt = now
            return
        }
        evaluateAdaptiveAutoCapture(now: now)
    }

    private func resetRRAvailabilityWindow(_ window: inout [(t: Date, hasRR: Bool, source: String)],
                                           head: inout Int) {
        window.removeAll(keepingCapacity: true)
        head = 0
    }

    private func removeRRAvailabilityWindowEntries(_ window: inout [(t: Date, hasRR: Bool, source: String)],
                                                   head: inout Int,
                                                   where shouldRemove: ((t: Date, hasRR: Bool, source: String)) -> Bool) {
        guard !window.isEmpty else {
            head = 0
            return
        }
        let activeStart = min(head, window.count)
        let active = window[activeStart...].filter { !shouldRemove($0) }
        window = Array(active)
        head = 0
    }

    private func compactRRAvailabilityWindowIfNeeded(_ window: inout [(t: Date, hasRR: Bool, source: String)],
                                                     head: inout Int) {
        guard head > 0 else { return }
        if head >= window.count {
            window.removeAll(keepingCapacity: true)
            head = 0
            return
        }
        if head >= 64 && head * 2 >= window.count {
            window.removeFirst(head)
            head = 0
        }
    }

    @discardableResult
    private func pruneRRWindow(_ window: inout [(t: Date, hasRR: Bool, source: String)],
                               head: inout Int,
                               now: Date,
                               maxAge: TimeInterval,
                               minimumTime: Date? = nil) -> RRWindowSummary {
        while head < window.count {
            let sample = window[head]
            if let minimumTime, sample.t < minimumTime {
                head += 1
                continue
            }
            if now.timeIntervalSince(sample.t) > maxAge {
                head += 1
                continue
            }
            break
        }
        compactRRAvailabilityWindowIfNeeded(&window, head: &head)

        guard head < window.count else {
            return RRWindowSummary(frames: 0,
                                   rrFrames: 0,
                                   fraction: 0,
                                   span: 0,
                                   frameMaxGap: 0,
                                   sourceLabel: "none",
                                   firstTimestamp: nil)
        }
        let activeWindow = window[head...]
        guard let first = activeWindow.first else {
            return RRWindowSummary(frames: 0,
                                   rrFrames: 0,
                                   fraction: 0,
                                   span: 0,
                                   frameMaxGap: 0,
                                   sourceLabel: "none",
                                   firstTimestamp: nil)
        }

        var rrFrames = 0
        var has2A37 = false
        var has28 = false
        var firstRR: Date?
        var previousRR: Date?
        var frameMaxGap: TimeInterval = 0

        for sample in activeWindow {
            guard sample.hasRR else { continue }
            rrFrames += 1
            if sample.source == "0x2A37" {
                has2A37 = true
            } else if sample.source == "0x28" {
                has28 = true
            }
            if let previousRR {
                frameMaxGap = max(frameMaxGap, sample.t.timeIntervalSince(previousRR))
            } else {
                firstRR = sample.t
                frameMaxGap = sample.t.timeIntervalSince(first.t)
            }
            previousRR = sample.t
        }

        if let previousRR {
            frameMaxGap = max(frameMaxGap, now.timeIntervalSince(previousRR))
        } else {
            frameMaxGap = now.timeIntervalSince(first.t)
        }

        let sourceLabel: String
        if has2A37 && has28 {
            sourceLabel = "mixed"
        } else if has2A37 {
            sourceLabel = "2a37"
        } else if has28 {
            sourceLabel = "0x28"
        } else {
            sourceLabel = "none"
        }

        let frames = activeWindow.count
        return RRWindowSummary(frames: frames,
                               rrFrames: rrFrames,
                               fraction: frames > 0 ? Double(rrFrames) / Double(frames) : 0,
                               span: now.timeIntervalSince(first.t),
                               frameMaxGap: frameMaxGap,
                               sourceLabel: sourceLabel,
                               firstTimestamp: firstRR ?? first.t)
    }

    private var currentRRBufferCount: Int {
        max(0, rrBuffer.count - rrBufferHead)
    }

    private func resetRRBuffer() {
        rrBuffer.removeAll(keepingCapacity: true)
        rrBufferHead = 0
    }

    private func compactRRBufferIfNeeded() {
        guard rrBufferHead > 0 else { return }
        if rrBufferHead >= rrBuffer.count {
            rrBuffer.removeAll(keepingCapacity: true)
            rrBufferHead = 0
            return
        }
        if rrBufferHead >= 128 && rrBufferHead * 2 >= rrBuffer.count {
            rrBuffer.removeFirst(rrBufferHead)
            rrBufferHead = 0
        }
    }

    private func pruneRRBuffer(now: Date) {
        while rrBufferHead < rrBuffer.count,
              now.timeIntervalSince(rrBuffer[rrBufferHead].t) > 305 {
            rrBufferHead += 1
        }
        compactRRBufferIfNeeded()
    }

    private func currentRRBufferWindow() -> ArraySlice<RRInterval> {
        guard rrBufferHead < rrBuffer.count else { return [] }
        return rrBuffer[rrBufferHead...]
    }

    private func noteRRArchiveDidChange() {
        invalidateActiveSessionJournalRestoreForLiveData()
        rrArchiveRevision &+= 1
        recentBreathworkRRSampleCache = nil
    }

    func recentBreathworkRRSamples(now: Date = Date(), maxAge: TimeInterval = 10 * 60) -> [AtriaBreathworkSession.RRSample] {
        let nowBucket = Int((now.timeIntervalSinceReferenceDate / Self.recentBreathworkRRCacheBucketSeconds).rounded(.down))
        if let cache = recentBreathworkRRSampleCache,
           cache.archiveRevision == rrArchiveRevision,
           cache.maxAge == maxAge,
           cache.nowBucket == nowBucket {
            return cache.samples
        }

        var samples: [AtriaBreathworkSession.RRSample] = []
        samples.reserveCapacity(min(rrArchive.count, 900))
        for interval in rrArchive.reversed() {
            guard now.timeIntervalSince(interval.t) <= maxAge else { break }
            let roundedMS = Int(interval.ms.rounded())
            guard (300...2000).contains(roundedMS) else { continue }
            samples.append(AtriaBreathworkSession.RRSample(date: interval.t, ms: roundedMS))
            if samples.count == 900 { break }
        }
        samples.reverse()
        recentBreathworkRRSampleCache = RecentBreathworkRRSampleCache(archiveRevision: rrArchiveRevision,
                                                                      maxAge: maxAge,
                                                                      nowBucket: nowBucket,
                                                                      samples: samples)
        return samples
    }

    func startScan(reason: String = "manual") {
        guard central.state == .poweredOn else {
            pendingScanReason = reason
            AtriaDebugLog("ATRIADBG ble_scan status=skipped reason=%@ central_state=%d",
                  reason,
                  central.state.rawValue)
            return
        }
        pendingScanReason = nil
        if peripheral == nil,
           let restored = central.retrieveConnectedPeripherals(withServices: UUIDs.scanServices).first {
            attach(to: restored, name: restored.name ?? "Strap")
            AtriaDebugLog("ATRIADBG ble_scan status=short_circuit reason=%@ action=attach_connected_peripheral",
                  reason)
            return
        }
        if !reason.contains("_retry") {
            scanRetryCount = 0
        }
        let allowBroadScan = shouldAllowBroadScan(for: reason)
        let useBroadScan = shouldUseBroadScanImmediately(for: reason, allowBroadScan: allowBroadScan)
        let requestedMode = useBroadScan ? "broad" : "filtered"
        if status == .scanning,
           peripheral == nil,
           !reason.contains("_retry"),
           !reason.contains("_broad"),
           let lastScanRequestedAt,
           Date().timeIntervalSince(lastScanRequestedAt) < Self.scanRequestDedupWindow,
           lastScanRequestMode == requestedMode {
            AtriaDebugLog("ATRIADBG ble_scan status=coalesced reason=%@ mode=%@ since_last_s=%.2f",
                  reason,
                  requestedMode,
                  Date().timeIntervalSince(lastScanRequestedAt))
            return
        }
        lastScanRequestedAt = Date()
        lastScanRequestMode = requestedMode
        reconnectWatchdogTask?.cancel()
        scanWideningTask?.cancel()
        if !hasSavedStrap {
            clearPendingKnownReconnect(reason: "start_scan")
        }
        isActivelyScanning = true
        recomputeConnectionStatus(reason: "start_scan")
        // Prefer a staged fresh scan: start with the expected strap/heart-rate
        // services for faster discovery, then broaden only if nothing appears.
        AtriaDebugLog("ATRIADBG ble_scan status=started reason=%@ standard_hr_only=%d retry=%d mode=%@ broad_allowed=%d",
              reason,
              standardHROnlyMode ? 1 : 0,
              scanRetryCount,
              requestedMode,
              allowBroadScan ? 1 : 0)
        central.scanForPeripherals(withServices: useBroadScan ? nil : UUIDs.scanServices,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if allowBroadScan && !useBroadScan {
            scheduleScanWidening(reason: reason)
        }
        scheduleScanRetry(reason: reason)
    }

    private func shouldUseBroadScanImmediately(for reason: String, allowBroadScan: Bool) -> Bool {
        guard allowBroadScan else { return false }
        if reason.contains("_broad") || scanRetryCount > 0 {
            return true
        }
        let hasEverConnected = UserDefaults.standard.integer(forKey: LinkDefaults.successes) > 0
        return !hasEverConnected && isInitialAutomaticSetupReason(reason)
    }

    private func shouldAllowBroadScan(for reason: String) -> Bool {
        if reason.contains("_broad") {
            return true
        }
        let hasEverConnected = UserDefaults.standard.integer(forKey: LinkDefaults.successes) > 0
        if !hasEverConnected {
            return true
        }
        if reason == "manual"
            || reason.contains("connection_guide")
            || reason.contains("home_manual")
            || reason.contains("restore_discard") {
            return true
        }
        return false
    }

    private func isInitialAutomaticSetupReason(_ reason: String) -> Bool {
        reason == "home_appear"
            || reason == "status_disconnected"
            || reason.hasPrefix("connection_guide")
            || reason == "scene_active_resume"
            || reason == "did_fail_to_connect_recovery"
    }

    private func scheduleScanWidening(reason: String) {
        scanWideningTask?.cancel()
        scanWideningTask = Task { @MainActor in
            try? await Task.sleep(for: scanWideningDelay(for: reason))
            if Task.isCancelled { return }
            guard self.status == .scanning, self.peripheral == nil else { return }
            AtriaDebugLog("ATRIADBG ble_scan status=widen reason=%@ action=restart_scan_broad", reason)
            self.central.stopScan()
            self.startScan(reason: "\(reason)_broad")
        }
    }

    private func scheduleScanRetry(reason: String) {
        scanRetryTask?.cancel()
        guard scanRetryCount < maxScanRetries else { return }
        scanRetryTask = Task { @MainActor in
            try? await Task.sleep(for: scanRetryDelay(for: reason))
            if Task.isCancelled { return }
            guard self.status == .scanning, self.peripheral == nil else { return }
            self.scanRetryCount += 1
            AtriaDebugLog("ATRIADBG ble_scan status=retry reason=%@ retry=%d max=%d action=restart_scan",
                  reason,
                  self.scanRetryCount,
                  self.maxScanRetries)
            self.central.stopScan()
            self.startScan(reason: "\(reason)_retry")
        }
    }

    private func scanWideningDelay(for reason: String) -> Duration {
        let hasEverConnected = UserDefaults.standard.integer(forKey: LinkDefaults.successes) > 0
        if !hasEverConnected && isInitialAutomaticSetupReason(reason) {
            return .milliseconds(900)
        }
        return .seconds(2)
    }

    private func scanRetryDelay(for reason: String) -> Duration {
        let hasEverConnected = UserDefaults.standard.integer(forKey: LinkDefaults.successes) > 0
        if !hasEverConnected && isInitialAutomaticSetupReason(reason) {
            return .milliseconds(2800)
        }
        return .seconds(5)
    }

    /// Connect and start service discovery on a peripheral we found or retrieved.
    fileprivate func attach(to p: CBPeripheral, name: String) {
        scanRetryTask?.cancel()
        scanWideningTask?.cancel()
        scanRetryCount = 0
        central.stopScan()
        isActivelyScanning = false
        peripheral = p
        assignIfChanged(\.deviceName, name)
        recomputeConnectionStatus(reason: "attach")
        p.delegate = self
        recordLinkAttempt(reason: "fresh_scan_attach", peripheral: p)
        central.connect(p, options: nil)
        startReconnectWatchdog(reason: "fresh_scan_attach", peripheral: p)
    }

    func disconnect() {
        reconnectWatchdogTask?.cancel()
        userRequestedDisconnect = true
        if let p = peripheral {
            cancelPeripheralConnection(p, reason: "explicit_disconnect")
        }
    }

    private func cancelPeripheralConnection(_ peripheral: CBPeripheral, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(reason, forKey: "atria.ble.lastAppCancelReason")
        defaults.set(Date().timeIntervalSince1970, forKey: "atria.ble.lastAppCancelAt")
        defaults.set(defaults.integer(forKey: "atria.ble.appCancelCount") + 1,
                     forKey: "atria.ble.appCancelCount")
        central.cancelPeripheralConnection(peripheral)
        AtriaDebugLog("ATRIADBG ble_link status=cancel_requested reason=%@ app_cancel_count=%d",
                      reason,
                      defaults.integer(forKey: "atria.ble.appCancelCount"))
    }

    /// True once the user has paired a strap that we should keep reconnecting to.
    var hasSavedStrap: Bool {
        UserDefaults.standard.string(forKey: LinkDefaults.savedPeripheralUUID) != nil
    }

    /// THE SINGLE SOURCE OF TRUTH for the displayed status. Derives it purely from
    /// CoreBluetooth ground truth (central power state + the peripheral's real state
    /// + whether a strap is saved + whether we're scanning). Call after ANY event
    /// that can change those. Nothing else writes `status` — so heals, watchdogs, and
    /// stale/queued data can never lie (e.g. "Live" with Bluetooth off).
    func recomputeConnectionStatus(reason: String) {
        let next = derivedConnectionStatus()
        guard status != next else { return }
        status = next
        AtriaDebugLog("ATRIADBG status_derived to=%@ reason=%@ central=%ld peripheral=%ld saved=%d scanning=%d",
                      next.logToken,
                      reason,
                      Int(central.state.rawValue),
                      peripheral.map { Int($0.state.rawValue) } ?? -1,
                      hasSavedStrap ? 1 : 0,
                      isActivelyScanning ? 1 : 0)
    }

    private func derivedConnectionStatus() -> Status {
        switch central.state {
        case .poweredOff, .unauthorized, .unsupported:
            // Bluetooth genuinely unavailable — a stale peripheral.state can't override this.
            return .poweredOff
        case .poweredOn:
            if let peripheral {
                switch peripheral.state {
                case .connected:
                    return .connected
                case .connecting, .disconnecting:
                    return .connecting
                case .disconnected:
                    // We hold a peripheral ref but it's down: a saved strap means we
                    // have a standing pending connect (reconnecting), else first setup.
                    return hasSavedStrap ? .connecting : (isActivelyScanning ? .scanning : .disconnected)
                @unknown default:
                    return .connecting
                }
            }
            return isActivelyScanning ? .scanning : (hasSavedStrap ? .connecting : .disconnected)
        case .resetting, .unknown:
            // Transient — hold the last reasonable state without flapping.
            return peripheral?.state == .connected ? .connected : (hasSavedStrap ? .connecting : .disconnected)
        @unknown default:
            return .disconnected
        }
    }

    /// Re-arm a STANDING pending connection to the saved strap — no scan. iOS keeps
    /// the request and connects whenever the strap is in range, across range loss,
    /// background, and app relaunch. This is the "connect once, stay connected"
    /// primitive. Returns false only if no strap is saved yet (first-time setup).
    @discardableResult
    func reconnectToSavedPeripheralIfPossible(reason: String) -> Bool {
        let defaults = UserDefaults.standard
        guard let uuidString = defaults.string(forKey: LinkDefaults.savedPeripheralUUID),
              let uuid = UUID(uuidString: uuidString),
              let saved = central.retrievePeripherals(withIdentifiers: [uuid]).first else {
            return false
        }
        saved.delegate = self
        self.peripheral = saved
        assignIfChanged(\.deviceName, saved.name ?? deviceName)
        if saved.state == .connected {
            clearPendingKnownReconnect(reason: "\(reason)_already_connected")
            recomputeConnectionStatus(reason: "event")
            if motionHandshakeDiagnostic != nil {
                recordMotionHandshakeEvidence(event: "already_connected",
                                              detail: "discover_stream5_service_only")
                saved.discoverServices([Self.UUIDs.strapService])
            } else {
                saved.discoverServices(discoveryServicesForCurrentMode)
            }
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=%@ action=already_connected", reason)
        } else if saved.state == .connecting || saved.state == .disconnecting {
            recomputeConnectionStatus(reason: "event")
            markPendingKnownReconnect(reason: reason)
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=%@ action=keep_existing_transition peripheral_state=%d",
                          reason,
                          saved.state.rawValue)
        } else {
            recomputeConnectionStatus(reason: "event")
            recordLinkAttempt(reason: reason, peripheral: saved)
            markPendingKnownReconnect(reason: reason)
            // Standing pending connect — never times out; iOS fulfils it whenever
            // the strap becomes reachable. No scanning, no give-up.
            central.connect(saved, options: nil)
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=%@ action=pending_connect", reason)
        }
        return true
    }

    /// Explicit user action: stop reconnecting to the saved strap and forget it.
    func forgetSavedStrap(reason: String) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: LinkDefaults.savedPeripheralUUID)
        userRequestedDisconnect = true
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = nil
        freshScanFallbackTask?.cancel()
        freshScanFallbackTask = nil
        clearPendingKnownReconnect(reason: "forget")
        if let peripheral {
            cancelPeripheralConnection(peripheral, reason: "forget_\(reason)")
        }
        self.peripheral = nil
        central.stopScan()
        isActivelyScanning = false
        recomputeConnectionStatus(reason: "forget")
        AtriaDebugLog("ATRIADBG ble_link status=forgotten reason=%@ action=user_forget", reason)
    }

    private func startReconnectWatchdog(reason: String, peripheral: CBPeripheral) {
        reconnectWatchdogTask?.cancel()
        reconnectWatchdogTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(reconnectWatchdogSeconds))
            guard !Task.isCancelled else { return }
            guard self.peripheral === peripheral,
                  self.status == .connecting,
                  peripheral.state != .connected else { return }
            // For a SAVED strap, NEVER cancel the connection and fall back to
            // scanning — that is what made "unable to reconnect" possible. A
            // pending connect() stands forever and iOS fulfils it the moment the
            // strap returns to range. Keep it armed and stay in the reconnecting
            // state; only an explicit user "Forget" stops it.
            if self.hasSavedStrap {
                AtriaDebugLog("ATRIADBG ble_link watchdog reason=%@ action=observe_pending_connect_saved_strap peripheral_state=%d",
                              reason,
                              peripheral.state.rawValue)
                return
            }
            self.recordLinkFailure(reason: "\(reason)_watchdog", error: nil)
            self.preserveLongWearRangeLossRecovery(reason: "\(reason)_watchdog")
            self.realtimeArmed = false
            self.txCharacteristic = nil
            self.dbgTxReady = false
            self.peripheral = nil
            cancelPeripheralConnection(peripheral, reason: "\(reason)_watchdog_fresh_scan")
            AtriaDebugLog("ATRIADBG ble_link watchdog reason=%@ timeout_s=%.0f action=fresh_scan",
                  reason,
                  reconnectWatchdogSeconds)
            self.startScan(reason: "\(reason)_watchdog_recovery")
        }
    }

    // MARK: Capture control

    private let captureCorrectionContract = "schema=2 correction=drop_300_2000_delta20_interpolate confidence=kept_over_raw"

    func toggleRecording() {
        if isRecording {
            finishRecording()
        } else {
            captureRowsFlushTask?.cancel()
            captureRowsFlushTask = nil
            let startedAt = Date()
            captureStart = startedAt
            captureCleanWindowStart = startedAt
            captureElapsedSeconds = 0
            capturedRows = 0
            assignIfChanged(\.captureSummary, "Recording a beat-to-beat heart-rate window")
            assignIfChanged(\.captureWasValidationReady, false)
            captureAbortReason = nil
            captureQualityResetCount = 0
            autoStoppedReadyCapture = false
            resetRRAvailabilityWindow(&captureRRQualityWindow, head: &captureRRQualityWindowHead)
            captureLog = ["elapsed_ms,kind,source,opcode,len,label,value"]
            lastRRBeatTime = nil
            lastRRExportElapsedMS = nil
            resetRRBuffer()
            rrSamples = 0
            hrv = 0
            assignIfChanged(\.hrvSnapshot, nil)
            tachogram.removeAll(keepingCapacity: true)
            assignIfChanged(\.hrvQuality, "waiting for beat-to-beat samples")
            assignIfChanged(\.isRecording, true)
            let startedAtUTC = ISO8601DateFormatter().string(from: captureStart)
            let context = [
                "started_at_utc=\(startedAtUTC)",
                "app_bundle=com.adidshaft.atria",
                "ios=\(metaSafe(UIDevice.current.systemVersion))",
                "model=\(metaSafe(UIDevice.current.model))",
                "strap=\(metaSafe(deviceName))",
                "label=\(metaSafe(captureLabel))",
                "strict_live_rr=\(strictLiveRRCapture ? 1 : 0)"
            ].joined(separator: " ")
            logRow(kind: "capture_meta", source: "app", opcode: "", len: "",
                   value: context)
            logRow(kind: "capture_meta", source: "app", opcode: "", len: "",
                   value: captureCorrectionContract)
            if strictLiveRRCapture {
                logRow(kind: "hrv_seed", source: "archive", opcode: "", len: "",
                       value: "skipped_strict_live_rr")
            } else {
                seedRecordingFromArchiveAsync(now: captureStart)
            }
            captureTimer?.invalidate()
            captureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let now = Date()
                    self.captureElapsedSeconds = now.timeIntervalSince(self.captureStart)
                    let cleanElapsed = now.timeIntervalSince(self.captureCleanWindowStart)
                    if self.shouldRefreshHRVSnapshot(now: now) {
                        self.requestLiveHRVSnapshotRefresh(now: now,
                                                           logKind: "hrv_timer",
                                                           shouldLogConsole: false)
                    }
                    if self.autoStopCaptureAfterSeconds > 0,
                       cleanElapsed >= self.autoStopCaptureAfterSeconds {
                        AtriaDebugLog("ATRIADBG autoCapture stop reason=timeout elapsed=%.1f clean_elapsed=%.1f",
                              self.captureElapsedSeconds, cleanElapsed)
                        self.finishRecording(stopReason: "timeout")
                    }
                }
            }
        }
    }

    private func seedRecordingFromArchiveAsync(now: Date) {
        archiveSeedTask?.cancel()
        let archive = rrArchive
        archiveSeedTask = Task { [archive, now] in
            let seed = await Task.detached(priority: .utility) {
                archive
                    .filter { now.timeIntervalSince($0.t) <= 305 }
                    .sorted { $0.t < $1.t }
            }.value
            guard !Task.isCancelled,
                  self.isRecording,
                  self.captureStart == now else { return }
            self.archiveSeedTask = nil
            guard !seed.isEmpty else { return }
            self.applyRecordingArchiveSeed(seed, now: now)
        }
    }

    private func applyRecordingArchiveSeed(_ seed: [RRInterval], now: Date) {
        let liveWindow = currentRRBufferWindow()
        rrBuffer = (seed + liveWindow).sorted { $0.t < $1.t }
        rrBufferHead = 0
        rrSamples = rrBuffer.count
        hrvGateWasOpen = true
        if let last = seed.last,
           lastRRBeatTime == nil || last.t > (lastRRBeatTime ?? .distantPast) {
            lastRRBeatTime = last.t
            let seedElapsedMS = Int((last.t.timeIntervalSince(captureStart) * 1000).rounded())
            lastRRExportElapsedMS = max(lastRRExportElapsedMS ?? seedElapsedMS, seedElapsedMS)
        }
        logRow(kind: "hrv_quality", source: "app", opcode: "", len: "",
               value: String(format: "seeded_from_archive rr=%d window_s=%.0f",
                             seed.count, now.timeIntervalSince(seed.first?.t ?? now)))
        for rr in seed {
            logRow(kind: "rr_seed", source: "archive", opcode: "RR", len: "",
                   value: String(format: "%.0f", rr.ms), at: rr.t)
        }
        requestLiveHRVSnapshotRefresh(now: now,
                                      logKind: "hrv_seed",
                                      shouldLogConsole: true)
    }

    @discardableResult
    private func refreshHRVSnapshot(now: Date,
                                    logKind: String,
                                    shouldLogConsole: Bool) -> HRVSnapshot? {
        hrvLiveRefreshGeneration &+= 1
        hrvLiveRefreshTask?.cancel()
        hrvLiveRefreshTask = nil
        recordHRVAnalysisAttempt(at: now)
        pruneRRBuffer(now: now)
        let bufferWindow = currentRRBufferWindow()
        rrSamples = bufferWindow.count
        let analyzed = HRVAnalyzer.analyze(bufferWindow,
                                           now: now,
                                           includeTachogram: shouldMaintainLiveTachogram)
        return applyHRVAnalysisResult(analyzed,
                                      now: now,
                                      logKind: logKind,
                                      shouldLogConsole: shouldLogConsole)
    }

    private func requestLiveHRVSnapshotRefresh(now: Date,
                                               logKind: String,
                                               shouldLogConsole: Bool) {
        pruneRRBuffer(now: now)
        rrSamples = currentRRBufferCount
        if hrvLiveRefreshTask != nil {
            if let pending = pendingLiveHRVRefreshRequest {
                pendingLiveHRVRefreshRequest = (now: max(pending.now, now),
                                               logKind: logKind,
                                               shouldLogConsole: pending.shouldLogConsole || shouldLogConsole)
            } else {
                pendingLiveHRVRefreshRequest = (now: now,
                                               logKind: logKind,
                                               shouldLogConsole: shouldLogConsole)
            }
            return
        }
        startLiveHRVSnapshotRefresh(now: now,
                                    logKind: logKind,
                                    shouldLogConsole: shouldLogConsole)
    }

    private func startLiveHRVSnapshotRefresh(now: Date,
                                             logKind: String,
                                             shouldLogConsole: Bool) {
        recordHRVAnalysisAttempt(at: now)
        let bufferWindow = currentRRBufferWindow()
        let includeTachogram = shouldMaintainLiveTachogram
        hrvLiveRefreshGeneration &+= 1
        let generation = hrvLiveRefreshGeneration
        hrvLiveRefreshTask = Task { [bufferWindow, now, logKind, shouldLogConsole, generation, includeTachogram] in
            let analyzed = await Task.detached(priority: .utility) {
                HRVAnalyzer.analyze(bufferWindow, now: now, includeTachogram: includeTachogram)
            }.value
            guard !Task.isCancelled, generation == self.hrvLiveRefreshGeneration else { return }
            self.hrvLiveRefreshTask = nil
            let snapshot = self.applyHRVAnalysisResult(analyzed,
                                                       now: now,
                                                       logKind: logKind,
                                                       shouldLogConsole: shouldLogConsole)
            if snapshot?.isReady == true,
               self.isRecording,
               self.autoStopCaptureWhenReady,
               !self.autoStoppedReadyCapture {
                self.autoStoppedReadyCapture = true
                AtriaDebugLog("ATRIADBG autoCapture stop reason=ready")
                self.finishRecording()
            }
            if let pending = self.pendingLiveHRVRefreshRequest {
                self.pendingLiveHRVRefreshRequest = nil
                self.startLiveHRVSnapshotRefresh(now: pending.now,
                                                 logKind: pending.logKind,
                                                 shouldLogConsole: pending.shouldLogConsole)
            }
        }
    }

    private func recordHRVAnalysisAttempt(at date: Date) {
        if isRecording {
            lastHRVAnalysisAttemptAt = date
        } else {
            lastNormalWearHRVAnalysisAttemptAt = date
            Self.persistNormalWearHRVAnalysisAttemptDate(date)
        }
    }

    @discardableResult
    private func applyHRVAnalysisResult(_ analyzed: (HRVSnapshot?, [RRSample]),
                                        now: Date,
                                        logKind: String,
                                        shouldLogConsole: Bool) -> HRVSnapshot? {
        assignIfChanged(\.hrvSnapshot, analyzed.0)
        if shouldMaintainLiveTachogram {
            tachogram = analyzed.1
        } else if !tachogram.isEmpty {
            tachogram.removeAll(keepingCapacity: true)
        }
        guard let snapshot = analyzed.0 else {
            hrv = 0
            return nil
        }

        assignIfChanged(\.hrvQuality, snapshot.readinessMessage)
        if snapshot.isReady {
            let readyAt = snapshot.analyzedAt == .distantPast ? now : snapshot.analyzedAt
            lastHRVAnalysisAt = readyAt
            latestReadyHRVSnapshot = snapshot
            let defaults = UserDefaults.standard
            defaults.set(readyAt, forKey: HRVCadenceDefaults.lastReadyAnalysisAt)
            if let encoded = Self.encodedReadyHRVSnapshot(snapshot) {
                defaults.set(encoded, forKey: HRVCadenceDefaults.readySnapshot)
            }
        }
        let metricFields: String
        if snapshot.isReady {
            let resp = snapshot.respiratoryRate.map { String(format: "%.1f", $0) } ?? "learning"
            metricFields = String(format: "rmssd=%.1f sdnn=%.1f pnn50=%.1f lnrmssd=%.2f resp=%@",
                                  snapshot.rmssd, snapshot.sdnn, snapshot.pnn50,
                                  snapshot.lnRMSSD, resp)
        } else {
            metricFields = "rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
        }
        logRow(kind: logKind, source: "analyzer", opcode: "", len: "",
               value: String(format: "raw=%d kept=%d rejected_out_of_range=%d rejected_delta_over_20_percent=%d rejected_hr_mismatch=%d interpolated=%d conf=%d window=%.0f max_rr_gap_s=%.1f ready=%d reason=%@ %@",
                             snapshot.raw, snapshot.kept,
                             snapshot.rejectedOutOfRange,
                             snapshot.rejectedDeltaOver20Percent,
                             snapshot.rejectedHRMismatch,
                             snapshot.interpolated,
                             snapshot.confidencePercent,
                             snapshot.windowSeconds,
                             snapshot.maxRRGapSeconds,
                             snapshot.isReady ? 1 : 0,
                             snapshot.readinessReason,
                             metricFields))
        if shouldLogConsole {
            AtriaDebugLog("ATRIADBG hrv raw=%d kept=%d rejected_out_of_range=%d rejected_delta_over_20_percent=%d rejected_hr_mismatch=%d interpolated=%d conf=%d window=%.0f max_rr_gap_s=%.1f ready=%d reason=%@ %@",
                  snapshot.raw, snapshot.kept,
                  snapshot.rejectedOutOfRange,
                  snapshot.rejectedDeltaOver20Percent,
                  snapshot.rejectedHRMismatch,
                  snapshot.interpolated,
                  snapshot.confidencePercent,
                  snapshot.windowSeconds,
                  snapshot.maxRRGapSeconds,
                  snapshot.isReady ? 1 : 0,
                  snapshot.readinessReason,
                  metricFields)
        }
        hrv = snapshot.isReady ? Int(snapshot.rmssd.rounded()) : 0
        return snapshot
    }

    private func finishRecording(stopReason: String = "manual") {
        captureTimer?.invalidate()
        captureTimer = nil
        captureRowsFlushTask?.cancel()
        captureRowsFlushTask = nil
        flushCapturedRows()
        captureElapsedSeconds = Date().timeIntervalSince(captureStart)
        let finalAbortReason = captureAbortReason
        let summary: String
        let ready: Bool
        let summaryLogValue: String
        if let h = hrvSnapshot {
            ready = h.isReady && finalAbortReason == nil
            summary = String(format: "%@ · saved %.0fs · HRV %.0fs · kept beats %d/%d · max gap %.1fs · confidence %d%% · RMSSD %@ · SDNN %@ · pNN50 %@ · ln %@ · breathing %@",
                             ready ? "Personal baseline ready" : "Still learning",
                             captureElapsedSeconds, h.windowSeconds, h.kept, h.raw,
                             h.maxRRGapSeconds,
                             h.confidencePercent,
                             ready ? String(format: "%.1f", h.rmssd) : "learning",
                             ready ? String(format: "%.1f", h.sdnn) : "learning",
                             ready ? String(format: "%.1f", h.pnn50) : "learning",
                             ready ? String(format: "%.2f", h.lnRMSSD) : "learning",
                             ready ? (h.respiratoryRate.map { String(format: "%.1f/min", $0) } ?? "learning") : "learning")
            let metricSummary: String
            if ready {
                let resp = h.respiratoryRate.map { String(format: "%.1f", $0) } ?? "learning"
                metricSummary = String(format: "rmssd=%.1f sdnn=%.1f pnn50=%.1f lnrmssd=%.2f resp=%@",
                                       h.rmssd, h.sdnn, h.pnn50, h.lnRMSSD, resp)
            } else {
                metricSummary = "rmssd=learning sdnn=learning pnn50=learning lnrmssd=learning resp=learning"
            }
            let reason = finalAbortReason ?? h.readinessReason
            let cleanElapsed = Date().timeIntervalSince(captureCleanWindowStart)
            summaryLogValue = String(format: "ready=%d stop=%@ elapsed=%.0f clean_elapsed=%.0f raw=%d kept=%d rejected_out_of_range=%d rejected_delta_over_20_percent=%d rejected_hr_mismatch=%d interpolated=%d conf=%d window=%.0f max_rr_gap_s=%.1f quality_resets=%d strict_live_rr=%d reason=%@ %@",
                                     ready ? 1 : 0, stopReason, captureElapsedSeconds, cleanElapsed,
                                     h.raw, h.kept,
                                     h.rejectedOutOfRange, h.rejectedDeltaOver20Percent,
                                     h.rejectedHRMismatch,
                                     h.interpolated, h.confidencePercent, h.windowSeconds,
                                     h.maxRRGapSeconds, captureQualityResetCount,
                                     strictLiveRRCapture ? 1 : 0,
                                     reason, metricSummary)
            logRow(kind: "capture_summary", source: "app", opcode: "", len: "",
                   value: summaryLogValue)
        } else {
            ready = false
            summary = String(format: "Still learning · saved %.0fs · waiting for beat-to-beat samples",
                             captureElapsedSeconds)
            let reason = finalAbortReason ?? "no_realtime_rr"
            let cleanElapsed = Date().timeIntervalSince(captureCleanWindowStart)
            summaryLogValue = String(format: "ready=0 stop=%@ elapsed=%.0f clean_elapsed=%.0f quality_resets=%d strict_live_rr=%d reason=%@",
                                     stopReason, captureElapsedSeconds, cleanElapsed,
                                     captureQualityResetCount, strictLiveRRCapture ? 1 : 0, reason)
            logRow(kind: "capture_summary", source: "app", opcode: "", len: "",
                   value: summaryLogValue)
        }
        AtriaDebugLog("ATRIADBG capture_summary %@", summaryLogValue)
        assignIfChanged(\.captureWasValidationReady, ready)
        if let saved = saveCaptureCSV(directory: .documentDirectory) {
            assignIfChanged(\.lastCaptureFile, saved.relativePath)
            AtriaDebugLog("ATRIADBG capture_file path=%@ rows=%d ready=%d",
                  saved.relativePath, currentCapturedRowCount, ready ? 1 : 0)
        } else {
            assignIfChanged(\.lastCaptureFile, "")
            AtriaDebugLog("ATRIADBG capture_file_error rows=%d ready=%d",
                  currentCapturedRowCount, ready ? 1 : 0)
        }
        assignIfChanged(\.captureSummary, summary)
        assignIfChanged(\.isRecording, false)
        captureAbortReason = nil
        resetRRAvailabilityWindow(&captureRRQualityWindow, head: &captureRRQualityWindowHead)
    }

    private func resetRecordingForRRQuality(reason: String,
                                            fraction: Double,
                                            rrFrames: Int,
                                            totalFrames: Int,
                                            maxGap: TimeInterval,
                                            windowSeconds: TimeInterval,
                                            now: Date,
                                            source: String,
                                            rrCount: Int) {
        guard isRecording else { return }
        captureQualityResetCount += 1
        logRow(kind: "capture_quality_reset", source: "app", opcode: "", len: "",
               value: String(format: "reason=%@ reset=%d fraction=%.3f rr_frames=%d total_frames=%d max_rr_gap_s=%.1f window_s=%.0f action=reset_hrv_keep_recording",
                             reason, captureQualityResetCount, fraction, rrFrames,
                             totalFrames, maxGap, windowSeconds))
        AtriaDebugLog("ATRIADBG capture_quality_reset reason=%@ reset=%d fraction=%.3f rr_frames=%d total_frames=%d max_rr_gap_s=%.1f window_s=%.0f action=reset_hrv_keep_recording",
              reason, captureQualityResetCount, fraction, rrFrames, totalFrames,
              maxGap, windowSeconds)
        checkpointCurrentSession(reason: "rr_quality_reset")
        resetHRVWindow(reason: "learning: RR gap reset")
        captureCleanWindowStart = now
        lastRRExportElapsedMS = nil
        resetRRAvailabilityWindow(&captureRRQualityWindow, head: &captureRRQualityWindowHead)
        captureRRQualityWindow.append((t: now, hasRR: rrCount > 0, source: source))
    }

    private func checkpointCurrentSession(reason: String) {
        if powerThermalGovernor.shouldDeferNonEssentialAnalysis {
            lastCanonicalCheckpointAt = Date()
            persistActiveSessionJournalIfNeeded(
                reason: "rr_quality_thermal_heartbeat",
                force: true,
                refreshTimestampIfUnchanged: true
            )
            AtriaDebugLog("ATRIADBG session_checkpoint status=deferred reason=%@ samples=%d rr_samples=%d source=rr_quality mode=%@",
                          reason,
                          session.count,
                          rrArchive.count,
                          effectivePowerThermalMode)
            return
        }
        guard let saved = snapshotSession(label: captureLabel.isEmpty ? "RR checkpoint" : captureLabel) else {
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=%@ samples=%d rr_samples=%d source=rr_quality",
                  reason, session.count, rrArchive.count)
            return
        }
        let checkpointPersisted = onSessionCheckpoint?(saved) == true
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ reason=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f hrv=%@ label=%@ source=rr_quality",
              checkpointPersisted ? "saved" : "store_failed",
              reason,
              saved.points.count,
              saved.rrSampleCount,
              saved.motionHintCountValue,
              saved.motionHintKindsValue,
              saved.motionEvidenceSourceValue,
              saved.motionEvidenceValidatedValue ? 1 : 0,
              saved.hrRaw2A37Value,
              saved.hrAcceptedValue,
              saved.hrZeroValue,
              saved.hrArtifactHeldValue,
              saved.hrArtifactDroppedValue,
              saved.hrRawGapsValue,
              saved.hrAcceptedGapsValue,
              saved.hrMaxRawGapValue,
              saved.hrMaxAcceptedGapValue,
              saved.duration,
              saved.hrv.map(String.init) ?? "learning",
              saved.label)
    }

    private func checkpointFromLiveEventIfNeeded(now: Date) {
        guard longWearModeEnabled else { return }
        guard session.count >= autoSaveMinSamples else { return }
        let checkpointInterval = powerThermalGovernor.shouldDeferNonEssentialAnalysis
            ? Self.thermalJournalCheckpointInterval
            : currentEventDrivenCheckpointInterval()
        guard Self.shouldRunCanonicalCheckpoint(now: now,
                                                lastCheckpointAt: lastCanonicalCheckpointAt,
                                                minimumInterval: checkpointInterval) else {
            return
        }
        if lastCanonicalCheckpointAt == nil,
           now.timeIntervalSince(sessionStart) < checkpointInterval {
            return
        }
        // Memory bounding is essential, not cosmetic: full-protocol overnight wear
        // still receives accepted HR events even when the long-wear supervisor is
        // preserving richer RR capture, so trigger the same retention roll here
        // before another full-session checkpoint snapshot.
        if rollLongWearLiveSessionIfOversized(now: now, reason: "ble_event_retention_roll") {
            lastCanonicalCheckpointAt = now
            return
        }
        if powerThermalGovernor.shouldDeferNonEssentialAnalysis {
            lastCanonicalCheckpointAt = now
            persistActiveSessionJournalIfNeeded(
                reason: "thermal_pressure_ble_event_checkpoint",
                force: true,
                refreshTimestampIfUnchanged: true
            )
            AtriaDebugLog("ATRIADBG session_checkpoint status=deferred reason=thermal_pressure_minimal_journal samples=%d rr_samples=%d source=ble_event mode=%@ interval_s=%.0f",
                  session.count,
                  rrArchive.count,
                  effectivePowerThermalMode,
                  checkpointInterval)
            return
        }
        let label = captureLabel.isEmpty
            ? (foregroundInteractiveMode ? "All-day wear" : "Unattended workout")
            : captureLabel
        guard let saved = snapshotSession(label: label) else {
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=event_snapshot_failed samples=%d rr_samples=%d source=ble_event",
                  session.count, rrArchive.count)
            return
        }

        lastCanonicalCheckpointAt = now
        UserDefaults.standard.set(true, forKey: CheckpointDefaults.armed)
        UserDefaults.standard.set(checkpointInterval, forKey: CheckpointDefaults.interval)
        UserDefaults.standard.set(label, forKey: CheckpointDefaults.label)
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active:
            appState = "active"
        case .inactive:
            appState = "inactive"
        case .background:
            appState = "background"
        @unknown default:
            appState = "unknown"
        }
        UserDefaults.standard.set("ble_event_\(appState)", forKey: CheckpointDefaults.source)
        let checkpointPersisted = onSessionCheckpoint?(saved) == true
        persistActiveSessionJournalIfNeeded(reason: "ble_event_checkpoint", force: true)
        UserDefaults.standard.set(checkpointPersisted ? "saved" : "store_failed", forKey: CheckpointDefaults.lastStatus)
        UserDefaults.standard.set(saved.points.count, forKey: CheckpointDefaults.lastSamples)
        UserDefaults.standard.set(Int(saved.duration.rounded()), forKey: CheckpointDefaults.lastDuration)
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ samples=%d rr_samples=%d hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d hrv=%@ label=%@ mode=upsert source=ble_event app_state=%@ foreground_interactive=%d interval_s=%.0f",
              checkpointPersisted ? "saved" : "store_failed",
              saved.points.count,
              saved.rrSampleCount,
              saved.hrRaw2A37Value,
              saved.hrAcceptedValue,
              saved.hrZeroValue,
              saved.hrArtifactHeldValue,
              saved.hrArtifactDroppedValue,
              saved.hrRawGapsValue,
              saved.hrAcceptedGapsValue,
              saved.hrMaxRawGapValue,
              saved.hrMaxAcceptedGapValue,
              saved.duration,
              saved.avg,
              saved.peak,
              saved.hrv.map(String.init) ?? "learning",
              saved.label,
              appState,
              foregroundInteractiveMode ? 1 : 0,
              checkpointInterval)
    }

    /// Builds the CSV file and returns its URL for sharing/export.
    func exportCSV() -> URL? {
        saveCaptureCSV(base: FileManager.default.temporaryDirectory, relativePrefix: "tmp")?.url
    }

    private func captureFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let label = filenameSafe(captureLabel)
        let readiness = captureWasValidationReady ? "ready" : "learning"
        return "atria-capture-\(df.string(from: captureStart))-\(label)-\(readiness).csv"
    }

    private func saveCaptureCSV(directory: FileManager.SearchPathDirectory) -> (url: URL, relativePath: String)? {
        guard !captureLog.isEmpty else { return nil }
        guard let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("atria-captures", isDirectory: true)
        return saveCaptureCSV(base: folder, relativePrefix: "Documents/atria-captures")
    }

    private func saveCaptureCSV(base folder: URL, relativePrefix: String) -> (url: URL, relativePath: String)? {
        guard !captureLog.isEmpty else { return nil }
        let url = folder.appendingPathComponent(captureFilename())
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try captureLog.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            return (url, "\(relativePrefix)/\(url.lastPathComponent)")
        } catch { return nil }
    }

    private func csvSafe(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }

    private func metaSafe(_ value: String) -> String {
        let collapsed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        let filtered = collapsed.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-._:/".unicodeScalars.contains(scalar) ? Character(scalar) : "_"
        }
        return String(filtered).isEmpty ? "unknown" : String(filtered)
    }

    private func filenameSafe(_ value: String) -> String {
        String(metaSafe(value).prefix(48))
    }

    private func rebuildSessionHeartRateStats() {
        guard !session.isEmpty else {
            sessionMinHeartRate = nil
            sessionMaxHeartRate = nil
            sessionHeartRateTotal = 0
            sessionHeartRateAggregateCount = 0
            sessionHeartRateMean = 0
            sessionHeartRateM2 = 0
            return
        }

        var minRate = Int.max
        var maxRate = Int.min
        var total = 0
        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for sample in session {
            minRate = min(minRate, sample.bpm)
            maxRate = max(maxRate, sample.bpm)
            total += sample.bpm
            count += 1
            let value = Double(sample.bpm)
            let delta = value - mean
            mean += delta / Double(count)
            m2 += delta * (value - mean)
        }
        sessionMinHeartRate = minRate == Int.max ? nil : minRate
        sessionMaxHeartRate = maxRate == Int.min ? nil : maxRate
        sessionHeartRateTotal = total
        sessionHeartRateAggregateCount = count
        sessionHeartRateMean = mean
        sessionHeartRateM2 = m2
    }

    private func recordSessionHeartRateStats(rate: Int) {
        sessionMinHeartRate = min(sessionMinHeartRate ?? rate, rate)
        sessionMaxHeartRate = max(sessionMaxHeartRate ?? rate, rate)
        sessionHeartRateTotal += rate
        sessionHeartRateAggregateCount += 1
        let value = Double(rate)
        let delta = value - sessionHeartRateMean
        sessionHeartRateMean += delta / Double(sessionHeartRateAggregateCount)
        sessionHeartRateM2 += delta * (value - sessionHeartRateMean)
    }

    static func shouldPublishLiveSessionSampleCount(currentCount: Int,
                                                    publishedCount: Int,
                                                    lastPublishedAt: Date?,
                                                    now: Date,
                                                    force: Bool = false) -> Bool {
        if force { return true }
        guard currentCount != publishedCount else { return false }
        if liveSessionSampleCountSemanticThresholds.contains(where: { publishedCount < $0 && currentCount >= $0 }) {
            return true
        }
        if abs(currentCount - publishedCount) >= sessionSampleCountPublishMinimumDelta {
            return true
        }
        guard let lastPublishedAt else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= sessionSampleCountPublishMinimumInterval
    }

    private func publishSessionSampleCountIfNeeded(now: Date = Date(),
                                                   force: Bool = false) {
        let currentCount = session.count
        guard Self.shouldPublishLiveSessionSampleCount(currentCount: currentCount,
                                                       publishedCount: sessionSampleCount,
                                                       lastPublishedAt: lastSessionSampleCountPublishedAt,
                                                       now: now,
                                                       force: force) else { return }
        lastSessionSampleCountPublishedAt = now
        assignIfChanged(\.sessionSampleCount, currentCount)
    }

    private var currentCapturedRowCount: Int {
        max(captureLog.count - 1, 0)
    }

    private func scheduleCapturedRowsFlush() {
        if captureRowsFlushTask == nil {
            captureRowsFlushTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.flushCapturedRows()
                self.captureRowsFlushTask = nil
            }
        } else if currentCapturedRowCount - capturedRows >= 12 {
            flushCapturedRows()
            captureRowsFlushTask?.cancel()
            captureRowsFlushTask = nil
        }
    }

    private func flushCapturedRows() {
        assignIfChanged(\.capturedRows, currentCapturedRowCount)
    }

    private func logRow(kind: String, source: String, opcode: String, len: String, value: String, at eventTime: Date = Date(), elapsedMS: Int? = nil) {
        guard isRecording else { return }
        let ms = elapsedMS ?? Int(eventTime.timeIntervalSince(captureStart) * 1000)
        captureLog.append([
            "\(ms)",
            csvSafe(kind),
            csvSafe(source),
            csvSafe(opcode),
            csvSafe(len),
            csvSafe(captureLabel),
            csvSafe(value)
        ].joined(separator: ","))
        scheduleCapturedRowsFlush()
    }

    private func recordRawHRNotification(hr: Int, at sampleTime: Date) {
        sessionRawHRNotifications += 1
        recordWorkoutPromptQualityEvent(.raw, at: sampleTime)
        sampleDiagnostics.rawNotifications += 1
        let rawCount = sampleDiagnostics.rawNotifications
        if let lastRawHRNotificationAt {
            let gap = sampleTime.timeIntervalSince(lastRawHRNotificationAt)
            if gap > SavedSession.workoutContinuityGapLimit {
                sessionRawHRGaps += 1
                sessionMaxRawHRGap = max(sessionMaxRawHRGap, gap)
                sampleDiagnostics.rawGaps += 1
                sampleDiagnostics.maxRawGap = max(sampleDiagnostics.maxRawGap, gap)
                setSampleDiagnosticsStatus("raw_2a37", reason: "raw_gap")
                AtriaDebugLog("ATRIADBG hr_sample_gap kind=raw_2a37 gap_s=%.1f threshold_s=%.1f raw_notifications=%d accepted=%d action=missing_notification",
                      gap,
                      SavedSession.workoutContinuityGapLimit,
                      rawCount,
                      sampleDiagnostics.acceptedSamples)
            }
        }
        lastRawHRNotificationAt = sampleTime
        scheduleSampleDiagnosticsFlush()
    }

    private func recordAcceptedHRSample(rate: Int, at sampleTime: Date) {
        sessionAcceptedHRSamples += 1
        recordWorkoutPromptQualityEvent(.accepted, at: sampleTime)
        sampleDiagnostics.acceptedSamples += 1
        promoteReconnectBatteryBaselineIfSafe(
            now: sampleTime,
            heartRateReceivedAt: sampleTime,
            reason: "accepted_hr_current_connection"
        )
        publishRecentReconnectBatteryBaselineIfNeeded(now: sampleTime)
        let acceptedCount = sampleDiagnostics.acceptedSamples
        let continuityRelevant = Self.isBLEContinuityRelevant(
            longWearEnabled: longWearModeEnabled,
            activeExplicitWorkout: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        )
        let hadOpenMissingWindow = continuityRelevant && AtriaHistoricalGapLedger.hasOpenWindow()
        let closeMissingWindowResult = hadOpenMissingWindow
            ? AtriaHistoricalGapLedger.closeOpenGapWithResult(
                at: sampleTime,
                minimumDuration: SavedSession.workoutContinuityGapLimit
            )
            : nil
        let closedMissingWindow = closeMissingWindowResult?.closedWindow == true
        if closeMissingWindowResult?.resolvedWindows ?? 0 > 0 {
            _ = reconcileRangeLossBackfillPendingWithArchive(
                reason: "accepted_hr_closed_covered_gap",
                ledgerCoverageResolved: true
            )
        }
        if let lastAcceptedHRAt {
            let gap = sampleTime.timeIntervalSince(lastAcceptedHRAt)
            if gap > SavedSession.workoutContinuityGapLimit {
                sessionAcceptedHRGaps += 1
                recordWorkoutPromptQualityEvent(.acceptedGap(gap), at: sampleTime)
                sessionMaxAcceptedHRGap = max(sessionMaxAcceptedHRGap, gap)
                sampleDiagnostics.acceptedGaps += 1
                sampleDiagnostics.maxAcceptedGap = max(sampleDiagnostics.maxAcceptedGap, gap)
                setSampleDiagnosticsStatus("accepted", reason: "accepted_gap")
                AtriaDebugLog("ATRIADBG hr_sample_gap kind=accepted_hr gap_s=%.1f threshold_s=%.1f accepted=%d raw_notifications=%d rate=%d action=coverage_gap",
                      gap,
                      SavedSession.workoutContinuityGapLimit,
                      acceptedCount,
                      sampleDiagnostics.rawNotifications,
                      rate)
                // A silent/suspended CoreBluetooth link may never produce
                // didDisconnect. Persist the exact consecutive-sample window;
                // when an open disconnect window was just closed, do not add a
                // duplicate interval for the same outage.
                if continuityRelevant, !hadOpenMissingWindow,
                   AtriaHistoricalGapLedger.recordObservedGap(
                    start: lastAcceptedHRAt,
                    end: sampleTime,
                    reason: "accepted_hr_gap",
                    minimumDuration: SavedSession.workoutContinuityGapLimit
                   ) {
                    markRangeLossBackfillRequired(reason: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
                                                  ? "explicit_workout_range_loss"
                                                  : "long_wear_range_loss")
                    scheduleRangeLossBackfillIfNeeded(reason: "accepted_hr_gap")
                } else if closedMissingWindow {
                    AtriaDebugLog("ATRIADBG offline_sync status=missing_window_closed start_unix=%d end_unix=%d action=await_metric_history_coverage",
                                  Int(lastAcceptedHRAt.timeIntervalSince1970),
                                  Int(sampleTime.timeIntervalSince1970))
                }
            }
        } else if continuityRelevant,
                  !hadOpenMissingWindow,
                  AtriaHistoricalGapLedger.recordRestorationGapIfNeeded(
                    firstAcceptedAt: sampleTime,
                    reason: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
                        ? "explicit_workout_process_restore_gap"
                        : "long_wear_process_restore_gap",
                    minimumDuration: SavedSession.workoutContinuityGapLimit
                  ) {
            // CoreBluetooth can deliver this pulse before the asynchronous
            // active-journal restore completes. Preserve the exact timestamp
            // outage for verified strap history rather than silently treating
            // the new process as the beginning of collection.
            markRangeLossBackfillRequired(reason: AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
                                          ? "explicit_workout_range_loss"
                                          : "long_wear_range_loss")
            scheduleRangeLossBackfillIfNeeded(reason: "process_restore_accepted_hr_gap")
        }
        _ = AtriaHistoricalGapLedger.advanceLiveContinuityAnchor(to: sampleTime)
        if sampleDiagnostics.lastReason == "accepted_gap" {
            sampleDiagnostics.lastStatus = "accepted"
            sampleDiagnostics.lastReason = "sample"
        }
        scheduleSampleDiagnosticsFlush()
    }

    fileprivate func record(_ rate: Int, at sampleTime: Date = Date()) {
        // ACCURACY: a 0 means the sensor lost skin contact — don't pollute the
        // series, just flag it.
        guard rate > 0 else {
            sessionZeroHRSamples += 1
            recordWorkoutPromptQualityEvent(.zero, at: sampleTime)
            sampleDiagnostics.zeroSamples += 1
            setSampleDiagnosticsStatus("zero_contact", reason: "hr_zero")
            assignIfChanged(\.hasContact, false)
            contactStableSince = nil
            pendingHRJump = nil
            recentValid.removeAll(keepingCapacity: true)
            // A real zero-contact reading proves the strap was off wrist. Do
            // not carry a pre-contact timestamp across that known-unwearable
            // interval and later request history that cannot contain pulse data.
            AtriaHistoricalGapLedger.clearLiveContinuityAnchor()
            resetHRVWindow(reason: "contact lost")
            logRow(kind: "hr", source: "0x2A37", opcode: "", len: "", value: "0", at: sampleTime)
            return
        }
        guard Self.heartRateIsPhysiologicallyPlausible(rate,
                                                       profileMaxHR: maxHRSetting) else {
            sessionDroppedArtifacts += 1
            recordWorkoutPromptQualityEvent(.droppedArtifact, at: sampleTime)
            sampleDiagnostics.droppedArtifacts += 1
            setSampleDiagnosticsStatus("artifact_drop", reason: "implausible_hr")
            AtriaDebugLog("ATRIADBG hr_artifact action=drop reason=implausible_hr rate=%d hard_upper=%d",
                          rate,
                          Self.heartRateHardUpperBound(profileMaxHR: maxHRSetting))
            logRow(kind: "hr_artifact", source: "0x2A37", opcode: "", len: "", value: "\(rate)", at: sampleTime)
            return
        }
        if !hasContact {
            contactStableSince = sampleTime
            hrvGateWasOpen = false
            pendingHRJump = nil
            recentValid.removeAll(keepingCapacity: true)
            resetHRVWindow(reason: "contact reacquired")
        }
        assignIfChanged(\.hasContact, true)

        // ACCURACY: reject isolated motion artifacts, but do not pin workout HR
        // to an old resting median. A jump is accepted if it repeats or if it is
        // a nearby second reading confirms the new level.
        if let med = median(recentValid), recentValid.count >= 3, abs(rate - med) > Self.workoutHRArtifactJumpBPM {
            let gap = lastAcceptedHRAt.map { sampleTime.timeIntervalSince($0) } ?? 0
            let pendingAge = pendingHRJump.map { sampleTime.timeIntervalSince($0.at) }
            let decision = Self.hrArtifactJumpDecision(rate: rate,
                                                       median: med,
                                                       pendingRate: pendingHRJump?.rate,
                                                       pendingAge: pendingAge,
                                                       acceptedGap: gap)
            if decision.reason == "confirmed_jump", let pending = pendingHRJump {
                pendingHRJump = nil
                AtriaDebugLog("ATRIADBG hr_artifact action=accept reason=confirmed_jump previous=%d rate=%d median=%d gap_s=%.1f", pending.rate, rate, med, gap)
                acceptHeartRate(pending.rate, at: pending.at)
                acceptHeartRate(rate, at: sampleTime)
                return
            }
            pendingHRJump = (rate, sampleTime)
            sessionHeldArtifacts += 1
            recordWorkoutPromptQualityEvent(.heldArtifact, at: sampleTime)
            sampleDiagnostics.heldArtifacts += 1
            setSampleDiagnosticsStatus("artifact_hold", reason: "unconfirmed_jump")
            AtriaDebugLog("ATRIADBG hr_artifact action=hold reason=unconfirmed_jump rate=%d median=%d gap_s=%.1f", rate, med, gap)
            logRow(kind: "hr_artifact", source: "0x2A37", opcode: "", len: "", value: "\(rate)", at: sampleTime)
            return
        }

        if let pending = pendingHRJump {
            sessionDroppedArtifacts += 1
            recordWorkoutPromptQualityEvent(.droppedArtifact, at: sampleTime)
            sampleDiagnostics.droppedArtifacts += 1
            setSampleDiagnosticsStatus("artifact_drop", reason: "not_confirmed")
            AtriaDebugLog("ATRIADBG hr_artifact action=drop reason=not_confirmed previous=%d rate=%d", pending.rate, rate)
            pendingHRJump = nil
        }
        acceptHeartRate(rate, at: sampleTime)
    }

    private func acceptHeartRate(_ rate: Int, at sampleTime: Date) {
        rollActiveSessionAtCivilDayBoundaryIfNeeded(nextSampleTime: sampleTime)
        invalidateActiveSessionJournalRestoreForLiveData()
        let shouldForceFirstJournalSave = longWearModeEnabled && session.isEmpty
        recordAcceptedHRSample(rate: rate, at: sampleTime)
        recentValid.append(rate)
        if recentValid.count > 5 { recentValid.removeFirst() }
        appendLastHeartRate(rate)
        let displayRate = median(recentValid) ?? rate
        // Evaluate the same artifact-filtered, short-median signal shown to the
        // user, not a single raw accepted beat. The lifecycle itself is owned
        // here so background/minimized delivery still produces transitions.
        if let pulses = workoutZoneHapticLifecycle.accept(bpm: displayRate) {
            triggerWorkoutZoneHaptic(pulses: pulses)
        }
        if acceptedHeartRateBatchDepth > 0 {
            acceptedHeartRateBatchPendingDisplayRate = displayRate
            acceptedHeartRateBatchPendingDisplayAt = sampleTime
            acceptedHeartRateBatchPendingDisplayForce = acceptedHeartRateBatchPendingDisplayForce || session.isEmpty
        } else {
            publishLiveHeartDisplayIfNeeded(sampleTime: sampleTime,
                                            displayRate: displayRate,
                                            force: session.isEmpty)
        }
        lastStandardHR = (rate, sampleTime)
        lastAcceptedHRAt = sampleTime
        fireDebugRRPresenceWatchdogIfDue(now: sampleTime, source: "accepted_hr")
        if acceptedHeartRateBatchDepth > 0 {
            acceptedHeartRateBatchPendingConsistencyAt = sampleTime
        } else {
            compareHRChannelsIfPossible(now: sampleTime, source: "2A37")
        }
        session.append(HRSample(t: sampleTime, bpm: rate))
        appendSessionPoint(rate: rate, at: sampleTime)
        recordSessionHeartRateStats(rate: rate)
        publishSessionSampleCountIfNeeded(now: sampleTime)
        logRow(kind: "hr", source: "0x2A37", opcode: "", len: "", value: "\(rate)", at: sampleTime)
        if acceptedHeartRateBatchDepth > 0 {
            acceptedHeartRateBatchNeedsJournalCheck = true
            acceptedHeartRateBatchForceJournalSave = acceptedHeartRateBatchForceJournalSave || shouldForceFirstJournalSave
            acceptedHeartRateBatchLatestCheckpointAt = sampleTime
        } else {
            if shouldForceFirstJournalSave {
                persistActiveSessionJournalIfNeeded(reason: "first_accepted_hr", force: true)
            } else {
                persistActiveSessionJournalIfNeeded(reason: "accepted_hr", force: false)
            }
            checkpointFromLiveEventIfNeeded(now: sampleTime)
        }
    }

    private func beginAcceptedHeartRateBatch() {
        acceptedHeartRateBatchDepth += 1
    }

    private func endAcceptedHeartRateBatch() {
        guard acceptedHeartRateBatchDepth > 0 else { return }
        acceptedHeartRateBatchDepth -= 1
        guard acceptedHeartRateBatchDepth == 0 else { return }
        let checkpointAt = acceptedHeartRateBatchLatestCheckpointAt
        let pendingConsistencyAt = acceptedHeartRateBatchPendingConsistencyAt
        let pendingRRContinuityAt = acceptedHeartRateBatchPendingRRContinuityAt
        let pendingAutoCaptureAt = acceptedHeartRateBatchPendingAutoCaptureAt
        let pendingSegmentRRRecoveryAt = acceptedHeartRateBatchPendingSegmentRRRecoveryAt
        let pendingCurrentRRRecoveryAt = acceptedHeartRateBatchPendingCurrentRRRecoveryAt
        let pendingDisplayRate = acceptedHeartRateBatchPendingDisplayRate
        let pendingDisplayAt = acceptedHeartRateBatchPendingDisplayAt
        let pendingDisplayForce = acceptedHeartRateBatchPendingDisplayForce
        defer {
            acceptedHeartRateBatchNeedsJournalCheck = false
            acceptedHeartRateBatchForceJournalSave = false
            acceptedHeartRateBatchLatestCheckpointAt = nil
            acceptedHeartRateBatchPendingConsistencyAt = nil
            acceptedHeartRateBatchPendingRRContinuityAt = nil
            acceptedHeartRateBatchPendingAutoCaptureAt = nil
            acceptedHeartRateBatchPendingSegmentRRRecoveryAt = nil
            acceptedHeartRateBatchPendingCurrentRRRecoveryAt = nil
            acceptedHeartRateBatchPendingDisplayRate = nil
            acceptedHeartRateBatchPendingDisplayAt = nil
            acceptedHeartRateBatchPendingDisplayForce = false
        }
        if acceptedHeartRateBatchNeedsJournalCheck {
            if acceptedHeartRateBatchForceJournalSave {
                persistActiveSessionJournalIfNeeded(reason: "first_accepted_hr_batch", force: true)
            } else {
                persistActiveSessionJournalIfNeeded(reason: "accepted_hr_batch", force: false)
            }
            if let checkpointAt {
                checkpointFromLiveEventIfNeeded(now: checkpointAt)
            }
        }
        if let now = pendingConsistencyAt {
            compareHRChannelsIfPossible(now: now, source: "2A37")
        }
        if let now = pendingRRContinuityAt {
            publishRRContinuityQuality(now: now)
        }
        if let now = pendingAutoCaptureAt {
            evaluateAdaptiveAutoCapture(now: now)
        }
        if let now = pendingSegmentRRRecoveryAt {
            recoverSegmentHROnlyRRIfNeeded(now: now)
        }
        if let now = pendingCurrentRRRecoveryAt {
            recoverCurrentRRGapIfNeeded(now: now)
        }
        if let displayRate = pendingDisplayRate,
           let displayAt = pendingDisplayAt {
            publishLiveHeartDisplayIfNeeded(sampleTime: displayAt,
                                            displayRate: displayRate,
                                            force: pendingDisplayForce)
        }
    }

    private func publishLiveHeartDisplayIfNeeded(sampleTime: Date,
                                                 displayRate: Int,
                                                 force: Bool = false) {
        let minimumInterval = foregroundInteractiveMode
            ? (foregroundHighFrequencyDisplayMode
                ? Self.liveHeartDisplayMinimumInterval
                : Self.reducedForegroundLiveHeartDisplayMinimumInterval)
            : Self.backgroundLiveHeartDisplayMinimumInterval
        let governedMinimumInterval = minimumInterval * effectiveThermalCadenceMultiplier
        let shouldPublish: Bool
        if force || heartRate == 0 || liveHeartWindow.sparkline.isEmpty {
            shouldPublish = true
        } else if abs(displayRate - heartRate) >= 4 {
            shouldPublish = true
        } else if let lastPublish = lastLiveHeartDisplayPublishAt {
            shouldPublish = sampleTime.timeIntervalSince(lastPublish) >= governedMinimumInterval
        } else {
            shouldPublish = true
        }

        guard shouldPublish else { return }
        lastLiveHeartDisplayPublishAt = sampleTime
        assignIfChanged(\.heartRate, displayRate)
        retryProtectedR10AfterStableHRIfEligible(now: sampleTime)
        // Live HR streaming proves the link is up. Heal ANY non-connected status —
        // including .disconnected after CoreBluetooth state restoration
        // (`ble_restore reuse_restored`), where notifications resume but no
        // didConnect arrives, so the UI showed "Disconnected" while HR/RR data was
        // actively flowing. If we're decoding the strap's HR, we are connected.
        // Only heal to .connected if Bluetooth is on AND the peripheral is actually
        // connected. iOS does not always fire didDisconnect when Bluetooth is turned
        // off, so peripheral.state can be a stale .connected — the `central.state`
        // check is what blocks a queued HR from faking "Live" while Bluetooth is off.
        if displayRate > 0, status != .connected,
           central.state == .poweredOn, peripheral?.state == .connected {
            recomputeConnectionStatus(reason: "event")
        }
        rebuildLiveHeartWindow()
    }

    nonisolated static func hrArtifactJumpDecision(rate: Int,
                                                   median: Int,
                                                   pendingRate: Int?,
                                                   pendingAge: TimeInterval?,
                                                   acceptedGap: TimeInterval) -> (action: String, reason: String) {
        if let pendingRate,
           let pendingAge,
           pendingAge <= workoutHRArtifactConfirmSeconds,
           abs(rate - pendingRate) <= workoutHRArtifactConfirmBPM,
           (rate - median).signum() == (pendingRate - median).signum() {
            return ("accept", "confirmed_jump")
        }
        return ("hold", acceptedGap > workoutHRArtifactStaleMedianSeconds
            ? "post_gap_unconfirmed_jump"
            : "unconfirmed_jump")
    }

    private func logHRArtifactPolicySelfTest() {
        let cases: [(name: String, rate: Int, median: Int, pending: Int?, pendingAge: TimeInterval?, gap: TimeInterval)] = [
            ("isolated_jump", 145, 90, nil, nil, 1),
            ("confirmed_jump", 148, 90, 145, 2, 2),
            ("stale_gap_jump", 145, 90, nil, nil, 8)
        ]
        for item in cases {
            let decision = Self.hrArtifactJumpDecision(rate: item.rate,
                                                       median: item.median,
                                                       pendingRate: item.pending,
                                                       pendingAge: item.pendingAge,
                                                       acceptedGap: item.gap)
            AtriaDebugLog("ATRIADBG hr_artifact_policy case=%@ action=%@ reason=%@ rate=%d median=%d pending=%@ pending_age_s=%@ accepted_gap_s=%.1f",
                  item.name,
                  decision.action,
                  decision.reason,
                  item.rate,
                  item.median,
                  item.pending.map(String.init) ?? "none",
                  item.pendingAge.map { String(format: "%.1f", $0) } ?? "none",
                  item.gap)
        }
        let now = Date()
        let rrCases = [
            RRInterval(t: now.addingTimeInterval(-4), ms: 800, expectedHR: 75),
            RRInterval(t: now.addingTimeInterval(-3), ms: 805, expectedHR: 75),
            RRInterval(t: now.addingTimeInterval(-2), ms: 317, expectedHR: 75),
            RRInterval(t: now.addingTimeInterval(-1), ms: 795, expectedHR: 75)
        ]
        if let snapshot = HRVAnalyzer.analyze(rrCases, now: now).0 {
            AtriaDebugLog("ATRIADBG hrv_artifact_policy case=rr_hr_mismatch raw=%d kept=%d rejected_out_of_range=%d rejected_delta_over_20_percent=%d rejected_hr_mismatch=%d expected_rejected_hr_mismatch=1 confidence=%d ready=%d rule=drop_rr_when_implied_bpm_diff_gt_%d",
                  snapshot.raw,
                  snapshot.kept,
                  snapshot.rejectedOutOfRange,
                  snapshot.rejectedDeltaOver20Percent,
                  snapshot.rejectedHRMismatch,
                  snapshot.confidencePercent,
                  snapshot.isReady ? 1 : 0,
                  Int(HRVSnapshot.maxRRImpliedHRMismatchBPM.rounded()))
        } else {
            AtriaDebugLog("ATRIADBG hrv_artifact_policy case=rr_hr_mismatch status=failed reason=no_snapshot")
        }
    }

    fileprivate func recordHeartRateMeasurement(_ data: Data) {
        let parsed = Self.parseHeartRatePacket(data)
        recordHeartRateMeasurement(parsed, rawData: data)
    }

    private func recordHeartRateMeasurement(_ measurement: ParsedHeartRatePacket?, rawData data: Data) {
        let frameTime = measurement?.frameTime ?? Date()
        let payloadLogBudget = standardHRPayloadLogBudget(now: frameTime)
        guard let measurement else {
            if let suppressed = payloadLogBudget {
                AtriaDebugLog("ATRIADBG standardHR payload=%@ parse=failed suppressed_since_last=%d",
                      Self.hex([UInt8](data)),
                      suppressed)
            }
            return
        }

        if let suppressed = payloadLogBudget {
            AtriaDebugLog("ATRIADBG standardHR payload=%@ hr=%d rrnum=%d truncated=%d rr_ms=%@ suppressed_since_last=%d",
                  Self.hex([UInt8](data)), measurement.hr, measurement.rrValues.count,
                  measurement.truncated ? 1 : 0,
                  Self.joinInts(measurement.rrValues),
                  suppressed)
        }
        standardHRFrames += 1
        recordRawHRNotification(hr: measurement.hr, at: frameTime)
        guard Self.heartRateIsPhysiologicallyPlausible(measurement.hr,
                                                       profileMaxHR: maxHRSetting) else {
            sessionDroppedArtifacts += 1
            sampleDiagnostics.droppedArtifacts += 1
            setSampleDiagnosticsStatus("artifact_drop", reason: "implausible_hr")
            AtriaDebugLog("ATRIADBG hr_artifact action=drop reason=implausible_hr rate=%d hard_upper=%d",
                          measurement.hr,
                          Self.heartRateHardUpperBound(profileMaxHR: maxHRSetting))
            logRow(kind: "hr_artifact", source: "0x2A37", opcode: "", len: "", value: "\(measurement.hr)", at: frameTime)
            return
        }
        rollActiveSessionAfterLongGapIfNeeded(nextSampleTime: frameTime, reason: "standard_hr_gap")
        record(measurement.hr, at: frameTime)

        guard !measurement.rrValues.isEmpty else {
            if acceptedHeartRateBatchDepth > 0 {
                acceptedHeartRateBatchPendingSegmentRRRecoveryAt = frameTime
                acceptedHeartRateBatchPendingCurrentRRRecoveryAt = frameTime
            } else {
                recoverSegmentHROnlyRRIfNeeded(now: frameTime)
                recoverCurrentRRGapIfNeeded(now: frameTime)
            }
            return
        }
        segmentHROnlyRRRecoveryCount = 0
        lastSegmentHROnlyRRRecoveryAt = nil
        currentRRGapRecoveryCount = 0
        lastCurrentRRGapRecoveryAt = nil
        let firstStandardRR = decodedStandardRRValues == 0
        decodedStandardRRValues += measurement.rrValues.count
        lastStandardRRAt = frameTime
        if firstStandardRR {
            // Once standard BLE R-R is proven live, old 0x28 zero-RR events are
            // diagnostic noise, not evidence against the R-R stream.
            removeRRAvailabilityWindowEntries(&rrContinuityWindow,
                                              head: &rrContinuityWindowHead) {
                !$0.hasRR && $0.source == "0x28"
            }
            removeRRAvailabilityWindowEntries(&captureRRQualityWindow,
                                              head: &captureRRQualityWindowHead) {
                !$0.hasRR && $0.source == "0x28"
            }
            removeRRAvailabilityWindowEntries(&autoCaptureRRWindow,
                                              head: &autoCaptureRRWindowHead) {
                !$0.hasRR && $0.source == "0x28"
            }
        }
        if autoCapturePending, autoCaptureRRThreshold > 0,
           appendAdaptiveAutoCaptureObservation(now: frameTime,
                                               rrnum: measurement.rrValues.count,
                                               source: "0x2A37") {
            if acceptedHeartRateBatchDepth > 0 {
                acceptedHeartRateBatchPendingAutoCaptureAt = frameTime
            } else {
                evaluateAdaptiveAutoCapture(now: frameTime)
            }
        }
        addRRBatch(intervalsMS: measurement.rrValues,
                   endingAt: frameTime,
                   source: "0x2A37",
                   opcode: "2A37",
                   expectedHR: measurement.hr)
        if appendRRContinuityObservation(now: frameTime,
                                         rrCount: measurement.rrValues.count,
                                         source: "0x2A37") {
            if acceptedHeartRateBatchDepth > 0 {
                acceptedHeartRateBatchPendingRRContinuityAt = frameTime
            } else {
                publishRRContinuityQuality(now: frameTime)
            }
        }

        if verboseBLEFrameLogging {
            let impliedBPM = measurement.rrValues.map { rr in
                rr > 0 ? String(format: "%.0f", 60000.0 / Double(rr)) : "inf"
            }.joined(separator: ",")
            let hrMismatch = measurement.rrValues.filter { rr in
                guard rr > 0 else { return true }
                return abs((60000.0 / Double(rr)) - Double(measurement.hr)) > 30
            }.count
            AtriaDebugLog("ATRIADBG rr source=0x2A37 hr=%d rrnum=%d decoded=%d total_decoded=%d truncated=%d hr_mismatch=%d implied_bpm=%@ values=%@",
                  measurement.hr, measurement.rrValues.count, measurement.rrValues.count,
                  decodedStandardRRValues, measurement.truncated ? 1 : 0, hrMismatch, impliedBPM,
                  Self.joinInts(measurement.rrValues))
        }
    }

    private func recoverSegmentHROnlyRRIfNeeded(now: Date) {
        guard longWearModeEnabled, standardHROnlyMode else { return }
        guard status == .connected else { return }
        guard rrArchive.isEmpty else { return }
        guard session.count >= autoSaveMinSamples,
              let firstSample = session.first?.t,
              let lastAcceptedHRAt else { return }
        let timeout: TimeInterval = 12
        let segmentAge = now.timeIntervalSince(firstSample)
        guard segmentAge >= timeout else { return }
        let acceptedGap = now.timeIntervalSince(lastAcceptedHRAt)
        guard acceptedGap <= 5 else { return }
        if let lastSegmentHROnlyRRRecoveryAt,
           now.timeIntervalSince(lastSegmentHROnlyRRRecoveryAt) < timeout {
            return
        }
        segmentHROnlyRRRecoveryCount += 1
        lastSegmentHROnlyRRRecoveryAt = now
        recoverRRPresenceWatchdog(label: captureLabel.isEmpty ? "All-day wear" : captureLabel,
                                  status: "segment_hr_only",
                                  rrGap: segmentAge,
                                  acceptedGap: acceptedGap,
                                  timeout: timeout,
                                  consecutive: segmentHROnlyRRRecoveryCount)
    }

    private func recoverCurrentRRGapIfNeeded(now: Date) {
        guard longWearModeEnabled, standardHROnlyMode else { return }
        guard status == .connected else { return }
        guard !rrArchive.isEmpty else { return }
        guard session.count >= autoSaveMinSamples,
              let lastStandardRRAt,
              let lastAcceptedHRAt else { return }
        let timeout: TimeInterval = 30
        let rrGap = now.timeIntervalSince(lastStandardRRAt)
        guard rrGap >= timeout else { return }
        let acceptedGap = now.timeIntervalSince(lastAcceptedHRAt)
        guard acceptedGap <= 5 else { return }
        if let lastCurrentRRGapRecoveryAt,
           now.timeIntervalSince(lastCurrentRRGapRecoveryAt) < 60 {
            return
        }
        currentRRGapRecoveryCount += 1
        lastCurrentRRGapRecoveryAt = now
        recoverRRPresenceWatchdog(label: captureLabel.isEmpty ? "All-day wear" : captureLabel,
                                  status: "current_rr_gap",
                                  rrGap: rrGap,
                                  acceptedGap: acceptedGap,
                                  timeout: timeout,
                                  consecutive: currentRRGapRecoveryCount)
    }

    private func standardHRPayloadLogBudget(now: Date) -> Int? {
        guard livePacketSummaryLoggingEnabled || verboseBLEFrameLogging else { return nil }
        if verboseBLEFrameLogging { return 0 }
        guard standardHROnlyMode else { return nil }
        standardHRPayloadLogCount += 1
        if standardHRPayloadLogCount <= 5 {
            lastStandardHRPayloadLogAt = now
            let suppressed = standardHRPayloadLogSuppressed
            standardHRPayloadLogSuppressed = 0
            return suppressed
        }
        if let lastStandardHRPayloadLogAt,
           now.timeIntervalSince(lastStandardHRPayloadLogAt) < 60 {
            standardHRPayloadLogSuppressed += 1
            return nil
        }
        lastStandardHRPayloadLogAt = now
        let suppressed = standardHRPayloadLogSuppressed
        standardHRPayloadLogSuppressed = 0
        return suppressed
    }

    private func median(_ xs: [Int]) -> Int? {
        guard !xs.isEmpty else { return nil }
        switch xs.count {
        case 1:
            return xs[0]
        case 2:
            return max(xs[0], xs[1])
        case 3:
            let a = xs[0]
            let b = xs[1]
            let c = xs[2]
            if a < b {
                if b < c { return b }
                return max(a, c)
            }
            if a < c { return a }
            return max(b, c)
        case 4:
            var a = xs[0]
            var b = xs[1]
            var c = xs[2]
            var d = xs[3]
            if a > b { swap(&a, &b) }
            if c > d { swap(&c, &d) }
            if a > c {
                swap(&a, &c)
                swap(&b, &d)
            }
            if b > c { swap(&b, &c) }
            if c > d { swap(&c, &d) }
            return c
        case 5:
            var a = xs[0]
            var b = xs[1]
            var c = xs[2]
            var d = xs[3]
            var e = xs[4]
            if a > b { swap(&a, &b) }
            if c > d { swap(&c, &d) }
            if a > c {
                swap(&a, &c)
                swap(&b, &d)
            }
            if b > e { swap(&b, &e) }
            if b > c { swap(&b, &c) }
            if d > e { swap(&d, &e) }
            if c > d { swap(&c, &d) }
            if b > c { swap(&b, &c) }
            return c
        default:
            let s = xs.sorted()
            return s[s.count / 2]
        }
    }

    private static func parseHexBytes(_ raw: String) -> [UInt8]? {
        let cleaned = raw
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "[^0-9a-fA-F]", with: "", options: .regularExpression)
        guard cleaned.count >= 2, cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let value = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(value)
            index = next
        }
        return bytes
    }

    private nonisolated static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func documentsRelativePath(for url: URL) -> String {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return url.lastPathComponent
        }
        let documentPath = documents.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath == documentPath { return "Documents" }
        if filePath.hasPrefix(documentPath + "/") {
            return "Documents/" + String(filePath.dropFirst(documentPath.count + 1))
        }
        return url.lastPathComponent
    }

    private static func packetKind(_ type: UInt8) -> String {
        switch type {
        case Packet.command: return "command"
        case 0x24: return "command_response"
        case Packet.realtime: return "realtime"
        case Packet.realtimeRaw: return "realtime_raw_r10_r11"
        case Packet.historical: return "historical"
        case 0x30: return "event"
        case Packet.metadata: return "metadata"
        case 0x32: return "diagnostic"
        case Packet.imu: return "imu"
        default: return String(format: "unknown_%02x", type)
        }
    }

    private static func printableRuns(in bytes: [UInt8], minimumLength: Int = 4) -> [String] {
        var runs: [String] = []
        var current: [UInt8] = []
        func flush() {
            defer { current.removeAll() }
            guard current.count >= minimumLength,
                  let string = String(bytes: current, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else { return }
            runs.append(string)
        }
        for byte in bytes {
            if byte == 0x0a || byte == 0x0d || (byte >= 0x20 && byte <= 0x7e) {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    private static func firstRegexCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    private static func diagnosticSleepMotionHint(from text: String) -> (kind: String, motionShort: String, stateFrom: String, stateTo: String)? {
        let upper = text.uppercased()
        let mentionsSleepFlag = upper.contains("SLEEPFLAG") || upper.contains("LEEPFLAG")
        let mentionsMotion = upper.contains("MOTION_SHORT")
        let mentionsDeepSleep = upper.contains("DEEPSLEEP")
        guard mentionsSleepFlag || mentionsMotion || mentionsDeepSleep else { return nil }

        let stateFrom = firstRegexCapture("from state '([A-Z_]+)'", in: text) ?? "unknown"
        let stateTo = firstRegexCapture("to '([A-Z_]+)'", in: text) ?? "unknown"
        let motionShort = firstRegexCapture("motion_short\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)", in: text) ?? "learning"
        let kind: String
        if mentionsSleepFlag {
            kind = "sleepflag"
        } else if mentionsMotion {
            kind = "motion_short"
        } else {
            kind = "deepsleep"
        }
        return (kind, motionShort, stateFrom, stateTo)
    }

    private static func formatDouble(_ value: Double?) -> String {
        value.map { String(format: "%.3f", $0) } ?? "learning"
    }

    private static func formatKindCounts(_ counts: [String: Int]) -> String {
        let parts = counts.keys.sorted().map { key in
            "\(key):\(counts[key] ?? 0)"
        }
        return parts.isEmpty ? "none" : parts.joined(separator: ",")
    }

    private nonisolated static func u16le(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        guard offset + 1 < bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private nonisolated static func u32le(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ]
    }

    private static func unixCandidateLabel(_ value: UInt32) -> String {
        guard value >= 1_500_000_000 && value <= 2_200_000_000 else { return "" }
        return String(format: ":unix:%@", Date(timeIntervalSince1970: TimeInterval(value)).ISO8601Format())
    }

    private func logDataRangeCommandResponse(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[0] == 0x24, payload[2] == 0x22 else { return }
        let seq = payload[1]
        let status = Array(payload.dropFirst(3))
        let body = status.count >= 3 ? Array(status.dropFirst(3)) : []
        let request = historyDataRangePendingRequests.isEmpty
            ? nil
            : historyDataRangePendingRequests.removeFirst()
        var u32Pairs: [String] = []
        if body.count >= 4 {
            for offset in stride(from: 0, through: body.count - 4, by: 2) {
                let value = Self.u32le(body, offset)
                u32Pairs.append("\(offset):\(value)\(Self.unixCandidateLabel(value))")
            }
        }
        var u16Pairs: [String] = []
        if body.count >= 2 {
            for offset in stride(from: 0, through: body.count - 2, by: 2) {
                u16Pairs.append("\(offset):\(Self.u16le(body, offset))")
            }
        }
        AtriaDebugLog("ATRIADBG data_range_response validated=0 seq=%d request_index=%d request_data=%@ status_len=%d lead=%@ body_len=%d u32=%@ u16=%@ last_realtime_unix=%@ device_unix=%.0f status=%@",
              Int(seq),
              request?.index ?? -1,
              request.map { Self.hex($0.data) } ?? "unknown",
              status.count,
              Self.hex(Array(status.prefix(3))),
              body.count,
              u32Pairs.joined(separator: ","),
              u16Pairs.joined(separator: ","),
              lastRealtimeUnix.map(String.init) ?? "none",
              Date().timeIntervalSince1970,
              Self.hex(status))
        maybeSendHistorySelectorSweep(body: body,
                                      requestIndex: request?.index,
                                      requestData: request?.data)
    }

    private func handleCommandResponsePayload(_ payload: [UInt8]) {
        guard payload.first == 0x24 else { return }
        handleProprietaryBatteryCommandResponse(payload)
        logClockCommandResponse(payload)
        logDataRangeCommandResponse(payload)
    }

    private func logClockCommandResponse(_ payload: [UInt8]) {
        guard payload.count >= 3, payload[0] == 0x24 else { return }
        let seq = payload[1]
        let cmd = payload[2]
        guard cmd == Cmd.setClock || cmd == Cmd.getClock else { return }
        let status = Array(payload.dropFirst(3))
        var u32Pairs: [String] = []
        for offset in stride(from: 3, through: max(3, payload.count - 4), by: 1) {
            guard offset + 3 < payload.count else { continue }
            let value = Self.u32le(payload, offset)
            u32Pairs.append("\(offset):\(value)\(Self.unixCandidateLabel(value))")
        }
        if cmd == Cmd.getClock, payload.count >= 9 {
            let device = Self.u32le(payload, 5)
            let wall = UInt32(Date().timeIntervalSince1970)
            if device > 0 {
                historyClockRef = HistoryClockRef(device: device, wall: wall)
            }
            let drift = Int(wall) - Int(device)
            let stale = abs(drift) >= 86_400
            AtriaDebugLog("ATRIADBG historyClock status=get_clock_response seq=%d device=%u wall=%u drift_s=%d stale=%d status_len=%d u32=%@ payload=%@",
                  Int(seq),
                  device,
                  wall,
                  drift,
                  stale ? 1 : 0,
                  status.count,
                  u32Pairs.joined(separator: ","),
                  Self.hex(payload))
        } else {
            AtriaDebugLog("ATRIADBG historyClock status=set_clock_response seq=%d status_len=%d u32=%@ payload=%@",
                  Int(seq),
                  status.count,
                  u32Pairs.joined(separator: ","),
                  Self.hex(payload))
        }
    }

    private func maybeSendHistorySelectorSweep(body: [UInt8], requestIndex: Int?, requestData: [UInt8]?) {
        guard historySelectorSweepEnabled, !historySelectorSweepSent else { return }
        if let requiredIndex = historySelectorRangeIndex,
           requestIndex != requiredIndex {
            AtriaDebugLog("ATRIADBG historySelector validated=0 status=skip reason=range_index_mismatch required=%d request_index=%d request_data=%@ mode=%@",
                  requiredIndex,
                  requestIndex ?? -1,
                  requestData.map { Self.hex($0) } ?? "unknown",
                  historySelectorMode)
            return
        }
        guard let target = closestDataRangeUnixCandidate(body: body) else {
            AtriaDebugLog("ATRIADBG historySelector validated=0 status=skip reason=no_live_unix_candidate request_index=%d request_data=%@ mode=%@",
                  requestIndex ?? -1,
                  requestData.map { Self.hex($0) } ?? "unknown",
                  historySelectorMode)
            return
        }
        historySelectorSweepSent = true
        let live = lastRealtimeUnix
        let delta = live.map { Int64(target.value) - Int64($0) } ?? 0
        let selectors = historySelectors(for: target.value, body: body)
        AtriaDebugLog("ATRIADBG historySelector validated=0 status=scheduled mode=%@ source=cmd22 request_index=%d request_data=%@ offset=%d value=%u live_unix=%@ delta_s=%lld variants=%d",
              historySelectorMode,
              requestIndex ?? -1,
              requestData.map { Self.hex($0) } ?? "unknown",
              target.offset,
              target.value,
              live.map(String.init) ?? "none",
              delta,
              selectors.count)
        Task { @MainActor in
            for (index, selector) in selectors.enumerated() {
                AtriaDebugLog("ATRIADBG historySelector validated=0 step=%d send cmd=21 label=%@ source=cmd22 offset=%d value=%u data=%@ mode=%@",
                      index,
                      selector.label,
                      target.offset,
                      target.value,
                      Self.hex(selector.data),
                      probeCommandMode.rawValue)
                sendCommand(0x21, selector.data, mode: probeCommandMode)
                try? await Task.sleep(for: .seconds(5))
                AtriaDebugLog("ATRIADBG historySelector validated=0 step=%d send cmd=16 label=%@ data=00 mode=%@",
                      index,
                      selector.label,
                      probeCommandMode.rawValue)
                sendCommand(0x16, [0x00], mode: probeCommandMode)
                if index < selectors.count - 1 {
                    try? await Task.sleep(for: .seconds(25))
                }
            }
        }
    }

    private func closestDataRangeUnixCandidate(body: [UInt8]) -> (offset: Int, value: UInt32)? {
        guard body.count >= 4 else { return nil }
        let reference = lastRealtimeUnix ?? UInt32(Date().timeIntervalSince1970)
        var best: (offset: Int, value: UInt32, delta: UInt32)?
        for offset in stride(from: 0, through: body.count - 4, by: 2) {
            let value = Self.u32le(body, offset)
            guard value >= 1_500_000_000 && value <= 2_200_000_000 else { continue }
            let delta = value > reference ? value - reference : reference - value
            guard delta <= 86_400 * 14 else { continue }
            if best == nil || delta < best!.delta {
                best = (offset, value, delta)
            }
        }
        return best.map { ($0.offset, $0.value) }
    }

    private func historyRecord(body: [UInt8], offset: Int, length: Int) -> [UInt8]? {
        guard offset >= 0, length > 0, offset + length <= body.count else { return nil }
        return Array(body[offset..<(offset + length)])
    }

    private func historySelectors(for unix: UInt32, body: [UInt8]) -> [(label: String, data: [UInt8])] {
        let bare = Self.le32(unix)
        let currentRecord = historyRecord(body: body, offset: 56, length: 8)
        let knownBlockRecord = historyRecord(body: body, offset: 40, length: 8)
        let rangeWindow = historyRecord(body: body, offset: 40, length: 24)
        switch historySelectorMode {
        case "current-unix-prefix0":
            return [("current_unix_prefix0", [0x00] + bare)]
        case "current-unix-prefix1":
            return [("current_unix_prefix1", [0x01] + bare)]
        case "current-unix-all":
            return [
                ("current_unix_bare", bare),
                ("current_unix_prefix0", [0x00] + bare),
                ("current_unix_prefix1", [0x01] + bare),
            ]
        case "current-record8":
            return currentRecord.map { [("current_record8", $0)] } ?? []
        case "known-block-record8":
            return knownBlockRecord.map { [("known_block_record8", $0)] } ?? []
        case "range-window24":
            return rangeWindow.map { [("range_window24", $0)] } ?? []
        case "record-shape-all":
            var selectors: [(label: String, data: [UInt8])] = []
            if let knownBlockRecord {
                selectors.append(("known_block_record8", knownBlockRecord))
            }
            if let currentRecord {
                selectors.append(("current_record8", currentRecord))
            }
            if let rangeWindow {
                selectors.append(("range_window24", rangeWindow))
            }
            return selectors
        default:
            return [("current_unix_bare", bare)]
        }
    }

    private func stableContactSeconds(now: Date = Date()) -> TimeInterval {
        guard hasContact, let contactStableSince else { return 0 }
        return now.timeIntervalSince(contactStableSince)
    }

    private func resetHRVWindow(reason: String) {
        hrvLiveRefreshGeneration &+= 1
        hrvLiveRefreshTask?.cancel()
        hrvLiveRefreshTask = nil
        lastHRVAnalysisAttemptAt = nil
        resetRRBuffer()
        rrSamples = 0
        hrv = 0
        assignIfChanged(\.hrvSnapshot, nil)
        tachogram.removeAll(keepingCapacity: true)
        assignIfChanged(\.hrvQuality, reason)
        hrvGateWasOpen = false
        if isRecording {
            captureCleanWindowStart = Date()
        }
        logRow(kind: "hrv_quality", source: "app", opcode: "", len: "", value: reason)
    }

    private func shouldRefreshHRVSnapshot(now: Date, force: Bool = false) -> Bool {
        if powerThermalGovernor.shouldSuspendNonEssentialWork && !force {
            return false
        }
        guard !force else { return true }
        let window = currentRRBufferWindow()
        let cleanWindowSeconds = window.first.map { max(0, now.timeIntervalSince($0.t)) } ?? 0
        return Self.shouldAttemptHRVAnalysis(
            now: now,
            lastReadyAnalysisAt: lastHRVAnalysisAt,
            lastAttemptAt: isRecording
                ? lastHRVAnalysisAttemptAt
                : lastNormalWearHRVAnalysisAttemptAt,
            isRecording: isRecording,
            hasReadySnapshot: latestReadyHRVSnapshot?.isReady == true || hrvSnapshot?.isReady == true,
            cleanWindowSeconds: cleanWindowSeconds,
            foregroundInteractive: foregroundInteractiveMode
        )
    }

    private var shouldMaintainLiveTachogram: Bool {
        foregroundInteractiveMode && isRecording
    }

    // MARK: Command channel + HRV

    private var realtimeRetry: Task<Void, Never>?
    private var realtimeRestartTask: Task<Void, Never>?
    private var r10ArmRetryTask: Task<Void, Never>?
    private var r10LivenessTask: Task<Void, Never>?
    private var lastR10RecoveryRearmAt: Date?
    private var lastR10RecoveryRediscoveryAt: Date?
    private var lastR10NotifyRepairAt: Date?
    nonisolated static let r10RecoveryRediscoveryMinimumInterval: TimeInterval = 60
    nonisolated static let r10LivenessStaleInterval: TimeInterval = 60
    nonisolated static let r10LivenessRearmGraceInterval: TimeInterval = 60
    nonisolated static let r10LivenessRearmMinimumInterval: TimeInterval = 10 * 60
    nonisolated static let r10NotifyRepairMinimumInterval: TimeInterval = 30
    private var lastRRBearingRealtimeFrameAt: Date?
    private var lastRealtimeRestartAt: Date?
    private var ackedHistoryAckKeys = Set<String>()
    private var rrContinuityWindow: [(t: Date, hasRR: Bool, source: String)] = []
    private var rrContinuityWindowHead = 0
    private var lastRRContinuityPublishAt: Date?
    private var lastRRContinuityLogAt: Date?
    private var lastRRContinuityLogState = ""
    private var realtimePacketBatchDepth = 0
    private var realtimeBatchPendingRRContinuityAt: Date?
    private var realtimeBatchPendingAutoCaptureAt: Date?
    private var realtimeBatchPendingConsistencyAt: Date?
    private var realtimeBatchPendingRestart: (now: Date, rrnum: Int)?
    private var realtimeBatchPendingHistorySweepUnix: UInt32?
    private var proprietaryNotifyFallbackTask: Task<Void, Never>?
    private var activeProprietaryNotifyUUIDs = Set<CBUUID>()
    private var strapStream5NotifyConfirmed = false

    /// A cached frame from immediately before a rediscovery/reconnect cannot
    /// prove that the newly armed R10 stream is alive. Requiring the frame to
    /// post-date the current arm prevents the retry loop from accepting stale
    /// motion while HR continues normally and steps remain frozen indefinitely.
    nonisolated static func r10FrameConfirmsCurrentArm(lastFrameAt: Date?,
                                                       armSentAt: Date,
                                                       now: Date,
                                                       maximumAge: TimeInterval = 5) -> Bool {
        guard let lastFrameAt,
              lastFrameAt >= armSentAt,
              now.timeIntervalSince(lastFrameAt) >= 0,
              now.timeIntervalSince(lastFrameAt) <= maximumAge else {
            return false
        }
        return true
    }

    /// Once a decoded R10 frame post-dates this arm command, the arm itself
    /// succeeded. Ongoing freshness is owned by the liveness watchdog.
    nonisolated static func r10FrameProvesCurrentArm(lastFrameAt: Date?,
                                                     evidenceEpoch: Date,
                                                     now: Date = Date()) -> Bool {
        guard let lastFrameAt else { return false }
        return lastFrameAt >= evidenceEpoch && lastFrameAt <= now
    }

    enum R10LivenessAction: Equatable {
        case none
        case rearm
        case rediscover
    }

    /// Pure policy used by the persistent R10 watchdog. Heart-rate continuity
    /// is deliberately absent: 2A37 can remain healthy while proprietary motion
    /// is frozen, which is the failure this policy must detect independently.
    nonisolated static func r10LivenessAction(
        eligible: Bool,
        connected: Bool,
        realtimeArmed: Bool,
        lastFrameAt: Date?,
        lastRearmAt: Date?,
        lastRediscoveryAt: Date?,
        now: Date,
        staleInterval: TimeInterval = r10LivenessStaleInterval,
        rearmGraceInterval: TimeInterval = r10LivenessRearmGraceInterval,
        rearmMinimumInterval: TimeInterval = r10LivenessRearmMinimumInterval,
        rediscoveryMinimumInterval: TimeInterval = r10RecoveryRediscoveryMinimumInterval
    ) -> R10LivenessAction {
        guard eligible, connected, realtimeArmed else { return .none }
        if let lastFrameAt,
           now.timeIntervalSince(lastFrameAt) >= 0,
           now.timeIntervalSince(lastFrameAt) <= staleInterval {
            return .none
        }
        guard let lastRearmAt else { return .rearm }
        let rearmAge = now.timeIntervalSince(lastRearmAt)
        if rearmAge >= rearmMinimumInterval { return .rearm }
        guard rearmAge >= rearmGraceInterval else { return .none }
        if let lastRediscoveryAt,
           now.timeIntervalSince(lastRediscoveryAt) < rediscoveryMinimumInterval {
            return .none
        }
        return .rediscover
    }

    nonisolated static func shouldRepairR10Notification(
        expected: Bool,
        connected: Bool,
        isNotifying: Bool,
        lastRepairAt: Date?,
        now: Date,
        minimumInterval: TimeInterval = r10NotifyRepairMinimumInterval
    ) -> Bool {
        guard expected, connected, !isNotifying else { return false }
        guard let lastRepairAt else { return true }
        return now.timeIntervalSince(lastRepairAt) >= minimumInterval
    }

    /// Send a COMMAND packet on CMD_TO_STRAP: [0x23, seq, cmd, data...].
    private func sendCommand(_ cmd: UInt8, _ data: [UInt8], mode: CommandWriteMode) {
        guard motionHandshakeDiagnostic == nil else {
            recordMotionHandshakeEvidence(event: "proprietary_tx_blocked",
                                          detail: String(format: "cmd_%02x", cmd))
            return
        }
        guard !standardHROnlyMode || historyOnlyProbeEnabled else {
            incrementRadioCounter(RadioDefaults.realtimeStartSkipped, reason: "standard_hr_only_write_blocked")
            AtriaDebugLog("ATRIADBG writeSkip mode=%@ reason=standard_hr_only_no_strap_writes cmd=%02x",
                  mode.rawValue, cmd)
            dbgWrite = "standard hr only blocked"
            return
        }
        guard let tx = txCharacteristic, let p = peripheral else { return }
        let payload = [Packet.command, cmdSeq, cmd] + data
        let seq = cmdSeq
        cmdSeq &+= 1
        let frame = encodeFrame(payload)
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        AtriaDebugLog("ATRIADBG send mode=%@ cmd=%02x seq=%d to=%@ props=%lu frame=%@",
              mode.rawValue, cmd, Int(seq), tx.uuid.uuidString, tx.properties.rawValue, hex)
        switch mode {
        case .withoutResponse:
            guard tx.properties.contains(.writeWithoutResponse) else {
                AtriaDebugLog("ATRIADBG writeSkip mode=wwr reason=unsupported props=%lu", tx.properties.rawValue)
                dbgWrite = "wwr unsupported"
                return
            }
            p.writeValue(frame, for: tx, type: .withoutResponse)
        case .withResponse:
            guard tx.properties.contains(.write) else {
                AtriaDebugLog("ATRIADBG writeSkip mode=wr reason=unsupported props=%lu", tx.properties.rawValue)
                dbgWrite = "wr unsupported"
                return
            }
            p.writeValue(frame, for: tx, type: .withResponse)
        }
        dbgWriteMode = mode.rawValue
        dbgWrite = mode == .withoutResponse ? "sent" : "pending"
        dbgCmdSends += 1
    }

    /// Plays a short, bounded WHOOP 4 haptic pattern for live zone coaching.
    /// Pattern 2 is the same neutral pulse used by the strap's alarm surface;
    /// `loops` maps directly to the requested one/two/three-pulse transition.
    func triggerWorkoutZoneHaptic(pulses: Int) {
        guard (1...3).contains(pulses),
              status == .connected,
              peripheral?.state == .connected,
              txCharacteristic != nil else {
            AtriaDebugLog("ATRIADBG workout_zone_haptic status=skipped pulses=%d reason=strap_not_write_ready", pulses)
            return
        }
        sendCommand(Cmd.runHapticsPattern,
                    [0x02, UInt8(pulses), 0x00, 0x00, 0x00],
                    mode: .withoutResponse)
        AtriaDebugLog("ATRIADBG workout_zone_haptic status=sent pattern=2 pulses=%d", pulses)
    }

    /// Installs or updates the persisted target owned by the current explicit
    /// workout. Repeating an identical configuration preserves detector state;
    /// only a session/target/pause transition establishes a new baseline.
    func configureWorkoutZoneHaptics(workoutStartedAt: Date?,
                                     lowerTargetZone: Int?,
                                     upperTargetZone: Int?,
                                     maxHR: Int,
                                     isPaused: Bool) {
        workoutZoneHapticLifecycle.configure(
            workoutStartedAt: workoutStartedAt,
            lowerTargetZone: lowerTargetZone,
            upperTargetZone: upperTargetZone,
            maxHR: maxHR,
            isPaused: isPaused
        )
    }

    private func stopProtocolHeartbeat() {
        // WHOOP 4 does not require a periodic command-channel heartbeat. Atria
        // briefly sent the unvalidated 0x01/[0x00] command here every five
        // seconds; physical capture showed that the strap then disconnected on
        // a repeatable 16–19 second cycle. Keep the lifecycle hook so existing
        // teardown call sites remain explicit, but never write to the strap.
    }

    private func scheduleProprietaryArmFallbackIfNeeded(reason: String) {
        guard !standardHROnlyMode || historyOnlyProbeEnabled else { return }
        guard txCharacteristic != nil else { return }
        guard !strapStream5NotifyConfirmed else { return }
        guard !activeProprietaryNotifyUUIDs.isEmpty else { return }
        guard !realtimeArmed else { return }
        guard !historyOnlyProbeArmed else { return }
        guard proprietaryNotifyFallbackTask == nil else { return }
        proprietaryNotifyFallbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            defer { proprietaryNotifyFallbackTask = nil }
            guard !Task.isCancelled else { return }
            guard !standardHROnlyMode || historyOnlyProbeEnabled else { return }
            guard txCharacteristic != nil else { return }
            guard !strapStream5NotifyConfirmed else { return }
            guard !activeProprietaryNotifyUUIDs.isEmpty else { return }
            guard !realtimeArmed else { return }
            guard !historyOnlyProbeArmed else { return }
            AtriaDebugLog("ATRIADBG proprietary_arm_fallback status=arming reason=%@ notify_count=%d stream5_confirmed=0 history_only=%d",
                          reason,
                          activeProprietaryNotifyUUIDs.count,
                          historyOnlyProbeEnabled ? 1 : 0)
            armRealtime()
        }
    }

    private func armWhenProprietaryNotifyPairReadyIfNeeded(reason: String) -> Bool {
        guard !standardHROnlyMode || historyOnlyProbeEnabled else { return false }
        guard txCharacteristic != nil else { return false }
        guard activeProprietaryNotifyUUIDs.count >= 2 else { return false }
        guard !realtimeArmed else { return false }
        guard !historyOnlyProbeArmed else { return false }
        guard !strapStream5NotifyConfirmed else { return false }
        AtriaDebugLog("ATRIADBG proprietary_arm_fallback status=arming reason=%@ notify_count=%d stream5_confirmed=0 history_only=%d",
                      reason,
                      activeProprietaryNotifyUUIDs.count,
                      historyOnlyProbeEnabled ? 1 : 0)
        armRealtime()
        return true
    }

    private var realtimeArmed = false

    nonisolated static func shouldArmHighFrequencyMotion(batteryLevel: Int,
                                                         isCharging: Bool,
                                                         calibrationActive: Bool = false) -> Bool {
        // A physical 13% proof delivered R10 frames but dropped the BLE link
        // after roughly twelve seconds. Below the warning boundary, preserving
        // continuous HR/strain is safer than repeatedly destabilizing both
        // streams. Charging or an explicit calibration may deliberately opt in.
        calibrationActive || batteryLevel < 0 || isCharging || batteryLevel > lowBatteryWarningThreshold
    }

    /// The legacy boolean and the typed status can briefly disagree during
    /// CoreBluetooth restoration. Never let a stale `true` bypass the
    /// low-battery HR-protection gate unless the verified status also says the
    /// charger is actively supplying power.
    nonisolated static func hasCredibleChargingForMotion(
        isCharging: Bool,
        chargeStatus: BatteryChargeStatus
    ) -> Bool {
        isCharging && chargeStatus == .charging
    }

    private var motionEligibilityIsCharging: Bool {
        Self.hasCredibleChargingForMotion(isCharging: batteryIsCharging,
                                          chargeStatus: batteryChargeStatus)
    }

    private var stepCalibrationCaptureIsActive: Bool {
        strapStepCalibrationCaptureUntil.map { $0 > Date() } ?? false
    }

    private var r10MotionIsEligible: Bool {
        let motionBattery = motionEligibilityBatteryLevel()
        return !standardHROnlyMode
            && !historyOnlyProbeEnabled
            && Self.shouldArmHighFrequencyMotion(
                batteryLevel: motionBattery,
                isCharging: motionEligibilityIsCharging,
                calibrationActive: stepCalibrationCaptureIsActive
            )
    }

    private var protectedR10MotionIsEligible: Bool {
        let motionBattery = motionEligibilityBatteryLevel()
        return standardHROnlyMode
            && !historyOnlyProbeEnabled
            && !historyOnlyProbeMode
            && !offlineHistoricalSyncInProgress
            && !protectedR10StreamSuppressed
            && !protectedR10RollbackEnabled
            && Self.shouldArmHighFrequencyMotion(
                batteryLevel: motionBattery,
                isCharging: motionEligibilityIsCharging,
                calibrationActive: stepCalibrationCaptureIsActive
            )
    }

    private var r10TransportIsExpected: Bool {
        r10MotionIsEligible || protectedR10MotionIsEligible
    }

    func motionEligibilityBatteryLevel(now: Date = Date()) -> Int {
        let defaults = UserDefaults.standard
        let cachedLevel = defaults.object(forKey: BatteryDefaults.level) as? Int
        let cachedAt = (defaults.object(forKey: BatteryDefaults.at) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        return Self.resolvedMotionBatteryLevel(liveLevel: batteryLevel,
                                               liveAcceptedAt: lastAcceptedBatteryLevelAt,
                                               cachedLevel: cachedLevel,
                                               cachedAt: cachedAt,
                                               now: now)
    }

    nonisolated static func resolvedMotionBatteryLevel(liveLevel: Int,
                                                       liveAcceptedAt: Date?,
                                                       cachedLevel: Int?,
                                                       cachedAt: Date?,
                                                       now: Date) -> Int {
        if (0...100).contains(liveLevel),
           batteryLevelIsFresh(lastAcceptedAt: liveAcceptedAt, now: now) {
            return liveLevel
        }
        if let cachedLevel,
           (0...100).contains(cachedLevel),
           batteryLevelIsFresh(lastAcceptedAt: cachedAt, now: now) {
            return cachedLevel
        }
        // Unknown fails open for motion. Only fresh credible low-battery truth
        // may reduce sensor detail; stale/false low values must not break steps.
        return -1
    }

    private func ensureR10LivenessWatchdog(reason: String) {
        guard r10LivenessTask == nil else { return }
        r10LivenessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            AtriaDebugLog("ATRIADBG r10_watchdog status=armed reason=%@ interval_s=%.0f",
                          reason,
                          Self.r10LivenessStaleInterval)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.r10LivenessStaleInterval))
                guard !Task.isCancelled else { return }
                self.evaluateR10Liveness(now: Date(), reason: "periodic")
            }
        }
    }

    private func stopR10LivenessWatchdog(reason: String) {
        guard r10LivenessTask != nil else { return }
        r10LivenessTask?.cancel()
        r10LivenessTask = nil
        lastR10RecoveryRearmAt = nil
        lastR10NotifyRepairAt = nil
        AtriaDebugLog("ATRIADBG r10_watchdog status=stopped reason=%@", reason)
    }

    private func requestBoundedR10ActivationForSilentStream(now: Date,
                                                             reason: String) {
        guard r10TransportIsExpected,
              strapStream5NotifyConfirmed,
              let peripheral,
              peripheral.state == .connected,
              let stream5 = peripheral.services?
                .first(where: { $0.uuid == Self.UUIDs.strapService })?
                .characteristics?
                .first(where: { $0.uuid == Self.UUIDs.strapStream5 }),
              stream5.isNotifying else {
            reassertR10NotificationIfConnected(reason: "\(reason)_inactive_cccd", now: now)
            return
        }

        if standardHROnlyMode {
            // Reuse the physically bounded protected path: passive grace,
            // persisted command lease, missing-frame rollback and the early-
            // disconnect circuit breaker all remain authoritative.
            protectedR10ActivationGraceTask?.cancel()
            protectedR10ActivationGraceTask = nil
            protectedR10MissingFrameTask?.cancel()
            protectedR10MissingFrameTask = nil
            protectedR10StabilityTask?.cancel()
            protectedR10StabilityTask = nil
            protectedR10ActivationSent = false
            protectedR10ActivationAt = nil
            protectedR10FramesAfterActivation = 0
            sendProtectedR10ActivationIfReady()
            AtriaDebugLog("ATRIADBG r10_watchdog status=repair_scheduled mode=protected reason=%@ action=passive_grace_then_leased_3f01",
                          reason)
            return
        }

        guard let txCharacteristic,
              txCharacteristic.properties.contains(.writeWithoutResponse),
              heartRateCharacteristic?.isNotifying == true else { return }
        let defaults = UserDefaults.standard
        let lastActivationAt = (defaults.object(
            forKey: Self.protectedR10ActivationSentAtKey
        ) as? Double).map(Date.init(timeIntervalSince1970:))
        let leaseDelay = Self.protectedR10ActivationLeaseDelay(
            lastActivationAt: lastActivationAt,
            now: now
        )
        guard leaseDelay <= 0 else {
            AtriaDebugLog("ATRIADBG r10_watchdog status=repair_deferred mode=full_protocol reason=%@ lease_remaining_s=%.0f action=preserve_hr_link",
                          reason,
                          leaseDelay)
            return
        }
        let sequence = cmdSeq
        cmdSeq &+= 1
        let frame = encodeFrame([Packet.command, sequence, Cmd.sendR10R11Realtime, 0x01])
        defaults.set(now.timeIntervalSince1970,
                     forKey: Self.protectedR10ActivationSentAtKey)
        defaults.set(defaults.integer(forKey: Self.protectedR10ActivationCountKey) + 1,
                     forKey: Self.protectedR10ActivationCountKey)
        peripheral.writeValue(frame, for: txCharacteristic, type: .withoutResponse)
        AtriaDebugLog("ATRIADBG r10_watchdog status=repair_sent mode=full_protocol reason=%@ cmd=3f data=01 seq=%d action=single_leased_write_no_reconnect",
                      reason,
                      Int(sequence))
    }

    private func evaluateR10Liveness(now: Date = Date(), reason: String) {
        let connected = status == .connected && peripheral?.state == .connected
        let eligible = r10TransportIsExpected
        if eligible, connected, !strapStream5NotifyConfirmed {
            reassertR10NotificationIfConnected(reason: "\(reason)_stream5_unconfirmed", now: now)
            return
        }
        let action = Self.r10LivenessAction(
            eligible: eligible,
            connected: connected,
            realtimeArmed: strapStream5NotifyConfirmed
                && (realtimeArmed || protectedR10MotionIsEligible),
            lastFrameAt: lastR10MotionFrameAt,
            lastRearmAt: lastR10RecoveryRearmAt,
            lastRediscoveryAt: lastR10RecoveryRediscoveryAt,
            now: now
        )
        switch action {
        case .none:
            break
        case .rearm:
            lastR10RecoveryRearmAt = now
            requestBoundedR10ActivationForSilentStream(now: now, reason: reason)
        case .rediscover:
            lastR10RecoveryRediscoveryAt = now
            // Inspect and repair only a truly inactive CCCD. Never reconnect or
            // toggle a healthy HR/R10 subscription for a missing frame.
            reassertR10NotificationIfConnected(reason: "\(reason)_stale_followup", now: now)
        }
    }

    /// Observe the proprietary stream only after 61080005 notification is
    /// confirmed. Production may send the validated 3F/01 activation only
    /// after passive grace and under the persisted ten-minute lease.
    func armRealtime() {
        proprietaryNotifyFallbackTask?.cancel()
        proprietaryNotifyFallbackTask = nil
        if standardHROnlyMode, !historyOnlyProbeEnabled {
            realtimeOn = false
            incrementRadioCounter(RadioDefaults.realtimeStartSkipped, reason: "standard_hr_only")
            AtriaDebugLog("ATRIADBG realtimeConfig standard_hr_only=1 realtime_start=skipped")
            return
        }
        if historyOnlyProbeEnabled {
            armHistoryOnlyProbe()
            return
        }
        guard !realtimeArmed else { return }
        realtimeArmed = true
        realtimeOn = true
        decodedRealtimeRRValues = 0
        usedRealtimeRRValues = 0
        standardHRFrames = 0
        decodedStandardRRValues = 0
        lastStandardRRAt = nil
        lastRRBearingRealtimeFrameAt = nil
        lastRealtimeRestartAt = nil
        realtimeRetry?.cancel()
        r10ArmRetryTask?.cancel()
        // Include frames delivered by the newly connected notification stream
        // during the TX wait/settle period; subscription alone may resume R10.
        let r10EvidenceEpoch = connectedAt ?? Date()
        realtimeRetry = Task { @MainActor [self] in
            // Wait for discovery, then settle so every notification subscription
            // is live before assessing the passive R10 stream.
            for _ in 0..<25 where txCharacteristic == nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard txCharacteristic != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            let motionBattery = motionEligibilityBatteryLevel()
            guard Self.shouldArmHighFrequencyMotion(batteryLevel: motionBattery,
                                                    isCharging: motionEligibilityIsCharging,
                                                    calibrationActive: stepCalibrationCaptureIsActive) else {
                AtriaDebugLog("ATRIADBG r10_stream status=deferred reason=low_battery_preserve_hr battery=%d charging=0 threshold=%d action=keep_realtime_hr_only",
                              motionBattery,
                              Self.lowBatteryWarningThreshold)
                return
            }
            ensureR10LivenessWatchdog(reason: "full_protocol_arm")
            AtriaDebugLog("ATRIADBG r10_stream status=observe_subscribed_stream command=deferred_until_passive_grace source=standard_hr_stability")
            // Never rediscover or repeatedly write while HR is healthy.
            // Physical WHOOP 4 testing showed repeated intervention can
            // destabilize the link; the fallback below is one persisted,
            // ten-minute-leased 3F/01 only after passive observation fails.
            r10ArmRetryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for attempt in 1...2 {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, self.realtimeArmed else { return }
                    if Self.r10FrameProvesCurrentArm(lastFrameAt: self.lastR10MotionFrameAt,
                                                     evidenceEpoch: r10EvidenceEpoch) {
                        AtriaDebugLog("ATRIADBG r10_stream status=alive retry=%d frames=%d",
                                      attempt - 1,
                                      self.r10MotionFrameCount)
                        return
                    }
                    AtriaDebugLog("ATRIADBG r10_stream status=observe attempt=%d reason=no_r10_frame",
                                  attempt)
                }
                if !Self.r10FrameProvesCurrentArm(lastFrameAt: self.lastR10MotionFrameAt,
                                                  evidenceEpoch: r10EvidenceEpoch) {
                    let recoveryAt = Date()
                    self.lastR10RecoveryRearmAt = recoveryAt
                    AtriaDebugLog("ATRIADBG r10_stream status=unavailable action=request_single_leased_activation")
                    self.requestBoundedR10ActivationForSilentStream(
                        now: recoveryAt,
                        reason: "initial_full_protocol_arm"
                    )
                    return
                }
            }
            if let probeCommand, let command = probeCommand.first {
                let data = Array(probeCommand.dropFirst())
                let delay = probeCommandDelaySeconds
                Task { @MainActor in
                    if delay > 0 {
                        try? await Task.sleep(for: .seconds(delay))
                    }
                    AtriaDebugLog("ATRIADBG probeCommand send cmd=%02x data=%@ delay_s=%.1f mode=%@",
                          command, data.map { String(format: "%02x", $0) }.joined(),
                          delay, probeCommandMode.rawValue)
                    sendCommand(command, data, mode: probeCommandMode)
                }
            }
            if !probeSweepCommands.isEmpty {
                let commands = probeSweepCommands
                let interval = probeSweepIntervalSeconds
                Task { @MainActor in
                    for (index, bytes) in commands.enumerated() {
                        try? await Task.sleep(for: .seconds(interval))
                        guard let command = bytes.first else { continue }
                        let data = Array(bytes.dropFirst())
                        AtriaDebugLog("ATRIADBG probeSweep send index=%d raw=%@ cmd=%02x data=%@ interval_s=%.1f mode=%@",
                              index, Self.hex(bytes), command, Self.hex(data),
                              interval, probeCommandMode.rawValue)
                        sendCommand(command, data, mode: probeCommandMode)
                    }
                }
            }
            for _ in 0..<realtimeStartRetries {
                try? await Task.sleep(for: .seconds(4))
                let rawHRProvesCurrentLink = lastRawHRNotificationAt.map { $0 >= r10EvidenceEpoch } ?? false
                let r10ProvesCurrentLink = Self.r10FrameProvesCurrentArm(
                    lastFrameAt: lastR10MotionFrameAt,
                    evidenceEpoch: r10EvidenceEpoch
                )
                if realtimeRRStreamIsAlive || rawHRProvesCurrentLink || r10ProvesCurrentLink {
                    AtriaDebugLog("ATRIADBG realtimeRetry status=stopped reason=transport_alive standard_hr_frames=%d realtime_frames=%d standard_rr=%d realtime_rr=%d raw_hr=%d r10=%d",
                          standardHRFrames, dbgRealtimeFrames, decodedStandardRRValues, decodedRealtimeRRValues,
                          rawHRProvesCurrentLink ? 1 : 0, r10ProvesCurrentLink ? 1 : 0)
                    break
                }
                AtriaDebugLog("ATRIADBG realtimeRetry status=send_start reason=no_rr_or_realtime_stream standard_hr_frames=%d realtime_frames=%d standard_rr=%d realtime_rr=%d",
                      standardHRFrames, dbgRealtimeFrames, decodedStandardRRValues, decodedRealtimeRRValues)
                break
            }
        }
    }

    private var realtimeRRStreamIsAlive: Bool {
        dbgRealtimeFrames > 0 || decodedStandardRRValues > 0 || decodedRealtimeRRValues > 0
    }

    private func shouldLogVerboseBLEFrame() -> Bool {
        guard verboseBLEFrameLogging else { return false }
        let limit = historyOnlyProbeMode ? 48 : 160
        if verboseBLEFrameLogCount < limit {
            verboseBLEFrameLogCount += 1
            return true
        }
        if !verboseBLEFrameLogSuppressed {
            verboseBLEFrameLogSuppressed = true
            AtriaDebugLog("ATRIADBG ble_frame_logging status=suppressed reason=log_budget_exhausted limit=%d history_probe=%d",
                  limit,
                  historyOnlyProbeMode ? 1 : 0)
        }
        return false
    }

    /// Historical fallback probe: keep live HRV off and ask the strap for its
    /// stored-session range. This keeps history transfer from poisoning a live
    /// RR capture and leaves all historical RR interpretations provisional.
    private func armHistoryOnlyProbe() {
        proprietaryNotifyFallbackTask?.cancel()
        proprietaryNotifyFallbackTask = nil
        guard !historyOnlyProbeArmed else { return }
        historyOnlyProbeArmed = true
        realtimeOn = false
        realtimeRetry?.cancel()
        realtimeRestartTask?.cancel()
        r10ArmRetryTask?.cancel()
        stopR10LivenessWatchdog(reason: "history_only_probe")
        AtriaDebugLog("ATRIADBG historyOnly status=arming realtime_start=skipped")
        Task { @MainActor in
            for _ in 0..<25 where txCharacteristic == nil {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard txCharacteristic != nil else {
                AtriaDebugLog("ATRIADBG historyOnly status=blocked reason=tx_missing")
                return
            }
            try? await Task.sleep(for: .seconds(3))
            if historyClockSyncEnabled {
                sendHistoryClockSync()
                try? await Task.sleep(for: .seconds(2))
            }
            if !historyInitSweepCommands.isEmpty {
                AtriaDebugLog("ATRIADBG historyOnly status=send_init_sweep commands=%d mode=%@",
                      historyInitSweepCommands.count,
                      probeCommandMode.rawValue)
                for (index, command) in historyInitSweepCommands.enumerated() {
                    guard let cmd = command.first else { continue }
                    let data = Array(command.dropFirst())
                    AtriaDebugLog("ATRIADBG historyInitSweep send index=%d cmd=%02x data=%@ mode=%@",
                          index, cmd, Self.hex(data), probeCommandMode.rawValue)
                    sendCommand(cmd, data, mode: probeCommandMode)
                    if index < historyInitSweepCommands.count - 1 {
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
            if historySkipDataRangeRequest {
                AtriaDebugLog("ATRIADBG historyOnly status=skip_data_range reason=history_skip_range")
                return
            }
            if historyDataRangeSweepEnabled {
                let payloads = historyDataRangeSweepPayloads
                AtriaDebugLog("ATRIADBG historyOnly status=send_data_range_sweep cmd=22 payloads=%d selector_sweep=%d mode=%@",
                      payloads.count,
                      historySelectorSweepEnabled ? 1 : 0,
                      historySelectorMode)
                for (index, payload) in payloads.enumerated() {
                    AtriaDebugLog("ATRIADBG historyRangeSweep send index=%d cmd=22 data=%@ mode=%@",
                          index, Self.hex(payload), probeCommandMode.rawValue)
                    sendHistoryDataRange(index: index, data: payload)
                    if index < payloads.count - 1 {
                        try? await Task.sleep(for: .seconds(5))
                    }
                }
            } else {
                AtriaDebugLog("ATRIADBG historyOnly status=send_data_range cmd=22 data=00 selector_sweep=%d mode=%@",
                      historySelectorSweepEnabled ? 1 : 0,
                      historySelectorMode)
                sendHistoryDataRange(index: 0, data: [0x00])
            }
        }
    }

    private func sendHistoryClockSync(now: UInt32 = UInt32(Date().timeIntervalSince1970)) {
        let set8 = Self.le32(now) + [0x00, 0x00, 0x00, 0x00]
        let set9 = set8 + [0x00]
        historyClockRef = nil
        AtriaDebugLog("ATRIADBG historyClock status=send_set_clock forms=8,9 now=%u iso=%@ mode=wr",
              now,
              Date(timeIntervalSince1970: TimeInterval(now)).ISO8601Format())
        sendCommand(Cmd.setClock, set8, mode: .withResponse)
        sendCommand(Cmd.setClock, set9, mode: .withResponse)
        AtriaDebugLog("ATRIADBG historyClock status=send_get_clock payload=empty,00 mode=wr")
        sendCommand(Cmd.getClock, [], mode: .withResponse)
        sendCommand(Cmd.getClock, [0x00], mode: .withResponse)
    }

    private func sendHistoryDataRange(index: Int, data: [UInt8]) {
        historyDataRangePendingRequests.append((index: index, data: data))
        sendCommand(0x22, data, mode: probeCommandMode)
    }

    func stopRealtime() {
        realtimeRetry?.cancel()
        realtimeRestartTask?.cancel()
        r10ArmRetryTask?.cancel()
        stopR10LivenessWatchdog(reason: "stop_realtime")
        stopProtocolHeartbeat()
        realtimeArmed = false
        sendCommand(Cmd.toggleRealtimeHR, [0x00], mode: .withoutResponse)
        realtimeOn = false
    }

    private func beginRealtimePacketBatch() {
        realtimePacketBatchDepth += 1
    }

    private func endRealtimePacketBatch() {
        guard realtimePacketBatchDepth > 0 else { return }
        realtimePacketBatchDepth -= 1
        guard realtimePacketBatchDepth == 0 else { return }
        if let now = realtimeBatchPendingConsistencyAt {
            compareHRChannelsIfPossible(now: now, source: "0x28")
        }
        if let now = realtimeBatchPendingRRContinuityAt {
            publishRRContinuityQuality(now: now)
        }
        if let now = realtimeBatchPendingAutoCaptureAt {
            evaluateAdaptiveAutoCapture(now: now)
        }
        if let restart = realtimeBatchPendingRestart {
            maybeRestartRealtimeAfterZeroRR(now: restart.now, rrnum: restart.rrnum)
        }
        if let realtimeUnix = realtimeBatchPendingHistorySweepUnix, historyRecentSweepEnabled {
            maybeSendRecentHistorySweep(realtimeUnix: realtimeUnix)
        }
        realtimeBatchPendingConsistencyAt = nil
        realtimeBatchPendingRRContinuityAt = nil
        realtimeBatchPendingAutoCaptureAt = nil
        realtimeBatchPendingRestart = nil
        realtimeBatchPendingHistorySweepUnix = nil
    }

    private func maybeRestartRealtimeAfterZeroRR(now: Date, rrnum: Int) {
        let restartThreshold = realtimeRestartAfterZeroRRSeconds
        let reassertThreshold = realtimeReassertStartAfterZeroRRSeconds
        let threshold = restartThreshold > 0 ? restartThreshold : reassertThreshold
        guard threshold > 0, realtimeArmed else { return }
        if rrnum > 0 {
            lastRRBearingRealtimeFrameAt = now
            return
        }
        guard let lastRRBearingRealtimeFrameAt else { return }
        let zeroRRSeconds = now.timeIntervalSince(lastRRBearingRealtimeFrameAt)
        guard zeroRRSeconds >= threshold else { return }
        if let lastRealtimeRestartAt,
           now.timeIntervalSince(lastRealtimeRestartAt) < threshold {
            return
        }
        guard realtimeRestartTask == nil else { return }
        lastRealtimeRestartAt = now
        if restartThreshold > 0 {
            AtriaDebugLog("ATRIADBG realtimeRestart reason=zero_rr gap_s=%.1f threshold_s=%.1f",
                  zeroRRSeconds, restartThreshold)
        } else {
            AtriaDebugLog("ATRIADBG realtimeReassert reason=zero_rr gap_s=%.1f threshold_s=%.1f",
                  zeroRRSeconds, reassertThreshold)
        }
        realtimeRestartTask = Task { @MainActor in
            if restartThreshold > 0 {
                sendCommand(Cmd.toggleRealtimeHR, [0x00], mode: .withoutResponse)
                try? await Task.sleep(for: .milliseconds(500))
            }
            sendCommand(Cmd.toggleRealtimeHR, [0x01], mode: .withoutResponse)
            realtimeRestartTask = nil
        }
    }

    private func shouldTrackRRAvailability(source: String, rrCount: Int) -> Bool {
        if rrCount > 0 { return true }
        return source == "0x28" && decodedStandardRRValues == 0
    }

    private func appendRRContinuityObservation(now: Date, rrCount: Int, source: String) -> Bool {
        guard shouldTrackRRAvailability(source: source, rrCount: rrCount) else { return false }
        if shouldSkipRealtimeZeroRRTracking(now: now,
                                           rrCount: rrCount,
                                           source: source,
                                           lastTrackedAt: &lastRealtimeZeroRRQualityUpdateAt) {
            return false
        }
        rrContinuityWindow.append((t: now, hasRR: rrCount > 0, source: source))
        if isRecording {
            captureRRQualityWindow.append((t: now, hasRR: rrCount > 0, source: source))
        }
        return true
    }

    private func publishRRContinuityQuality(now: Date) {
        if !isRecording, let lastRRContinuityPublishAt {
            let minimumInterval = foregroundInteractiveMode
                ? Self.liveRRContinuityPublishMinimumInterval
                : Self.backgroundRRContinuityPublishMinimumInterval
            if now.timeIntervalSince(lastRRContinuityPublishAt) < minimumInterval * effectiveThermalCadenceMultiplier {
                return
            }
        }
        lastRRContinuityPublishAt = now
        let continuity = pruneRRWindow(&rrContinuityWindow,
                                       head: &rrContinuityWindowHead,
                                       now: now,
                                       maxAge: 300)

        let frames = continuity.frames
        let rrFrames = continuity.rrFrames
        let fraction = continuity.fraction
        let span = continuity.span
        let frameMaxGap = continuity.frameMaxGap
        let beatMaxGap = continuity.firstTimestamp.flatMap { maxRRBeatGap(since: $0, now: now) }
        let maxGap = beatMaxGap ?? frameMaxGap
        let sourceLabel = continuity.sourceLabel
        let state: String
        if frames < 45 || span < 45 {
            state = "learning"
        } else if fraction >= 0.90 && maxGap <= HRVSnapshot.maxReadyRRGapSeconds {
            state = "ready"
        } else {
            state = "poor_contact"
        }

        assignIfChanged(\.rrContinuityFrames, frames)
        assignIfChanged(\.rrContinuityRRFrames, rrFrames)
        assignIfChanged(\.rrContinuityFraction, fraction)
        assignIfChanged(\.rrContinuityMaxGapSeconds, maxGap)
        assignIfChanged(\.rrContinuityState, state)
        assignIfChanged(\.rrContinuityDetail,
                        String(format: "%@ · %@ · RR %.0f%% · gap %.1fs · %d/%d frames",
                               state.replacingOccurrences(of: "_", with: " "),
                               sourceLabel, fraction * 100, maxGap, rrFrames, frames))

        let shouldLog: Bool
        if let lastRRContinuityLogAt {
            let logState = "\(state)-\(sourceLabel)"
            shouldLog = logState != lastRRContinuityLogState || now.timeIntervalSince(lastRRContinuityLogAt) >= 30
        } else {
            shouldLog = true
        }
        if shouldLog {
            lastRRContinuityLogAt = now
            lastRRContinuityLogState = "\(state)-\(sourceLabel)"
            AtriaDebugLog("ATRIADBG rr_quality source=%@ state=%@ fraction=%.3f rr_frames=%d total_frames=%d max_rr_gap_s=%.1f frame_max_rr_gap_s=%.1f beat_timeline=%d window_s=%.0f hrv_state=%@ rr_source_2a37_values=%d rr_source_0x28_decoded_values=%d rr_source_0x28_used_values=%d",
                  sourceLabel, state, fraction, rrFrames, frames,
                  maxGap, frameMaxGap, beatMaxGap == nil ? 0 : 1, min(span, 300),
                  hrvSnapshot?.isReady == true ? "ready" : "learning",
                  decodedStandardRRValues, decodedRealtimeRRValues, usedRealtimeRRValues)
        }
        guard isRecording else { return }
        let capture = pruneRRWindow(&captureRRQualityWindow,
                                    head: &captureRRQualityWindowHead,
                                    now: now,
                                    maxAge: 300,
                                    minimumTime: captureStart)
        let captureFrames = capture.frames
        let captureRRFrames = capture.rrFrames
        let captureFraction = capture.fraction
        let captureFrameMaxGap = capture.frameMaxGap
        let captureBeatMaxGap = maxRRBeatGap(since: captureCleanWindowStart, now: now)
        let captureMaxGap = captureBeatMaxGap ?? captureFrameMaxGap
        let captureSpan = capture.span
        if captureElapsedSeconds >= 45,
           captureFrames >= 45,
           (captureFraction < 0.90 || captureMaxGap > HRVSnapshot.maxReadyRRGapSeconds) {
            let reason = captureFraction < 0.90 ? "rr_fraction_below_0.90" : "rr_gap_over_3s"
            resetRecordingForRRQuality(reason: reason,
                                       fraction: captureFraction,
                                       rrFrames: captureRRFrames,
                                       totalFrames: captureFrames,
                                       maxGap: captureMaxGap,
                                       windowSeconds: captureSpan,
                                       now: now,
                                       source: sourceLabel == "2a37" ? "0x2A37" : "0x28",
                                       rrCount: captureRRFrames)
        }
    }

    private func updateRRContinuityQuality(now: Date, rrCount: Int, source: String) {
        guard appendRRContinuityObservation(now: now, rrCount: rrCount, source: source) else { return }
        if realtimePacketBatchDepth > 0, source == "0x28" {
            realtimeBatchPendingRRContinuityAt = now
            return
        }
        publishRRContinuityQuality(now: now)
    }

    private func maxRRBeatGap(since start: Date, now: Date) -> TimeInterval? {
        if let earliestRecentBeat = recentRRBeatTimes.first, start >= earliestRecentBeat {
            return maxRRBeatGap(inRecentBeatTimesSince: start, now: now)
        }
        return maxRRBeatGap(inArchiveSince: start, now: now)
    }

    private func maxRRBeatGap(inRecentBeatTimesSince start: Date, now: Date) -> TimeInterval? {
        guard !recentRRBeatTimes.isEmpty else { return nil }

        var startIndex = recentRRBeatTimes.count
        for index in stride(from: recentRRBeatTimes.count - 1, through: 0, by: -1) {
            let beatTime = recentRRBeatTimes[index]
            guard beatTime >= start else { break }
            startIndex = index
        }

        guard startIndex < recentRRBeatTimes.count else { return nil }
        let firstBeat = recentRRBeatTimes[startIndex]
        guard firstBeat <= now else { return nil }

        var maxGap = firstBeat.timeIntervalSince(start)
        var previous = firstBeat
        if startIndex + 1 < recentRRBeatTimes.count {
            for index in (startIndex + 1)..<recentRRBeatTimes.count {
                let beatTime = recentRRBeatTimes[index]
                guard beatTime <= now else { break }
                maxGap = max(maxGap, beatTime.timeIntervalSince(previous))
                previous = beatTime
            }
        }
        maxGap = max(maxGap, now.timeIntervalSince(previous))
        return maxGap
    }

    private func maxRRBeatGap(inArchiveSince start: Date, now: Date) -> TimeInterval? {
        guard !rrArchive.isEmpty else { return nil }

        var startIndex = rrArchive.count
        for index in stride(from: rrArchive.count - 1, through: 0, by: -1) {
            let beatTime = rrArchive[index].t
            guard beatTime >= start else { break }
            startIndex = index
        }

        guard startIndex < rrArchive.count else { return nil }
        let firstBeat = rrArchive[startIndex].t
        guard firstBeat <= now else { return nil }

        var maxGap = firstBeat.timeIntervalSince(start)
        var previous = firstBeat
        if startIndex + 1 < rrArchive.count {
            for index in (startIndex + 1)..<rrArchive.count {
                let beatTime = rrArchive[index].t
                guard beatTime <= now else { break }
                maxGap = max(maxGap, beatTime.timeIntervalSince(previous))
                previous = beatTime
            }
        }
        maxGap = max(maxGap, now.timeIntervalSince(previous))
        return maxGap
    }

    /// Decode a proprietary frame; if it's REALTIME_DATA, pull RR intervals (HRV).
    private func handleProprietary(_ data: Data, sourceUUID: CBUUID) {
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0xAA else { return }
        let len = Int(b[1]) | (Int(b[2]) << 8)
        guard b[3] == crc8([b[1], b[2]]), len + 4 <= b.count, len >= 5 else { return }
        let payload = Array(b[4..<len])
        let expectedCRC = crc32(payload)
        let actualCRC = UInt32(b[len])
            | (UInt32(b[len + 1]) << 8)
            | (UInt32(b[len + 2]) << 16)
            | (UInt32(b[len + 3]) << 24)
        guard expectedCRC == actualCRC else {
            AtriaDebugLog("ATRIADBG frameReject reason=crc32_mismatch type=%02x len=%d expected=%08x actual=%08x full=%@",
                  payload.first ?? 0, b.count, expectedCRC, actualCRC, Self.hex(b))
            return
        }
        switch payload.first {
        case 0x24:
            handleCommandResponsePayload(payload)
            handleUnknownProtocolPayload(payload, fullFrame: b, sourceUUID: sourceUUID)
            return
        case Packet.metadata:
            handleHistoryMetadata(payload)
            return
        case Packet.historical:
            handleHistoricalData(payload)
            return
        default:
            break
        }
        guard payload.first == Packet.realtime, payload.count >= 10 else {
            handleUnknownProtocolPayload(payload, fullFrame: b, sourceUUID: sourceUUID)
            return
        }
        // payload: [type, seq, cmd, 5-byte header, HR, rrnum, RR(u16le)...]
        let realtimeUnix = payload.count >= 6 ? Self.u32le(payload, 2) : 0
        if realtimeUnix > 0 {
            lastRealtimeUnix = realtimeUnix
        }
        let hr = Int(payload[8])
        lastRealtimeHR = (hr, Date())
        compareHRChannelsIfPossible(now: lastRealtimeHR?.t ?? Date(), source: "0x28")
        let rrnum = Int(payload[9])
        let rrByteCount = min(max(0, payload.count - 10), rrnum * 2)
        let rrBytes = Array(payload[10..<(10 + rrByteCount)])
        let payloadTail = Array(payload.dropFirst(10 + rrByteCount))
        if verboseBLEFrameLogging {
            AtriaDebugLog("ATRIADBG realtimeFrame hrByte=%d rrnum=%d rrBytes=%@ payloadTail=%@ payload=%@ full=%@",
                  hr, rrnum, Self.hex(rrBytes), Self.hex(payloadTail), Self.hex(payload), Self.hex(b))
        }
        let frameTime = Date()
        let standardRecentlyActive = lastStandardRRAt.map { frameTime.timeIntervalSince($0) <= 2.5 } ?? false
        var decodedRR: [Int] = []
        var truncated = false
        for i in 0..<rrnum {
            let off = 10 + i * 2
            guard off + 1 < payload.count else {
                truncated = true
                break
            }
            let rr = Int(payload[off]) | (Int(payload[off + 1]) << 8)
            decodedRR.append(rr)
        }
        if !decodedRR.isEmpty {
            if !standardRecentlyActive {
                usedRealtimeRRValues += decodedRR.count
                for beat in Self.beatTimesEnding(at: frameTime, intervalsMS: decodedRR) {
                    addRR(Double(beat.rr),
                          at: beat.time,
                          source: "0x28",
                          opcode: "28",
                          expectedHR: nil,
                          triggerRefresh: false)
                }
                requestDeferredHRVSnapshotRefreshIfNeeded(now: frameTime)
            }
        }
        if !standardRecentlyActive {
            updateRRContinuityQuality(now: frameTime, rrCount: rrnum, source: "0x28")
            updateAdaptiveAutoCapture(now: frameTime, rrnum: rrnum, source: "0x28")
        }
        maybeRestartRealtimeAfterZeroRR(now: frameTime, rrnum: rrnum)
        maybeSendRecentHistorySweep(realtimeUnix: realtimeUnix)
        if !decodedRR.isEmpty || truncated {
            decodedRealtimeRRValues += decodedRR.count
            let values = decodedRR.map(String.init).joined(separator: ",")
            let impliedBPM = decodedRR.map { rr in
                rr > 0 ? String(format: "%.0f", 60000.0 / Double(rr)) : "inf"
            }.joined(separator: ",")
            let hrMismatch = decodedRR.filter { rr in
                guard rr > 0 else { return true }
                return abs((60000.0 / Double(rr)) - Double(hr)) > 30
            }.count
            if verboseBLEFrameLogging {
                AtriaDebugLog("ATRIADBG rr source=0x28 used=%d hr=%d rrnum=%d decoded=%d total_decoded=%d total_used=%d truncated=%d hr_mismatch=%d implied_bpm=%@ values=%@",
                      standardRecentlyActive ? 0 : 1,
                      hr, rrnum, decodedRR.count, decodedRealtimeRRValues,
                      usedRealtimeRRValues,
                      truncated ? 1 : 0, hrMismatch, impliedBPM, values)
            }
        }
    }

    private func compareHRChannelsIfPossible(now: Date, source: String) {
        guard hrConsistencyEnabled,
              let standard = lastStandardHR,
              let realtime = lastRealtimeHR else { return }
        let age = abs(standard.t.timeIntervalSince(realtime.t))
        guard age <= 5 else { return }
        let delta = abs(standard.bpm - realtime.bpm)
        hrConsistencyPairs += 1
        hrConsistencyDeltaSum += delta
        hrConsistencyMaxDelta = max(hrConsistencyMaxDelta, delta)
        hrConsistencyRecentDeltas.append(delta)
        if hrConsistencyRecentDeltas.count > 20 { hrConsistencyRecentDeltas.removeFirst() }
        let mean = Double(hrConsistencyDeltaSum) / Double(hrConsistencyPairs)
        let recentMax = hrConsistencyRecentDeltas.max() ?? delta
        let recentMean = Double(hrConsistencyRecentDeltas.reduce(0, +)) / Double(max(1, hrConsistencyRecentDeltas.count))
        let ready = hrConsistencyRecentDeltas.count >= 10 && recentMax <= 2 && recentMean <= 1
        let shouldLog = ready
            || hrConsistencyPairs <= 5
            || hrConsistencyPairs.isMultiple(of: 10)
            || hrConsistencyLastLogAt.map { now.timeIntervalSince($0) >= 10 } ?? true
        guard shouldLog else { return }
        hrConsistencyLastLogAt = now
        AtriaDebugLog("ATRIADBG hr_consistency source=%@ pairs=%d standard_hr=%d realtime_hr=%d delta=%d mean_delta=%.1f max_delta=%d recent_mean_delta=%.1f recent_max_delta=%d pair_age_s=%.1f ready=%d tolerance_bpm=2",
              source,
              hrConsistencyPairs,
              standard.bpm,
              realtime.bpm,
              delta,
              mean,
              hrConsistencyMaxDelta,
              recentMean,
              recentMax,
              age,
              ready ? 1 : 0)
    }

    private func handleUnknownProtocolPayload(_ payload: [UInt8],
                                              fullFrame: [UInt8],
                                              sourceUUID: CBUUID? = nil) {
        guard let type = payload.first else { return }
        let body = Array(payload.dropFirst())
        recordProtocolPacket(type: type, length: payload.count)
        if type == Packet.event,
           let reading = Self.parseBatteryLevelEventFrame(fullFrame) {
                let level = reading.level
                let millivolts = reading.millivolts
                let charging = reading.isCharging
                let eventReceivedAt = Date()
                switch Self.batteryEventAcceptanceDecision(
                    previousLevel: batteryLevel,
                    previousAcceptedAt: lastAcceptedBatteryLevelAt,
                    reading: reading,
                    receivedAt: eventReceivedAt,
                    pending: pendingBatteryDropCandidate,
                    previousIsCached: displayedBatteryLevelIsCached,
                    requiresFreshConfirmation: UserDefaults.standard.bool(
                        forKey: BatteryDefaults.requiresFreshConfirmation
                    ),
                    previousChargeStatus: batteryChargeStatus
                ) {
                case .quarantine(let candidate):
                    pendingBatteryDropCandidate = candidate
                    AtriaDebugLog("ATRIADBG battery source=event_30 status=quarantined level=%d previous=%d confirmations=%d span_s=%.1f mv=%d charging=%d",
                                  level,
                                  batteryLevel,
                                  candidate.confirmations,
                                  candidate.lastSeenAt.timeIntervalSince(candidate.firstSeenAt),
                                  millivolts,
                                  charging ? 1 : 0)
                    scheduleBatteryConfirmationRead(incomingLevel: level)
                    return
                case .accept:
                    break
                }
                batteryConfirmationReadTask?.cancel()
                batteryConfirmationReadTask = nil
                batteryConfirmationReadLevel = nil
                pendingBatteryDropCandidate = nil
                displayedBatteryLevelIsCached = false
                batteryReadingIsRecentBaseline = false
                batteryProjectionRevision &+= 1
                UserDefaults.standard.removeObject(forKey: BatteryDefaults.requiresFreshConfirmation)
                lastAcceptedBatteryLevelAt = eventReceivedAt
                let proposedChargeStatus: BatteryChargeStatus = charging
                    ? (level == 100 ? .full : .charging)
                    : .notCharging
                // Unlike 2A1B, this flag is part of the same CRC-validated event
                // as SOC and plausible cell voltage, so it can originate charge
                // truth without waiting for a second percentage sample.
                let acceptedChargeStatus = proposedChargeStatus
                assignIfChanged(\.batteryLevel, level)
                assignIfChanged(\.batteryIsCharging, acceptedChargeStatus == .charging)
                assignIfChanged(\.batteryChargeStatus, acceptedChargeStatus)
                persistBatteryLevel(level,
                                    source: "live_battery_event",
                                    chargeStatus: acceptedChargeStatus)
                recordBatteryChargeEvidence(acceptedChargeStatus,
                                            reason: "battery_event")
                AtriaDebugLog("ATRIADBG battery source=event_30 status=accepted level=%d mv=%d charging=%d charge_status=%@",
                              level,
                              millivolts,
                              charging ? 1 : 0,
                              acceptedChargeStatus.rawValue)
            return
        }
        if type == Packet.realtimeRaw {
            if payload.count > 1, payload[1] == AtriaR10MotionDecoder.recordType {
                r10MotionFrameCount += 1
                let receivedAt = Date()
                recordValidR10MotionEvidence(receivedAt: receivedAt)
                if let sourceUUID {
                    recordProtectedR10EvidenceMetadataIfNeeded(receivedAt: receivedAt,
                                                               sourceUUID: sourceUUID)
                }
                recordMotionHandshakeR10EvidenceIfNeeded(receivedAt: receivedAt,
                                                         payloadLength: payload.count)
                recordProtectedR10EvidenceIfNeeded(receivedAt: receivedAt)
                markStepCalibrationMotionStreamReady(receivedAt: receivedAt)
            }
            if verboseBLEFrameLogging {
                AtriaDebugLog("ATRIADBG r10_frame record_type=%02x len=%d decoded=%d total=%d",
                              payload.count > 1 ? payload[1] : 0,
                              payload.count,
                              payload.count >= 1_288 ? 1 : 0,
                              r10MotionFrameCount)
            }
            return
        }
        if type == Packet.imu {
            logIMUCandidate(payload: payload)
            return
        }
        if type == 0x32 {
            logDiagnosticPacket(payload: payload, fullFrame: fullFrame)
            return
        }
        if verboseBLEFrameLogging {
            AtriaDebugLog("ATRIADBG protocol_packet type=%02x kind=%@ len=%d body=%@ full=%@",
                  type, Self.packetKind(type), payload.count, Self.hex(body), Self.hex(fullFrame))
        }
    }

    private func recordDecodedR10Metadata(sourceUUID: CBUUID,
                                          payloadLength: Int,
                                          receivedAt: Date) {
        dbgPropFrames += 1
        let type = Packet.realtimeRaw
        let signature = "\(sourceUUID.uuidString.prefix(8).suffix(2)):\(String(format: "%02x", type))"
        if !dbgTypeSet.contains(signature) {
            dbgTypeSet.insert(signature)
            dbgLast = dbgTypeSet.sorted().joined(separator: " ")
        }
        recordProtocolPacket(type: type, length: payloadLength)
        r10MotionFrameCount += 1
        recordValidR10MotionEvidence(receivedAt: receivedAt)
        recordMotionHandshakeR10EvidenceIfNeeded(receivedAt: receivedAt,
                                                 payloadLength: payloadLength)
        recordProtectedR10EvidenceIfNeeded(receivedAt: receivedAt)
        recordProtectedR10EvidenceMetadataIfNeeded(receivedAt: receivedAt,
                                                   sourceUUID: sourceUUID)
        markStepCalibrationMotionStreamReady(receivedAt: receivedAt)
        if verboseBLEFrameLogging {
            AtriaDebugLog("ATRIADBG r10_frame record_type=%02x len=%d decoded=1 total=%d path=fast_metadata",
                          AtriaR10MotionDecoder.recordType,
                          payloadLength,
                          r10MotionFrameCount)
        }
    }

    /// A decoded R10 frame has already passed framing, CRC and fixed-layout
    /// validation. Record that source truth for every radio profile; the old
    /// implementation updated freshness only in the protected-mode branch,
    /// leaving full-protocol counts falsely stale in Home/system surfaces.
    private func recordValidR10MotionEvidence(receivedAt: Date) {
        lastR10MotionFrameAt = receivedAt
        UserDefaults.standard.set(receivedAt.timeIntervalSince1970,
                                  forKey: RadioDefaults.passiveR10LastValidAt)
        assignIfChanged(\.liveStrapMotionCapturedAt, receivedAt)
    }

    private func recordProtectedR10EvidenceMetadataIfNeeded(receivedAt: Date,
                                                            sourceUUID: CBUUID) {
        guard standardHROnlyMode, sourceUUID == UUIDs.strapStream5 else { return }
        let defaults = UserDefaults.standard
        passiveR10FirstFrameTask?.cancel()
        passiveR10FirstFrameTask = nil
        if defaults.object(forKey: RadioDefaults.passiveR10FirstValidAt) == nil {
            defaults.set(receivedAt.timeIntervalSince1970,
                         forKey: RadioDefaults.passiveR10FirstValidAt)
        }
        defaults.set(defaults.integer(forKey: RadioDefaults.passiveR10ValidFrames) + 1,
                     forKey: RadioDefaults.passiveR10ValidFrames)
        defaults.set("receiving_crc_valid", forKey: RadioDefaults.passiveR10Status)
    }

    private func recordMotionHandshakeR10EvidenceIfNeeded(receivedAt: Date,
                                                          payloadLength: Int) {
        guard motionHandshakeDiagnostic != nil else { return }
        let defaults = UserDefaults.standard
        let frames = defaults.integer(forKey: "atria.motionHandshake.r10Frames") + 1
        defaults.set(frames, forKey: "atria.motionHandshake.r10Frames")
        defaults.set(receivedAt.timeIntervalSince1970,
                     forKey: "atria.motionHandshake.lastR10At")
        if defaults.object(forKey: "atria.motionHandshake.firstR10At") == nil {
            defaults.set(receivedAt.timeIntervalSince1970,
                         forKey: "atria.motionHandshake.firstR10At")
            defaults.set(payloadLength,
                         forKey: "atria.motionHandshake.firstR10PayloadLength")
            recordMotionHandshakeEvidence(event: "first_r10_received",
                                          detail: "payload_\(payloadLength)")
        }
    }

    private func recordProtectedR10EvidenceIfNeeded(receivedAt: Date) {
        guard motionHandshakeDiagnostic == nil else { return }
        if !protectedR10ActivationSent,
           Self.protectedR10FrameBelongsToCurrentConnection(lastFrameAt: receivedAt,
                                                            connectedAt: connectedAt) {
            if protectedR10ActivationAt == nil {
                protectedR10ActivationAt = receivedAt
                protectedR10FramesAfterActivation = 0
            }
            protectedR10FramesAfterActivation += 1
            if !UserDefaults.standard.bool(forKey: Self.protectedR10StableTransportKey),
               let passiveEpoch = protectedR10ActivationAt,
               receivedAt.timeIntervalSince(passiveEpoch) >= 85,
               Self.protectedR10StabilityWindowIsProven(
                framesAfterActivation: protectedR10FramesAfterActivation,
                lastFrameAt: receivedAt,
                connectedAt: connectedAt,
                activationAt: passiveEpoch,
                now: receivedAt
               ) {
                UserDefaults.standard.set(true, forKey: Self.protectedR10StableTransportKey)
                UserDefaults.standard.set(receivedAt.timeIntervalSince1970,
                                          forKey: Self.protectedR10StableTransportQualifiedAtKey)
                UserDefaults.standard.set(0, forKey: Self.protectedR10EarlyDisconnectsKey)
                UserDefaults.standard.set(0, forKey: Self.protectedR10RetryCountKey)
                UserDefaults.standard.set(false, forKey: Self.protectedR10RollbackKey)
                UserDefaults.standard.set(false, forKey: Self.protectedR10PassiveReprobePendingKey)
                UserDefaults.standard.set(0, forKey: Self.protectedR10PassiveReprobeFailureCountKey)
                protectedR10PassiveReprobeTimeoutTask?.cancel()
                protectedR10PassiveReprobeTimeoutTask = nil
                AtriaDebugLog("ATRIADBG protected_r10 status=stable_window_complete path=passive duration_s=%.0f frames=%d action=qualify_transport",
                              receivedAt.timeIntervalSince(passiveEpoch),
                              protectedR10FramesAfterActivation)
            }
            protectedR10ActivationGraceTask?.cancel()
            protectedR10ActivationGraceTask = nil
            UserDefaults.standard.set("receiving_crc_valid_passive",
                                      forKey: RadioDefaults.passiveR10Status)
            maybeRequestProprietaryBatteryRefresh(now: receivedAt)
            return
        }
        guard protectedR10ActivationSent else { return }
        protectedR10FramesAfterActivation += 1
        if protectedR10FramesAfterActivation == 1 {
            protectedR10MissingFrameTask?.cancel()
            protectedR10MissingFrameTask = nil
            let defaults = UserDefaults.standard
            defaults.set(receivedAt.timeIntervalSince1970,
                         forKey: Self.protectedR10FirstFrameAtKey)
            defaults.set("receiving_crc_valid", forKey: RadioDefaults.passiveR10Status)
            let latency = protectedR10ActivationAt.map { receivedAt.timeIntervalSince($0) } ?? -1
            AtriaDebugLog("ATRIADBG protected_r10 status=first_frame latency_s=%.3f action=keep_minimal_stream",
                          latency)
        }
        maybeRequestProprietaryBatteryRefresh(now: receivedAt)
    }

    private func maybeRequestProprietaryBatteryRefresh(now: Date) {
        guard Self.proprietaryBatteryRefreshEnabled,
              motionHandshakeDiagnostic == nil,
              !protectedR10RollbackEnabled else { return }
        let defaults = UserDefaults.standard
        let stableTransportProven = defaults.bool(forKey: Self.protectedR10StableTransportKey)
        var qualifiedAt = (defaults.object(forKey: Self.protectedR10StableTransportQualifiedAtKey) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        // V3 may already be physically qualified on an installed build that
        // predates this timestamp. Establish the grace anchor now; never infer
        // that the additional two quiet minutes have already elapsed.
        if stableTransportProven, qualifiedAt == nil {
            defaults.set(now.timeIntervalSince1970,
                         forKey: Self.protectedR10StableTransportQualifiedAtKey)
            qualifiedAt = now
        }
        let lastAttemptAt = (defaults.object(forKey: BatteryDefaults.proprietaryRefreshLastAttemptAt) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let circuitOpenUntil = (defaults.object(forKey: BatteryDefaults.proprietaryRefreshCircuitOpenUntil) as? Double)
            .map(Date.init(timeIntervalSince1970:))
        let requestPending = proprietaryBatteryRefreshPhase != .idle
            || defaults.bool(forKey: BatteryDefaults.proprietaryRefreshPending)
        guard Self.shouldRequestProprietaryBatteryRefresh(
            standardHROnlyMode: standardHROnlyMode,
            stableTransportProven: stableTransportProven,
            connected: status == .connected && peripheral?.state == .connected,
            currentConnectionR10Frames: protectedR10FramesAfterActivation,
            lastR10FrameAt: lastR10MotionFrameAt,
            transportQualifiedAt: qualifiedAt,
            batteryIsFresh: Self.batteryLevelIsFresh(lastAcceptedAt: lastAcceptedBatteryLevelAt,
                                                     now: now),
            activeWorkout: AtriaPendingWorkoutIntent.isActiveForBLEContinuity(),
            historyActive: offlineHistoricalSyncInProgress || historyOnlyProbeEnabled || historyOnlyProbeMode,
            requestPending: requestPending,
            lastAttemptAt: lastAttemptAt,
            circuitOpenUntil: circuitOpenUntil,
            now: now
        ) else { return }
        guard let peripheral,
              let service = peripheral.services?.first(where: { $0.uuid == Self.UUIDs.strapService }),
              let txCharacteristic,
              txCharacteristic.properties.contains(.write) else {
            failProprietaryBatteryRefresh(reason: "missing_service_or_wr_tx", now: now)
            return
        }

        defaults.set(now.timeIntervalSince1970,
                     forKey: BatteryDefaults.proprietaryRefreshLastAttemptAt)
        defaults.set(true, forKey: BatteryDefaults.proprietaryRefreshPending)
        proprietaryBatteryRefreshPhase = .discoveringResponse
        proprietaryBatteryRequestSequence = nil
        proprietaryBatteryResponseCharacteristic = nil
        proprietaryBatteryRefreshEnabledResponseNotify = false
        proprietaryBatteryRefreshTimeoutTask?.cancel()
        proprietaryBatteryRefreshTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.proprietaryBatteryResponseTimeout))
            guard let self, !Task.isCancelled,
                  self.proprietaryBatteryRefreshPhase != .idle else { return }
            self.failProprietaryBatteryRefresh(reason: "response_timeout")
        }
        AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=discovering_rx action=one_shot stable_frames=%d",
                      protectedR10FramesAfterActivation)
        peripheral.discoverCharacteristics([Self.UUIDs.strapRX], for: service)
    }

    private func handleProprietaryBatteryResponseCharacteristic(
        _ characteristic: CBCharacteristic,
        peripheral: CBPeripheral
    ) {
        guard proprietaryBatteryRefreshPhase == .discoveringResponse else { return }
        guard characteristic.uuid == Self.UUIDs.strapRX,
              characteristic.properties.contains(.notify) else {
            failProprietaryBatteryRefresh(reason: "rx_notify_unsupported")
            return
        }
        proprietaryBatteryResponseCharacteristic = characteristic
        if characteristic.isNotifying {
            sendProprietaryBatteryRefreshCommand()
        } else {
            proprietaryBatteryRefreshPhase = .subscribingResponse
            proprietaryBatteryRefreshEnabledResponseNotify = true
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    private func handleProprietaryBatteryResponseNotifyState(
        _ characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard proprietaryBatteryRefreshPhase == .subscribingResponse,
              characteristic.uuid == Self.UUIDs.strapRX else { return }
        guard error == nil, characteristic.isNotifying else {
            failProprietaryBatteryRefresh(reason: "rx_notify_failed")
            return
        }
        sendProprietaryBatteryRefreshCommand()
    }

    private func sendProprietaryBatteryRefreshCommand() {
        guard proprietaryBatteryRefreshPhase == .discoveringResponse
                || proprietaryBatteryRefreshPhase == .subscribingResponse,
              let peripheral,
              peripheral.state == .connected,
              let txCharacteristic,
              txCharacteristic.properties.contains(.write),
              proprietaryBatteryResponseCharacteristic?.isNotifying == true else {
            failProprietaryBatteryRefresh(reason: "command_prerequisite_lost")
            return
        }
        let sequence = cmdSeq
        cmdSeq &+= 1
        proprietaryBatteryRequestSequence = sequence
        proprietaryBatteryRefreshPhase = .awaitingResponse
        let frame = encodeFrame([Packet.command, sequence, Cmd.getBatteryLevel])
        peripheral.writeValue(frame, for: txCharacteristic, type: .withResponse)
        AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=request_sent seq=%d mode=wr action=await_single_response",
                      Int(sequence))
    }

    private func handleProprietaryBatteryCommandResponse(_ payload: [UInt8], receivedAt: Date = Date()) {
        guard proprietaryBatteryRefreshPhase == .awaitingResponse,
              let expectedSequence = proprietaryBatteryRequestSequence,
              payload.count >= 3,
              payload[0] == 0x24,
              payload[2] == Cmd.getBatteryLevel else { return }
        guard let level = Self.parseProprietaryBatteryResponse(payload,
                                                               expectedSequence: expectedSequence) else {
            failProprietaryBatteryRefresh(reason: "malformed_or_mismatched_response", now: receivedAt)
            return
        }
        switch Self.batteryLevelAcceptanceDecision(
            previousLevel: batteryLevel,
            previousAcceptedAt: lastAcceptedBatteryLevelAt,
            incomingLevel: level,
            receivedAt: receivedAt,
            pending: pendingBatteryDropCandidate,
            previousIsCached: displayedBatteryLevelIsCached,
            requiresFreshConfirmation: UserDefaults.standard.bool(
                forKey: BatteryDefaults.requiresFreshConfirmation
            )
        ) {
        case .quarantine(let candidate):
            pendingBatteryDropCandidate = candidate
            AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=quarantined level=%d previous=%d action=no_followup_read",
                          level, batteryLevel)
        case .accept:
            pendingBatteryDropCandidate = nil
            displayedBatteryLevelIsCached = false
            batteryReadingIsRecentBaseline = false
            batteryProjectionRevision &+= 1
            UserDefaults.standard.removeObject(forKey: BatteryDefaults.requiresFreshConfirmation)
            lastAcceptedBatteryLevelAt = receivedAt
            assignIfChanged(\.batteryLevel, level)
            assignIfChanged(\.batteryIsCharging, false)
            assignIfChanged(\.batteryChargeStatus, .levelOnly)
            persistBatteryLevel(level, source: "live_proprietary_1a")
            recordBatteryChargeEvidence(.levelOnly, reason: "proprietary_battery_response")
            AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=accepted level=%d", level)
        }
        finishProprietaryBatteryRefresh(success: true, reason: "response_received", now: receivedAt)
    }

    private func failProprietaryBatteryRefresh(reason: String, now: Date = Date()) {
        if proprietaryBatteryRefreshPhase == .idle,
           !UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending) {
            UserDefaults.standard.set(true, forKey: BatteryDefaults.proprietaryRefreshPending)
        }
        finishProprietaryBatteryRefresh(success: false, reason: reason, now: now)
    }

    private func finishProprietaryBatteryRefresh(success: Bool, reason: String, now: Date) {
        let wasPending = proprietaryBatteryRefreshPhase != .idle
            || UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending)
        guard wasPending else { return }
        let responseCharacteristic = proprietaryBatteryResponseCharacteristic
        let shouldDisableResponseNotify = proprietaryBatteryRefreshEnabledResponseNotify
        proprietaryBatteryRefreshTimeoutTask?.cancel()
        proprietaryBatteryRefreshTimeoutTask = nil
        proprietaryBatteryRefreshPhase = .idle
        proprietaryBatteryRequestSequence = nil
        proprietaryBatteryResponseCharacteristic = nil
        proprietaryBatteryRefreshEnabledResponseNotify = false
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: BatteryDefaults.proprietaryRefreshPending)
        if success {
            defaults.set(now.timeIntervalSince1970,
                         forKey: BatteryDefaults.proprietaryRefreshLastSuccessAt)
            defaults.removeObject(forKey: BatteryDefaults.proprietaryRefreshCircuitOpenUntil)
            defaults.removeObject(forKey: BatteryDefaults.proprietaryRefreshLastFailure)
        } else {
            defaults.set(now.addingTimeInterval(Self.proprietaryBatteryRefreshFailureCircuit).timeIntervalSince1970,
                         forKey: BatteryDefaults.proprietaryRefreshCircuitOpenUntil)
            defaults.set(reason, forKey: BatteryDefaults.proprietaryRefreshLastFailure)
        }
        if shouldDisableResponseNotify,
           let responseCharacteristic,
           responseCharacteristic.isNotifying,
           peripheral?.state == .connected {
            peripheral?.setNotifyValue(false, for: responseCharacteristic)
        }
        AtriaDebugLog("ATRIADBG battery source=proprietary_1a status=%@ reason=%@ action=unsubscribe_no_retry circuit_h=%.0f",
                      success ? "complete" : "failed",
                      reason,
                      success ? 0 : Self.proprietaryBatteryRefreshFailureCircuit / 3600)
    }

    private func markPassiveR10SubscriptionConfirmed() {
        let subscribedAt = Date()
        ensureR10LivenessWatchdog(reason: "protected_stream5_subscribed")
        let defaults = UserDefaults.standard
        defaults.set("subscribed_waiting_for_crc_valid_frame",
                     forKey: RadioDefaults.passiveR10Status)
        defaults.set(subscribedAt.timeIntervalSince1970,
                     forKey: RadioDefaults.passiveR10SubscribedAt)
        assignIfChanged(\.liveStrapStepResearchState, "passive_r10_waiting")
        passiveR10FirstFrameTask?.cancel()
        passiveR10FirstFrameTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, !Task.isCancelled else { return }
            self.passiveR10FirstFrameTask = nil
            let receivedAfterSubscribe = self.lastR10MotionFrameAt.map {
                $0 >= subscribedAt
            } ?? false
            guard !receivedAfterSubscribe else { return }
            defaults.set("subscribed_no_crc_valid_frames",
                         forKey: RadioDefaults.passiveR10Status)
            self.assignIfChanged(\.liveStrapStepResearchState,
                                 "passive_r10_unavailable")
            AtriaDebugLog("ATRIADBG passive_r10 status=unavailable action=preserve_2a37_no_writes_no_reconnect")
        }
        AtriaDebugLog("ATRIADBG passive_r10 status=subscribed source=stream5 hr_source=2a37 writes=0")
    }

    private func markStepCalibrationMotionStreamReady(receivedAt: Date) {
        guard !stepCalibrationMotionStreamReady,
              let armedAt = stepCalibrationCaptureArmedAt,
              receivedAt >= armedAt,
              let captureUntil = strapStepCalibrationCaptureUntil,
              receivedAt < captureUntil else { return }
        stepCalibrationMotionStreamReady = true
        AtriaDebugLog(
            "ATRIADBG strap_step_calibration status=stream_ready fresh_r10_after_arm=1 latency_ms=%.0f",
            receivedAt.timeIntervalSince(armedAt) * 1_000
        )
    }

    private func recordProtocolPacket(type: UInt8, length: Int) {
        protocolPacketCount += 1
        protocolLastPacketType = String(format: "%02x", type)
        protocolLastPacketKind = Self.packetKind(type)
        protocolLastPacketLength = length
        if type == Packet.imu || type == Packet.realtimeRaw {
            protocolIMUFrameCount += 1
        } else if type == 0x32 {
            protocolDiagnosticFrameCount += 1
        } else if type == 0x30 {
            protocolEventFrameCount += 1
        } else {
            protocolUnknownFrameCount += 1
        }

        guard protocolDiagnosticsPersistenceEnabled else { return }
        let defaults = UserDefaults.standard
        defaults.set(protocolPacketCount, forKey: ProtocolDefaults.packets)
        defaults.set(protocolLastPacketType, forKey: ProtocolDefaults.lastPacketType)
        defaults.set(protocolLastPacketKind, forKey: ProtocolDefaults.lastPacketKind)
        defaults.set(protocolLastPacketLength, forKey: ProtocolDefaults.lastPacketLength)
        defaults.set(protocolIMUFrameCount, forKey: ProtocolDefaults.imuFrames)
        defaults.set(protocolDiagnosticFrameCount, forKey: ProtocolDefaults.diagnosticFrames)
        defaults.set(protocolEventFrameCount, forKey: ProtocolDefaults.eventFrames)
        defaults.set(protocolUnknownFrameCount, forKey: ProtocolDefaults.unknownFrames)
    }

    private func logDiagnosticPacket(payload: [UInt8], fullFrame: [UInt8]) {
        let text = Self.printableRuns(in: Array(payload.dropFirst())).joined(separator: " | ")
        if verboseBLEFrameLogging {
            AtriaDebugLog("ATRIADBG diagnostic_text validated=0 len=%d text=%@ payload=%@ full=%@",
                  payload.count, text.isEmpty ? "none" : text, Self.hex(payload), Self.hex(fullFrame))
        }
        if let hint = Self.diagnosticSleepMotionHint(from: text) {
            sleepMotionHintCount += 1
            sleepMotionHintKindCounts[hint.kind, default: 0] += 1
            sleepMotionHintKinds = Self.formatKindCounts(sleepMotionHintKindCounts)
            sleepMotionSource = "diagnostic_observe_only"
            if let motionShort = Double(hint.motionShort) {
                sleepMotionShortValues.append(motionShort)
            }
            let motionShortStats = sleepMotionShortSummary()
            AtriaDebugLog("ATRIADBG sleep_motion_hint validated=0 source=0x32 kind=%@ motion_short=%@ state_from=%@ state_to=%@ motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_threshold=%.1f text=%@ action=observe_only_until_motion_decode_validated",
                  hint.kind,
                  hint.motionShort,
                  hint.stateFrom,
                  hint.stateTo,
                  motionShortStats.count,
                  Self.formatDouble(motionShortStats.mean),
                  Self.formatDouble(motionShortStats.min),
                  Self.formatDouble(motionShortStats.max),
                  motionShortStats.overOne,
                  motionShortAuditThreshold,
                  text.isEmpty ? "none" : text)
        }
    }

    private func sleepMotionShortSummary() -> (count: Int, mean: Double?, min: Double?, max: Double?, overOne: Int) {
        guard !sleepMotionShortValues.isEmpty else { return (0, nil, nil, nil, 0) }
        let count = sleepMotionShortValues.count
        let mean = sleepMotionShortValues.reduce(0, +) / Double(count)
        let overOne = sleepMotionShortValues.filter { $0 > motionShortAuditThreshold }.count
        return (count, mean, sleepMotionShortValues.min(), sleepMotionShortValues.max(), overOne)
    }

    private func logIMUCandidate(payload: [UInt8]) {
        let body = Array(payload.dropFirst())
        let decoded = AtriaIMUDecoder.decode(payload: payload)
        if let decoded {
            recordIMUFeatures(decoded)
        }
        var i16Pairs: [String] = []
        var magnitudes: [String] = []
        for offset in stride(from: 0, through: max(0, body.count - 2), by: 2) {
            guard offset + 1 < body.count else { continue }
            let raw = Int16(bitPattern: Self.u16le(body, offset))
            i16Pairs.append("\(offset):\(raw)")
        }
        for offset in stride(from: 0, through: max(0, body.count - 6), by: 6) {
            guard offset + 5 < body.count else { continue }
            let x = Double(Int16(bitPattern: Self.u16le(body, offset)))
            let y = Double(Int16(bitPattern: Self.u16le(body, offset + 2)))
            let z = Double(Int16(bitPattern: Self.u16le(body, offset + 4)))
            let magnitude = sqrt(x * x + y * y + z * z)
            magnitudes.append(String(format: "%d:%.1f", offset, magnitude))
        }
        if verboseBLEFrameLogging {
            AtriaDebugLog("ATRIADBG imu_candidate validated=%d validation_state=%@ len=%d offset=%d endian=%@ scale=%.0f sample_rate_hz=%@ samples=%d mean_g=%@ stillness_ratio=%@ movement_intensity=%@ bursts=%d strap_steps_research=%d step_source=strap_imu_research metric_promotions=0 i16=%@ magnitudes=%@ payload=%@",
                  decoded?.gravityValidated == true ? 1 : 0,
                  decoded?.validationState ?? "decode_failed",
                  payload.count,
                  decoded?.offset ?? -1,
                  decoded?.endian.rawValue ?? "none",
                  decoded?.scale ?? 0,
                  Self.formatDouble(imuFeatureSummary().sampleRateHz),
                  decoded?.samples.count ?? 0,
                  Self.formatDouble(decoded?.meanMagnitudeG),
                  Self.formatDouble(decoded?.stillnessRatio),
                  Self.formatDouble(decoded?.movementIntensity),
                  decoded?.activityBursts ?? 0,
                  strapStepResearchCount,
                  i16Pairs.joined(separator: ","),
                  magnitudes.joined(separator: ","),
                  Self.hex(payload))
        }
    }

    private func recordResearchProbeCandidate(payload: [UInt8], source: AtriaResearchProbe.Source) {
        if historyOnlyProbeMode, source == .historical {
            guard verboseBLEFrameLogging, researchProbeFrameCount < 3 else { return }
        }
        let summary = AtriaResearchProbe.analyze(payload: payload, source: source)
        applyModelMetadataIfExplicit(summary)
        guard researchProbeGenerationGate.acceptsForCandidateCounting(summary),
              supportsGenerationSpecificDecode,
              supportsSpO2Probe || supportsSkinTempProbe else { return }
        researchProbeFrameCount += 1
        if supportsSpO2Probe, !summary.oxygenByteCandidates.isEmpty {
            researchProbeOxygenCandidateFrames += 1
        }
        if supportsSkinTempProbe, !summary.temperatureWordCandidates.isEmpty {
            researchProbeTemperatureCandidateFrames += 1
            researchProbeTemperatureCandidateValueSum += summary.temperatureWordCandidates.reduce(0) { $0 + $1.value }
            researchProbeTemperatureCandidateValueCount += summary.temperatureWordCandidates.count
        }
        guard summary.hasAnyCandidate || researchProbeFrameCount == 1 || researchProbeFrameCount.isMultiple(of: 50) else { return }
        AtriaDebugLog("ATRIADBG sensor_research_probe source=%@ status=research_unvalidated len=%d frames=%d model_generation=%@ model_evidence=%@ spo2_enabled=%d spo2_candidate_frames=%d spo2_offsets=%@ skin_temp_enabled=%d skin_temp_candidate_frames=%d skin_temp_offsets=%@ metric_promotions=0 healthkit_write=0 raw_storage=0",
              summary.source.rawValue,
              summary.payloadLength,
              researchProbeFrameCount,
              summary.modelGeneration.rawValue,
              summary.modelEvidence.isEmpty ? "none" : summary.modelEvidence,
              supportsSpO2Probe ? 1 : 0,
              researchProbeOxygenCandidateFrames,
              supportsSpO2Probe ? summary.oxygenOffsetSummary : "disabled",
              supportsSkinTempProbe ? 1 : 0,
              researchProbeTemperatureCandidateFrames,
              supportsSkinTempProbe ? summary.temperatureOffsetSummary : "disabled")
    }

    private func applyModelMetadataIfExplicit(_ summary: AtriaResearchProbe.Summary) {
        guard summary.source == .metadata else { return }
        let mapped: AtriaStrapModel?
        switch summary.modelGeneration {
        case .strapMG:
            mapped = .strapMG
        case .strap5:
            mapped = .strap5
        case .strap4:
            mapped = .strap4
        case .strap3:
            mapped = .strap3
        case .unknown:
            mapped = nil
        }
        guard let mapped else {
            logUnknownStrapGenerationIfNeeded(summary)
            return
        }
        guard mapped != strapModel else { return }
        strapModel = mapped
        AtriaDebugLog("ATRIADBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
              mapped.rawValue,
              summary.modelEvidence.isEmpty ? "none" : summary.modelEvidence,
              summary.source.rawValue)
    }

    private func logUnknownStrapGenerationIfNeeded(_ summary: AtriaResearchProbe.Summary) {
        guard unknownGenerationProbeLogCount == 0 else { return }
        unknownGenerationProbeLogCount += 1
        AtriaDebugLog("ATRIADBG strap_generation status=unknown layout=%@ source=%@ evidence=%@ action=fail_closed_generation_specific_decodes",
                      summary.layoutHead,
                      summary.source.rawValue,
                      summary.modelEvidence.isEmpty ? "none" : summary.modelEvidence)
    }

    private func maybeSendRecentHistorySweep(realtimeUnix: UInt32) {
        guard historyRecentSweepEnabled, !historyRecentSweepSent, realtimeUnix > 0 else { return }
        historyRecentSweepSent = true
        let offsets = historyRecentSweepOffsets
        Task { @MainActor in
            for offset in offsets {
                let start = realtimeUnix > offset ? realtimeUnix - offset : realtimeUnix
                let end = realtimeUnix
                let payloads: [[UInt8]] = [
                    [0x00],
                    [0x01] + Self.le32(start),
                    [0x00] + Self.le32(start),
                    Self.le32(start),
                    Self.le32(start) + Self.le32(end),
                    [0x00] + Self.le32(start) + Self.le32(end),
                ]
                for (variant, data) in payloads.enumerated() {
                    AtriaDebugLog("ATRIADBG historyRecentSweep send offset_s=%u start=%u end=%u variant=%d cmd=16 data=%@",
                          offset, start, end, variant, Self.hex(data))
                    sendCommand(0x16, data, mode: probeCommandMode)
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        }
    }

    private func handleHistoryMetadata(_ payload: [UInt8]) {
        guard payload.count >= 3 else {
            AtriaDebugLog("ATRIADBG historyMeta malformed payload=%@", Self.hex(payload))
            return
        }
        recordResearchProbeCandidate(payload: payload, source: .metadata)
        let seq = payload[1]
        let cmd = payload[2]
        let body = Array(payload.dropFirst(3))
        let kind: String
        switch cmd {
        case 0x01: kind = "start"
        case 0x02: kind = "end"
        case 0x03: kind = "complete"
        default: kind = String(format: "unknown_%02x", cmd)
        }
        var fields = ""
        var metadataU32 = ""
        var metadataU16 = ""
        if body.count >= 10 {
            let unix = Self.u32le(body, 0)
            let subsec = Self.u16le(body, 4)
            let index = Self.u32le(body, 6)
            fields = String(format: " unix=%u subsec=%u index=%u", unix, subsec, index)
        }
        if !body.isEmpty {
            var u32Pairs: [String] = []
            for offset in stride(from: 0, through: max(0, body.count - 4), by: 2) {
                guard offset + 3 < body.count else { continue }
                u32Pairs.append("\(offset):\(Self.u32le(body, offset))")
            }
            metadataU32 = u32Pairs.joined(separator: ",")
            var u16Pairs: [String] = []
            for offset in stride(from: 0, through: max(0, body.count - 2), by: 2) {
                guard offset + 1 < body.count else { continue }
                u16Pairs.append("\(offset):\(Self.u16le(body, offset))")
            }
            metadataU16 = u16Pairs.joined(separator: ",")
        }
        if cmd == 0x03 {
            guard offlineHistoricalSyncInProgress else {
                AtriaDebugLog("ATRIADBG historyTerminal status=ignored reason=no_active_generation")
                return
            }
            historyDrainGate.terminalReceived = true
            AtriaDebugLog("ATRIADBG historyTerminal status=received generation=%llu pending=%d ack_complete=%d action=no_ack",
                          historyDrainGate.generation,
                          historyDrainGate.pendingPersistence,
                          historyDrainGate.ackWriteCompleted ? 1 : 0)
            advanceHistoricalDrainIfPossible(generation: historyDrainGate.generation)
        } else if cmd == 0x02, body.count >= 14 {
            let unix = body.count >= 4 ? Self.u32le(body, 0) : 0
            let index = body.count >= 10 ? Self.u32le(body, 6) : 0
            let trim = Self.u32le(body, 10)
            let endData = body.count >= 18 ? Array(body[10..<18]) : []
            let ackCursor: UInt32
            switch historyAckMode {
            case "index":
                ackCursor = index
            case "unix":
                ackCursor = unix
            case "zero":
                ackCursor = 0
            default:
                ackCursor = trim
            }
            let ackKey = historyAckMode == "enddata"
                ? "\(historyAckMode):\(Self.hex(endData))"
                : (historyAckMode == "trim"
                    ? "\(historyAckMode):\(ackCursor)"
                    : "\(historyAckMode):\(ackCursor):seq\(seq)")
            let acked = ackedHistoryAckKeys.contains(ackKey)
            AtriaDebugLog("ATRIADBG historyMeta seq=%d cmd=%02x kind=%@%@ trim=%u end_data=%@ ack_mode=%@ ack_cursor=%u acked=%d u32=%@ u16=%@ payload=%@",
                  Int(seq), cmd, kind, fields, trim, Self.hex(endData),
                  historyAckMode, ackCursor, acked ? 1 : 0, metadataU32, metadataU16,
                  Self.hex(payload))
            if historicalArchiveWriteFailures > 0 {
                AtriaDebugLog("ATRIADBG historyAck skip=archive_persist_failed mode=%@ trim=%u cursor=%u rows=%d rows_since_ack=%d failures=%d archive=%@",
                      historyAckMode,
                      trim,
                      ackCursor,
                      historicalArchiveRows,
                      historicalArchiveRowsSinceAck,
                      historicalArchiveWriteFailures,
                      lastHistoricalArchivePath.isEmpty ? HistoricalArchive.relativePath : lastHistoricalArchivePath)
                return
            }
            if historicalAckDisabled || historyAckMode == "none" {
                AtriaDebugLog("ATRIADBG historyAck skip=disabled mode=%@ trim=%u cursor=%u",
                      historyAckMode, trim, ackCursor)
                return
            }
            if historyAckMode == "enddata", endData.count != 8 {
                AtriaDebugLog("ATRIADBG historyAck skip=malformed_enddata mode=%@ trim=%u end_data_len=%d payload=%@",
                      historyAckMode, trim, endData.count, Self.hex(payload))
                return
            }
            guard !acked else { return }
            let ack: [UInt8]
            if historyAckMode == "enddata" {
                ack = [0x01] + endData
            } else {
                ack = [0x01] + Self.le32(ackCursor) + [0x00, 0x00, 0x00, 0x00]
            }
            guard offlineHistoricalSyncInProgress else {
                AtriaDebugLog("ATRIADBG historyAck skip=no_active_generation key=%@", ackKey)
                return
            }
            pendingHistoryEndACK = (ackKey, ack)
            historyDrainGate.endReceived = true
            AtriaDebugLog("ATRIADBG historyAck status=queued mode=%@ key=%@ pending_persistence=%d batch_failed=%d action=await_durable_flush",
                          historyAckMode,
                          ackKey,
                          historyDrainGate.pendingPersistence,
                          historyDrainGate.batchFailed ? 1 : 0)
            advanceHistoricalDrainIfPossible(generation: historyDrainGate.generation)
        } else {
            AtriaDebugLog("ATRIADBG historyMeta seq=%d cmd=%02x kind=%@%@ u32=%@ u16=%@ payload=%@",
                  Int(seq), cmd, kind, fields, metadataU32, metadataU16, Self.hex(payload))
        }
    }

    private func handleHistoricalData(_ payload: [UInt8]) {
        recordResearchProbeCandidate(payload: payload, source: .historical)
        let clock = historyClockRef
        let historyClockSyncEnabled = historyClockSyncEnabled
        let generation = offlineHistoricalSyncGeneration
        guard offlineHistoricalSyncInProgress,
              historyDrainGate.enqueueFrame(generation: generation) else {
            AtriaDebugLog("ATRIADBG historicalArchive status=ignored reason=inactive_or_stale_generation generation=%llu", generation)
            return
        }
        historicalArchiveQueue.async { [weak self] in
            let computation = Self.prepareHistoricalArchiveComputation(payload: payload,
                                                                       clock: clock,
                                                                       historyClockSyncEnabled: historyClockSyncEnabled)
            AtriaDebugLog("%@", computation.logMessage)
            let persistence = Self.persistHistoricalArchiveComputation(computation)
            Task { @MainActor [weak self] in
                self?.applyHistoricalArchivePersistenceResult(persistence, generation: generation)
            }
        }
    }

    private func applyHistoricalArchivePersistenceResult(_ result: HistoricalArchivePersistenceResult,
                                                         generation: UInt64) {
        guard offlineHistoricalSyncInProgress,
              historyDrainGate.finishPersistence(generation: generation,
                                                 succeeded: result.succeeded) else {
            AtriaDebugLog("ATRIADBG historicalArchive status=ignored reason=stale_persistence_callback callback_generation=%llu current_generation=%llu",
                          generation,
                          historyDrainGate.generation)
            return
        }
        if result.succeeded {
            historicalArchiveRows += 1
            historicalArchiveRowsSinceAck += 1
            if result.metricUsable, let effectiveUnix = result.effectiveUnix {
                let gapResult = AtriaHistoricalGapLedger.recordMetricUsableRow(
                    at: Date(timeIntervalSince1970: TimeInterval(effectiveUnix))
                )
                if gapResult.matchedWindows > 0 {
                    AtriaDebugLog("ATRIADBG offline_sync status=missing_window_metric_progress timestamp_unix=%u matched=%d resolved=%d remaining=%d",
                                  effectiveUnix,
                                  gapResult.matchedWindows,
                                  gapResult.resolvedWindows,
                                  gapResult.remainingWindows)
                }
                if gapResult.resolvedWindows > 0 {
                    offlineHistoricalSyncResolvedGapCoverage = true
                }
            }
            if offlineHistoricalSyncInProgress {
                let defaults = UserDefaults.standard
                let requestedStart = defaults.double(forKey: OfflineSyncDefaults.recoveryWindowStart)
                let requestedEnd = defaults.double(forKey: OfflineSyncDefaults.recoveryWindowEnd)
                if Self.requestedRecoveryRowProvidesMetricProgress(
                    metricUsable: result.metricUsable,
                    effectiveUnix: result.effectiveUnix,
                    requestedStart: requestedStart,
                    requestedEnd: requestedEnd
                ) {
                    offlineHistoricalSyncMadeRequestedMetricProgress = true
                }
            }
            lastHistoricalArchivePath = result.persistedPath.isEmpty ? HistoricalArchive.relativePath : result.persistedPath
            if result.archivedUndecodable {
                AtriaDebugLog("ATRIADBG historicalArchive status=archived_undecodable reason=%@ rows=%d rows_since_ack=%d failures=%d path=%@",
                      result.reason ?? "unknown",
                      historicalArchiveRows,
                      historicalArchiveRowsSinceAck,
                      historicalArchiveWriteFailures,
                      result.persistedPath)
            } else if historicalArchiveRows == 1 || historicalArchiveRows.isMultiple(of: 500) {
                AtriaDebugLog("ATRIADBG historicalArchive status=ok rows=%d rows_since_ack=%d failures=%d layout=%@ metric_usable=%d current_session_usable=%d path=%@",
                      historicalArchiveRows,
                      historicalArchiveRowsSinceAck,
                      historicalArchiveWriteFailures,
                      HistoricalArchive.layoutVersion,
                      result.metricUsable ? 1 : 0,
                      result.currentSessionUsable ? 1 : 0,
                      result.persistedPath)
            }
            advanceHistoricalDrainIfPossible(generation: generation)
            return
        }

        historicalArchiveWriteFailures += 1
        AtriaDebugLog("ATRIADBG historicalArchive status=error rows=%d rows_since_ack=%d failures=%d error=%@ action=skip_future_history_ack path=%@",
              historicalArchiveRows,
              historicalArchiveRowsSinceAck,
              historicalArchiveWriteFailures,
              result.errorDescription ?? "unknown",
              HistoricalArchive.relativePath)
        advanceHistoricalDrainIfPossible(generation: generation)
    }

    private func advanceHistoricalDrainIfPossible(generation: UInt64) {
        guard offlineHistoricalSyncInProgress,
              generation == historyDrainGate.generation else { return }

        if historyDrainGate.mayFlush, !historyDurableFlushInFlight {
            historyDurableFlushInFlight = true
            historicalArchiveQueue.async { [weak self] in
                let error: Error?
                do {
                    try HistoricalArchive.synchronizeDurableStorage()
                    error = nil
                } catch let caught {
                    error = caught
                }
                Task { @MainActor [weak self] in
                    guard let self,
                          self.offlineHistoricalSyncInProgress,
                          generation == self.historyDrainGate.generation else { return }
                    self.historyDurableFlushInFlight = false
                    if let error {
                        self.historyDrainGate.batchFailed = true
                        self.historicalArchiveWriteFailures += 1
                        AtriaDebugLog("ATRIADBG historyAck status=blocked reason=durable_flush_failed generation=%llu error=%@",
                                      generation,
                                      String(describing: error))
                    } else {
                        self.historyDrainGate.durableFlushCompleted = true
                        AtriaDebugLog("ATRIADBG historyAck status=durable generation=%llu rows_since_ack=%d",
                                      generation,
                                      self.historicalArchiveRowsSinceAck)
                    }
                    self.advanceHistoricalDrainIfPossible(generation: generation)
                }
            }
            return
        }

        if historyDrainGate.maySendACK, let pendingHistoryEndACK {
            guard txCharacteristic != nil else {
                peripheral?.discoverServices(discoveryServicesForCurrentMode)
                AtriaDebugLog("ATRIADBG historyAck status=waiting reason=tx_missing generation=%llu", generation)
                return
            }
            historyDrainGate.ackWriteInFlight = true
            pendingHistoryACKAttempts += 1
            AtriaDebugLog("ATRIADBG historyAck status=sending key=%@ generation=%llu attempt=%d payload=%@ write_mode=wr",
                          pendingHistoryEndACK.key,
                          generation,
                          pendingHistoryACKAttempts,
                          Self.hex(pendingHistoryEndACK.payload))
            sendCommand(Cmd.historicalDataResult, pendingHistoryEndACK.payload, mode: .withResponse)
            return
        }

        if historyDrainGate.mayFinishTerminal {
            let completedGeneration = historyDrainGate.generation
            if let peripheralID = peripheral?.identifier.uuidString {
                UserDefaults.standard.set(peripheralID,
                                          forKey: OfflineSyncDefaults.verifiedHistoryPeripheralID)
            }
            finishOfflineHistoricalSync(reason: "\(offlineHistoricalSyncReason)_terminal",
                                        generation: completedGeneration)
        }
    }

    private func handleHistoricalACKWriteResult(error: Error?) {
        guard offlineHistoricalSyncInProgress,
              historyDrainGate.ackWriteInFlight,
              let pendingHistoryEndACK else { return }
        let generation = historyDrainGate.generation
        historyDrainGate.ackWriteInFlight = false
        if let error {
            AtriaDebugLog("ATRIADBG historyAck status=write_failed key=%@ generation=%llu attempt=%d error=%@",
                          pendingHistoryEndACK.key,
                          generation,
                          pendingHistoryACKAttempts,
                          error.localizedDescription)
            guard pendingHistoryACKAttempts < 3 else {
                historyDrainGate.batchFailed = true
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self,
                      self.offlineHistoricalSyncInProgress,
                      generation == self.historyDrainGate.generation else { return }
                self.advanceHistoricalDrainIfPossible(generation: generation)
            }
            return
        }

        ackedHistoryAckKeys.insert(pendingHistoryEndACK.key)
        historicalArchiveRowsSinceAck = 0
        historyDrainGate.ackWriteCompleted = true
        self.pendingHistoryEndACK = nil
        AtriaDebugLog("ATRIADBG historyAck status=confirmed key=%@ generation=%llu attempts=%d",
                      pendingHistoryEndACK.key,
                      generation,
                      pendingHistoryACKAttempts)
        advanceHistoricalDrainIfPossible(generation: generation)
    }

    private nonisolated static func prepareHistoricalArchiveComputation(payload: [UInt8],
                                                                        clock: HistoryClockRef?,
                                                                        historyClockSyncEnabled: Bool) -> HistoricalArchiveComputation {
        guard payload.count >= 24 else {
            return HistoricalArchiveComputation(
                logMessage: String(format: "ATRIADBG historicalData short len=%d payload=%@", payload.count, Self.hex(payload)),
                payload: .undecodable(payload: payload, reason: "short_payload")
            )
        }

        let seq = payload.count > 1 ? payload[1] : 0
        let cmd = payload.count > 2 ? payload[2] : 0
        let unix = payload.count >= 11 ? Self.u32le(payload, 7) : 0
        let subsec = payload.count >= 13 ? Self.u16le(payload, 11) : 0
        let flashIndex = payload.count >= 15 ? Self.u32le(payload, 13) : 0
        let whoofHR = payload.count > 17 ? Int(payload[17]) : -1
        let whoofRRNum = payload.count > 18 ? Int(payload[18]) : -1
        let whoofRR = Self.historicalRRValues(payload, offsets: [19, 21, 23, 25])
        let kRevisionRR = Self.historicalRRValues(payload, offsets: [64, 66, 68, 70])
        let gravity = HistoricalArchive.historicalGravity(payload)
        let drift = clock?.driftSeconds
        let snappedDrift = clock?.snappedDriftSeconds
        let correctedUnix: UInt32?
        let clockStatus: String
        if let clock, unix > 0 {
            let corrected = Int64(unix) + Int64(clock.snappedDriftSeconds)
            correctedUnix = corrected > 0 && corrected <= Int64(UInt32.max) ? UInt32(corrected) : nil
            clockStatus = abs(clock.driftSeconds) >= 86_400 ? "stale_corrected_diagnostic_only" : "clock_ref_present"
        } else if historyClockSyncEnabled {
            correctedUnix = nil
            clockStatus = "clock_ref_missing"
        } else {
            correctedUnix = nil
            clockStatus = "clock_sync_not_requested"
        }

        var candidates: [String] = []
        candidates.reserveCapacity(payload.count / 8)
        for offset in stride(from: 1, to: payload.count - 1, by: 2) {
            let value = Int(Self.u16le(payload, offset))
            if (300...2000).contains(value) {
                candidates.append("\(offset):\(value)")
            }
        }

        let currentSessionUsable = Self.historicalCurrentSessionUsable(unix: correctedUnix ?? unix,
                                                                       gravityValidated: gravity?.validated == true,
                                                                       rrValues: whoofRR + kRevisionRR,
                                                                       candidateCount: candidates.count)
        let effectiveUnix = correctedUnix ?? unix
        let effectiveAgeSeconds: Int?
        if effectiveUnix > 0 {
            effectiveAgeSeconds = Int(Date().timeIntervalSince1970.rounded()) - Int(effectiveUnix)
        } else {
            effectiveAgeSeconds = nil
        }
        let effectiveRecentTwelveHours = effectiveAgeSeconds.map { $0 >= 0 && $0 <= 12 * 60 * 60 } ?? false
        let usabilityReason = currentSessionUsable
            ? "current_session_replay_ready_metric_reference_pending"
            : "provisional_historical_layout_old_or_unvalidated"
        let metricUsable = Self.historicalMetricUsable(layoutVersion: HistoricalArchive.layoutVersion,
                                                       clockStatus: clockStatus,
                                                       gravityValidated: gravity?.validated == true,
                                                       rrValues: whoofRR + kRevisionRR,
                                                       candidateCount: candidates.count)
        let payloadHex = Self.hex(payload)
        let logMessage = String(
            format: "ATRIADBG historicalData provisional=1 validated=0 seq=%02x cmd=%02x unix7=%u subsec11=%u flash13=%u len=%d strap4_v24_hr17=%d strap4_v24_rrnum18=%d strap4_v24_rr19=%@ k_rr64=%@ historical_gravity_mag=%@ historical_gravity_validated=%d clock_status=%@ clock_device_ref=%@ clock_wall_ref=%@ clock_drift_s=%@ clock_snapped_drift_s=%@ clock_corrected_unix7=%@ clock_effective_unix7=%u clock_effective_age_s=%@ clock_recent_12h=%d candidate_rr=%@ payload=%@",
            seq,
            cmd,
            unix,
            subsec,
            flashIndex,
            payload.count,
            whoofHR,
            whoofRRNum,
            Self.joinInts(whoofRR),
            Self.joinInts(kRevisionRR),
            gravity.map { String(format: "%.3f", $0.magnitude) } ?? "none",
            gravity?.validated == true ? 1 : 0,
            clockStatus,
            clock.map { String($0.device) } ?? "none",
            clock.map { String($0.wall) } ?? "none",
            drift.map(String.init) ?? "none",
            snappedDrift.map(String.init) ?? "none",
            correctedUnix.map(String.init) ?? "none",
            effectiveUnix,
            effectiveAgeSeconds.map(String.init) ?? "none",
            effectiveRecentTwelveHours ? 1 : 0,
            candidates.joined(separator: ","),
            payloadHex
        )

        let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                              capturedAt: Date(),
                                              source: "0x2f",
                                              layoutVersion: HistoricalArchive.layoutVersion,
                                              sequence: Int(seq),
                                              command: Int(cmd),
                                              unix7: unix,
                                              subsec11: subsec,
                                              flash13: flashIndex,
                                              payloadLength: payload.count,
                                              whoofHR17: whoofHR,
                                              whoofRRNum18: whoofRRNum,
                                              whoofRR19: whoofRR,
                                              kRR64: kRevisionRR,
                                              gravityX36: gravity?.x,
                                              gravityY40: gravity?.y,
                                              gravityZ44: gravity?.z,
                                              gravityMagnitude: gravity?.magnitude,
                                              gravityValidated: gravity?.validated == true,
                                              candidateRR: candidates,
                                              rawPayloadHex: payloadHex,
                                              clockDeviceRef: clock?.device,
                                              clockWallRef: clock?.wall,
                                              clockDriftSeconds: drift,
                                              clockCorrectedUnix7: correctedUnix,
                                              clockCorrectionStatus: clockStatus,
                                              currentSessionUsable: currentSessionUsable,
                                              metricUsable: metricUsable,
                                              usabilityReason: metricUsable ? "metric_ready_clock_gravity_rr" : usabilityReason)
        return HistoricalArchiveComputation(logMessage: logMessage, payload: .record(record))
    }

    private nonisolated static func historicalMetricUsable(layoutVersion: String,
                                                           clockStatus: String,
                                                           gravityValidated: Bool,
                                                           rrValues: [Int],
                                                           candidateCount: Int) -> Bool {
        HistoricalArchive.metricLayoutValidated(layoutVersion)
            && clockStatus == "clock_ref_present"
            && gravityValidated
            && rrValues.contains { (300...2000).contains($0) }
    }

    private nonisolated static func persistHistoricalArchiveComputation(_ computation: HistoricalArchiveComputation) -> HistoricalArchivePersistenceResult {
        do {
            let url: URL
            let archivedUndecodable: Bool
            let reason: String?
            switch computation.payload {
            case .record(let record):
                url = try HistoricalArchive.append(record)
                archivedUndecodable = false
                reason = nil
                let currentSessionUsable = record.currentSessionUsable
                return HistoricalArchivePersistenceResult(succeeded: true,
                                                          archivedUndecodable: archivedUndecodable,
                                                          currentSessionUsable: currentSessionUsable,
                                                          metricUsable: record.metricUsable,
                                                          reason: reason,
                                                          persistedPath: Self.documentsRelativePath(for: url),
                                                          errorDescription: nil,
                                                          effectiveUnix: record.clockCorrectedUnix7 ?? record.unix7)
            case .undecodable(let payload, let persistReason):
                url = try HistoricalArchive.appendUndecodable(payload: payload, reason: persistReason)
                archivedUndecodable = true
                reason = persistReason
                return HistoricalArchivePersistenceResult(succeeded: true,
                                                          archivedUndecodable: archivedUndecodable,
                                                          currentSessionUsable: false,
                                                          metricUsable: false,
                                                          reason: reason,
                                                          persistedPath: Self.documentsRelativePath(for: url),
                                                          errorDescription: nil,
                                                          effectiveUnix: nil)
            }
        } catch {
            return HistoricalArchivePersistenceResult(succeeded: false,
                                                      archivedUndecodable: false,
                                                      currentSessionUsable: false,
                                                      metricUsable: false,
                                                      reason: nil,
                                                      persistedPath: HistoricalArchive.relativePath,
                                                      errorDescription: String(describing: error).replacingOccurrences(of: " ", with: "_"),
                                                      effectiveUnix: nil)
        }
    }

    private nonisolated static func historicalRRValues(_ payload: [UInt8], offsets: [Int]) -> [Int] {
        offsets.compactMap { offset in
            guard offset + 1 < payload.count else { return nil }
            let value = Int(u16le(payload, offset))
            return (300...2000).contains(value) ? value : nil
        }
    }

    private nonisolated static func historicalCurrentSessionUsable(unix: UInt32,
                                                                   gravityValidated: Bool,
                                                                   rrValues: [Int],
                                                                   candidateCount: Int) -> Bool {
        unix > 0 && gravityValidated && (!rrValues.isEmpty || candidateCount >= 2)
    }

    private nonisolated static func joinInts(_ values: [Int]) -> String {
        values.map(String.init).joined(separator: ",")
    }

    /// Add an RR interval and recompute clinical HRV over the last 5 minutes.
    private func addRR(_ ms: Double,
                       at beatTime: Date,
                       source: String,
                       opcode: String,
                       expectedHR: Int?,
                       triggerRefresh: Bool = true) {
        var now = beatTime
        let previousRRBeatTime = lastRRBeatTime
        if let previous = previousRRBeatTime, now <= previous {
            now = previous.addingTimeInterval(0.001)
        }
        lastRRBeatTime = now
        recentRRBeatTimes.append(now)
        pruneRecentRRBeatTimesIfNeeded(now: now)
        let interval = RRInterval(t: now, ms: ms, expectedHR: expectedHR)
        rrArchive.append(interval)
        noteRRArchiveDidChange()
        appendRRPoint(ms: ms, at: now)
        let rrGap = previousRRBeatTime.map { now.timeIntervalSince($0) } ?? 0
        refreshRRPresenceOnRealInterval(at: now, source: source, rrGap: rrGap)
        let stableSeconds = stableContactSeconds(now: now)
        guard stableSeconds >= 10 else {
            resetHRVWindow(reason: String(format: "contact %.0fs/10s", stableSeconds))
            return
        }
        if !hrvGateWasOpen {
            resetRRBuffer()
            hrvGateWasOpen = true
            assignIfChanged(\.hrvQuality, "collecting beat-to-beat samples")
            logRow(kind: "hrv_quality", source: "app", opcode: "", len: "",
                   value: "clean_rr_window_started")
            return
        }
        rrBuffer.append(interval)
        if isRecording {
            var exportElapsedMS = Int((now.timeIntervalSince(captureStart) * 1000).rounded())
            if let previous = lastRRExportElapsedMS, exportElapsedMS <= previous {
                exportElapsedMS = previous + 1
            }
            lastRRExportElapsedMS = exportElapsedMS
            logRow(kind: "rr", source: source, opcode: opcode, len: "", value: String(format: "%.0f", ms),
                   at: now, elapsedMS: exportElapsedMS)
        }
        if triggerRefresh, shouldRefreshHRVSnapshot(now: now) {
            requestLiveHRVSnapshotRefresh(now: now,
                                          logKind: "hrv",
                                          shouldLogConsole: currentRRBufferCount.isMultiple(of: 15))
        }
    }

    private func addRRBatch(intervalsMS: [Int],
                            endingAt frameTime: Date,
                            source: String,
                            opcode: String,
                            expectedHR: Int?) {
        guard !intervalsMS.isEmpty else { return }

        let stableSeconds = stableContactSeconds(now: frameTime)
        let hasStableContact = stableSeconds >= 10
        let shouldOpenGate = hasStableContact && !hrvGateWasOpen
        if shouldOpenGate {
            resetRRBuffer()
            hrvGateWasOpen = true
            assignIfChanged(\.hrvQuality, "collecting beat-to-beat samples")
            logRow(kind: "hrv_quality", source: "app", opcode: "", len: "",
                   value: "clean_rr_window_started")
        } else if !hasStableContact {
            resetHRVWindow(reason: String(format: "contact %.0fs/10s", stableSeconds))
        }

        let beats = Self.beatTimesEnding(at: frameTime, intervalsMS: intervalsMS)
        let previousPacketBeatTime = lastRRBeatTime
        let appendPayload = makeRRBatchAppendPayload(beats: beats,
                                                     previousBeatTime: lastRRBeatTime,
                                                     expectedHR: expectedHR)
        if !appendPayload.intervals.isEmpty {
            lastRRBeatTime = appendPayload.beatTimes.last
            recentRRBeatTimes.append(contentsOf: appendPayload.beatTimes)
            rrArchive.append(contentsOf: appendPayload.intervals)
            noteRRArchiveDidChange()
            persistActiveSessionJournalForRRIfNeeded(reason: "standard_rr_batch", now: frameTime)
            if shouldMaintainSessionPointCaches, !appendPayload.rrPoints.isEmpty {
                rrPointsCache.append(contentsOf: appendPayload.rrPoints)
            }
            if hrvGateWasOpen && !shouldOpenGate {
                rrBuffer.append(contentsOf: appendPayload.intervals)
            }
        }

        if isRecording {
            for interval in appendPayload.intervals {
                var exportElapsedMS = Int((interval.t.timeIntervalSince(captureStart) * 1000).rounded())
                if let previous = lastRRExportElapsedMS, exportElapsedMS <= previous {
                    exportElapsedMS = previous + 1
                }
                lastRRExportElapsedMS = exportElapsedMS
                logRow(kind: "rr", source: source, opcode: opcode, len: "",
                       value: String(format: "%.0f", interval.ms),
                       at: interval.t, elapsedMS: exportElapsedMS)
            }
        }

        pruneRecentRRBeatTimesIfNeeded(now: lastRRBeatTime ?? frameTime)
        let rrGap = previousPacketBeatTime.map { max(0, frameTime.timeIntervalSince($0)) } ?? 0
        refreshRRPresenceOnRealInterval(at: frameTime, source: source, rrGap: rrGap)

        if hasStableContact && !shouldOpenGate {
            requestDeferredHRVSnapshotRefreshIfNeeded(now: frameTime)
        }
    }

    private func requestDeferredHRVSnapshotRefreshIfNeeded(now: Date) {
        guard shouldRefreshHRVSnapshot(now: now) else { return }
        requestLiveHRVSnapshotRefresh(now: now,
                                      logKind: "hrv",
                                      shouldLogConsole: currentRRBufferCount.isMultiple(of: 15))
    }

    private func pruneRecentRRBeatTimes(now: Date) {
        lastRecentRRBeatPruneAt = now
        recentRRBeatTimes.removeAll {
            now.timeIntervalSince($0) > Self.recentRRBeatWindowSeconds
        }
    }

    private func pruneRecentRRBeatTimesIfNeeded(now: Date) {
        if let lastRecentRRBeatPruneAt,
           now.timeIntervalSince(lastRecentRRBeatPruneAt) < Self.recentRRBeatPruneMinimumInterval,
           recentRRBeatTimes.count < 720 {
            return
        }
        pruneRecentRRBeatTimes(now: now)
    }

    private func appendSessionPoint(rate: Int, at sampleTime: Date) {
        guard shouldMaintainSessionPointCaches else { return }
        if sessionOriginTime == nil {
            sessionOriginTime = sampleTime
        }
        guard let origin = sessionOriginTime else { return }
        sessionPointsCache.append(SavedSession.Point(t: sampleTime.timeIntervalSince(origin), bpm: rate))
    }

    private func appendRRPoint(ms: Double, at beatTime: Date) {
        guard shouldMaintainSessionPointCaches else { return }
        guard let origin = sessionOriginTime, beatTime >= origin else { return }
        rrPointsCache.append(SavedSession.RRPoint(t: beatTime.timeIntervalSince(origin),
                                                  ms: Int(ms.rounded())))
    }

    private func makeRRBatchAppendPayload(beats: [(rr: Int, time: Date)],
                                          previousBeatTime: Date?,
                                          expectedHR: Int?) -> RRBatchAppendPayload {
        guard !beats.isEmpty else {
            return RRBatchAppendPayload(intervals: [], beatTimes: [], rrPoints: [])
        }

        var adjustedBeatTimes: [Date] = []
        adjustedBeatTimes.reserveCapacity(beats.count)

        var intervals: [RRInterval] = []
        intervals.reserveCapacity(beats.count)

        var rrPoints: [SavedSession.RRPoint] = []
        rrPoints.reserveCapacity(sessionOriginTime == nil ? 0 : beats.count)

        var previous = previousBeatTime
        let origin = sessionOriginTime

        for beat in beats {
            var beatTime = beat.time
            if let previous, beatTime <= previous {
                beatTime = previous.addingTimeInterval(0.001)
            }
            previous = beatTime
            adjustedBeatTimes.append(beatTime)

            let interval = RRInterval(t: beatTime,
                                      ms: Double(beat.rr),
                                      expectedHR: expectedHR)
            intervals.append(interval)

            if let origin, beatTime >= origin {
                rrPoints.append(SavedSession.RRPoint(t: beatTime.timeIntervalSince(origin),
                                                     ms: beat.rr))
            }
        }

        return RRBatchAppendPayload(intervals: intervals,
                                    beatTimes: adjustedBeatTimes,
                                    rrPoints: rrPoints)
    }

    private func rebuildSessionCaches() {
        sessionActiveCaloriesCache = nil
        guard let first = session.first else {
            sessionOriginTime = nil
            sessionPointsCache.removeAll(keepingCapacity: true)
            rrPointsCache.removeAll(keepingCapacity: true)
            return
        }

        sessionOriginTime = first.t
        sessionPointsCache = session.map {
            SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm)
        }
        rrPointsCache = rrArchive
            .filter { $0.t >= first.t }
            .map {
                SavedSession.RRPoint(t: $0.t.timeIntervalSince(first.t),
                                     ms: Int($0.ms.rounded()))
            }
    }

    /// Keeps routine durability checkpoints O(new samples) while preserving the
    /// exact full calculation for strength-workout exclusion windows.
    private func activeCaloriesForSnapshot(rest: Int,
                                           profile: AthleteProfile,
                                           excludedIntervals: [ExcludedInterval]) -> Double? {
        guard excludedIntervals.isEmpty else {
            let activeSamples = AtriaStrengthLog.samplesExcludingIntervals(
                session,
                excludedIntervals: excludedIntervals
            )
            return Metrics.activeCalories(activeSamples, rest: rest, profile: profile)
        }
        guard let first = session.first, let last = session.last, session.count > 1 else { return nil }

        if var cache = sessionActiveCaloriesCache,
           cache.sessionID == liveSessionID,
           cache.origin == first.t,
           cache.restingHeartRate == rest,
           cache.profile == profile,
           cache.sampleCount > 0,
           cache.sampleCount <= session.count,
           session[cache.sampleCount - 1].t == cache.lastTimestamp {
            if cache.sampleCount < session.count {
                var calories = cache.calories ?? 0
                if profile.hasEnergyProfile {
                    for index in cache.sampleCount..<session.count {
                        calories += Metrics.activeCalories(
                            [session[index - 1], session[index]],
                            rest: rest,
                            profile: profile
                        ) ?? 0
                    }
                }
                cache.sampleCount = session.count
                cache.lastTimestamp = last.t
                cache.calories = profile.hasEnergyProfile ? calories : nil
                sessionActiveCaloriesCache = cache
            }
            return cache.calories
        }

        let calories = Metrics.activeCalories(session, rest: rest, profile: profile)
        sessionActiveCaloriesCache = SessionActiveCaloriesCache(
            sessionID: liveSessionID,
            origin: first.t,
            sampleCount: session.count,
            lastTimestamp: last.t,
            restingHeartRate: rest,
            profile: profile,
            calories: calories
        )
        return calories
    }

    private var shouldMaintainSessionPointCaches: Bool {
        longWearModeEnabled
    }

    private func updateSessionPointCacheMode() {
        if shouldMaintainSessionPointCaches {
            rebuildSessionCaches()
        } else {
            sessionOriginTime = session.first?.t
            sessionPointsCache.removeAll(keepingCapacity: true)
            rrPointsCache.removeAll(keepingCapacity: true)
        }
    }

    fileprivate func record(frame: AtriaFrame) {
        guard storeProprietaryFrames else { return }
        logRow(kind: "frame", source: frame.source,
               opcode: String(format: "%02X", frame.opcode),
               len: "\(frame.declaredLen)", value: frame.hex)
        frames.append(frame)
        if frames.count >= maxFrames * 2 {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    /// Snapshot the current HR session into a persistable record, then reset it
    /// so a new session starts fresh. Returns nil if there's nothing to save.
    func finishSession(label: String) -> SavedSession? {
        guard let saved = snapshotSession(label: label) else { return nil }
        resetLiveSessionState(start: Date())
        return saved
    }

    @discardableResult
    func checkpointCurrentSession(label: String,
                                  reason: String,
                                  strengthSets: [LoggedSet] = [],
                                  excludedIntervals: [ExcludedInterval] = []) -> Bool {
        guard let saved = snapshotSession(label: label,
                                          strengthSets: strengthSets,
                                          excludedIntervals: excludedIntervals) else {
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=%@ samples=%d rr_samples=%d label=%@ source=live_workout_end",
                  reason,
                  session.count,
                  rrArchive.count,
                  label)
            return false
        }
        let persisted = onSessionCheckpoint?(saved) == true
        persistActiveSessionJournalIfNeeded(reason: "live_workout_end_checkpoint", force: true)
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ reason=%@ samples=%d rr_samples=%d duration_s=%.0f avg_hr=%d peak_hr=%d label=%@ source=live_workout_end mode=upsert reset_live_session=0",
              persisted ? "saved" : "store_failed",
              reason,
              saved.points.count,
              saved.rrSampleCount,
              saved.duration,
              saved.avg,
              saved.peak,
              saved.label)
        return persisted
    }

    private func rollActiveSessionAfterLongGapIfNeeded(nextSampleTime: Date, reason: String) {
        let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
        guard (longWearModeEnabled || activeExplicitWorkout || sessionAwaitingUnexpectedReconnect),
              !session.isEmpty else { return }
        let previous = [lastRawHRNotificationAt, lastAcceptedHRAt, session.last?.t].compactMap { $0 }.max()
        guard let previous else { return }
        let gap = nextSampleTime.timeIntervalSince(previous)
        guard gap >= activeJournalSegmentGapLimit else {
            sessionAwaitingUnexpectedReconnect = false
            return
        }

        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        guard let saved = snapshotSession(label: label) else {
            resetLiveSessionState(start: nextSampleTime)
            sessionAwaitingUnexpectedReconnect = false
            ActiveSessionJournal.clear()
            AtriaDebugLog("ATRIADBG active_session_rollover status=reset reason=%@ gap_s=%.1f threshold_s=%.1f previous_samples=%d action=start_new_segment",
                  reason, gap, activeJournalSegmentGapLimit, session.count)
            return
        }
        let persisted = persistFinishedSession(saved, reason: "long_gap_rollover")
        if persisted {
            // `snapshotSession` does not reset; `persistFinishedSession` only clears
            // the on-disk journal. Start the next received sample in a clean segment.
            resetLiveSessionState(start: nextSampleTime)
        }
        sessionAwaitingUnexpectedReconnect = false
        AtriaDebugLog("ATRIADBG active_session_rollover status=%@ reason=%@ gap_s=%.1f threshold_s=%.1f saved_samples=%d saved_duration_s=%.0f action=%@",
              persisted ? "saved" : "store_failed",
              reason,
              gap,
              activeJournalSegmentGapLimit,
              saved.points.count,
              saved.duration,
              persisted ? "start_new_segment" : "retain_existing_segment")
    }

    nonisolated static func crossesEventCivilDay(sessionStart: Date,
                                                 nextSampleTime: Date,
                                                 eventTimeZoneIdentifier: String?,
                                                 calendar: Calendar = .current) -> Bool {
        let startDay = EventCivilTime.day(containing: sessionStart,
                                          eventTimeZoneIdentifier: eventTimeZoneIdentifier,
                                          outputCalendar: calendar)
        let nextDay = EventCivilTime.day(containing: nextSampleTime,
                                         eventTimeZoneIdentifier: eventTimeZoneIdentifier,
                                         outputCalendar: calendar)
        return startDay != nextDay
    }

    private func rollActiveSessionAtCivilDayBoundaryIfNeeded(nextSampleTime: Date) {
        guard longWearModeEnabled,
              let first = session.first,
              Self.crossesEventCivilDay(sessionStart: first.t,
                                        nextSampleTime: nextSampleTime,
                                        eventTimeZoneIdentifier: liveSessionEventTimeZoneIdentifier) else {
            return
        }
        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        guard let saved = snapshotSession(label: label) else {
            let previousSamples = session.count
            resetLiveSessionState(start: nextSampleTime)
            ActiveSessionJournal.clear()
            AtriaDebugLog("ATRIADBG active_session_rollover status=reset reason=civil_day_boundary previous_samples=%d action=start_new_day_segment",
                          previousSamples)
            return
        }
        let persisted = persistFinishedSession(saved, reason: "civil_day_boundary_rollover")
        if persisted {
            resetLiveSessionState(start: nextSampleTime)
        }
        AtriaDebugLog("ATRIADBG active_session_rollover status=%@ reason=civil_day_boundary saved_samples=%d saved_duration_s=%.0f action=%@",
                      persisted ? "saved" : "store_failed",
                      saved.points.count,
                      saved.duration,
                      persisted ? "start_new_day_segment" : "retain_existing_segment")
    }

    /// Bound the live session during continuous all-day wear: once the current
    /// segment spans `longWearLiveSessionRetentionSpan`, finalize it to disk and
    /// segment-roll to a fresh one so the four live arrays can't grow unbounded
    /// (the OOM/jetsam cause — handoff #1). Uses the same persist-then-reset
    /// primitive as the >=90s-gap roll: `persistFinishedSession` calls
    /// `onSessionEnd` (`store.add`, which upserts by id), so the full record is
    /// preserved on disk before `resetLiveSessionState` clears the live arrays and
    /// mints a new `liveSessionID`. The next received sample resumes ~1s later, so
    /// the day's contiguous segments re-cluster into one aggregate sleep/wear
    /// candidate (`sleepClusters` bridges gaps <=2h). Mode-independent by design:
    /// full-protocol overnight capture still needs the same memory bound while
    /// preserving richer RR/IMU evidence. Returns without rolling unless long-wear
    /// mode is active with enough samples and the span cap is met.
    /// Pure trigger for the retention roll, extracted so the 3h-cap logic is
    /// unit-testable without standing up a live AtriaBLEManager (AtriaPerfFixesTests):
    /// roll once the live segment has enough samples AND spans the retention cap.
    static func shouldRollLiveSession(spanSeconds: TimeInterval,
                                      sampleCount: Int,
                                      minSamples: Int,
                                      retentionSpan: TimeInterval) -> Bool {
        sampleCount >= minSamples && spanSeconds >= retentionSpan
    }

    @discardableResult
    private func rollLongWearLiveSessionIfOversized(now: Date, reason: String) -> Bool {
        guard longWearModeEnabled else { return false }
        guard let first = session.first else { return false }
        let span = now.timeIntervalSince(first.t)
        guard Self.shouldRollLiveSession(spanSeconds: span,
                                         sampleCount: session.count,
                                         minSamples: autoSaveMinSamples,
                                         retentionSpan: longWearLiveSessionRetentionSpan) else { return false }

        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        guard let saved = snapshotSession(label: label) else { return false }
        let persisted = persistFinishedSession(saved, reason: reason)
        if persisted {
            // Full segment is on disk; start the next sample in a clean segment so
            // the live arrays reset. Mirrors the gap-roll at the reset below.
            resetLiveSessionState(start: now)
        }
        AtriaDebugLog("ATRIADBG live_session_retention_roll status=%@ reason=%@ span_s=%.0f cap_s=%.0f samples=%d rr_samples=%d duration_s=%.0f action=%@",
              persisted ? "rolled" : "store_failed",
              reason,
              span,
              longWearLiveSessionRetentionSpan,
              saved.points.count,
              saved.rrSampleCount,
              saved.duration,
              persisted ? "reset_live_segment" : "retain_live_segment")
        return persisted
    }

    private func resetLiveSessionState(start: Date) {
        session.removeAll(keepingCapacity: true)
        publishSessionSampleCountIfNeeded(now: start, force: true)
        lastSessionSampleCountPublishedAt = nil
        sessionOriginTime = nil
        sessionPointsCache.removeAll(keepingCapacity: true)
        rrPointsCache.removeAll(keepingCapacity: true)
        sessionActiveCaloriesCache = nil
        sessionMinHeartRate = nil
        sessionMaxHeartRate = nil
        sessionHeartRateTotal = 0
        sessionHeartRateAggregateCount = 0
        sessionHeartRateMean = 0
        sessionHeartRateM2 = 0
        // Invalidate the off-main historical-motion cache for the new segment so a
        // previous session's value can never be reused, and clear the in-flight flag
        // so a fresh refresh can always start (defense-in-depth; origin-keying
        // already prevents cross-session reads, but this survives frequent resets).
        cachedHistoricalMotion = nil
        cachedHistoricalMotionOrigin = nil
        cachedHistoricalMotionAt = nil
        historicalMotionRefreshInFlight = false
        replaceLastHeartRates([])
        rrArchive.removeAll(keepingCapacity: true)
        noteRRArchiveDidChange()
        recentRRBeatTimes.removeAll(keepingCapacity: true)
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
        lastActiveJournalPersistedSampleCount = 0
        lastActiveJournalPersistedRRCount = 0
        lastActiveJournalSavedResearchAggregates = .zero
        resetSessionMotionDiagnostics()
        resetSessionSampleDiagnostics()
        sessionStart = start
        lastAcceptedHRAt = nil
        lastRawHRNotificationAt = nil
        lastStandardHR = nil
        pendingHRJump = nil
        recentValid.removeAll(keepingCapacity: true)
        liveSessionID = UUID()
        liveSessionEventTimeZoneIdentifier = TimeZone.current.identifier
        activeJournalDirtySamples = 0
        activeJournalPendingTimestampRefresh = false
        lastCanonicalCheckpointAt = nil
        segmentHROnlyRRRecoveryCount = 0
        lastSegmentHROnlyRRRecoveryAt = nil
        currentRRGapRecoveryCount = 0
        lastCurrentRRGapRecoveryAt = nil
    }

    private func appendLastHeartRate(_ rate: Int) {
        lastHeartRates.append(rate)
        if rate > 0 {
            lastHeartRatesTotal += rate
            lastHeartRatesPositiveCount += 1
            lastHeartRatesPeak = max(lastHeartRatesPeak ?? rate, rate)
        }
        if lastHeartRates.count > 60 {
            let removed = lastHeartRates.removeFirst()
            if removed > 0 {
                lastHeartRatesTotal -= removed
                lastHeartRatesPositiveCount = max(0, lastHeartRatesPositiveCount - 1)
                if lastHeartRatesPeak == removed {
                    lastHeartRatesPeak = lastHeartRates.lazy.filter { $0 > 0 }.max()
                }
            }
        }
    }

    private func replaceLastHeartRates(_ values: [Int]) {
        lastHeartRates = values
        lastHeartRatesTotal = 0
        lastHeartRatesPositiveCount = 0
        lastHeartRatesPeak = nil
        for value in values where value > 0 {
            lastHeartRatesTotal += value
            lastHeartRatesPositiveCount += 1
            lastHeartRatesPeak = max(lastHeartRatesPeak ?? value, value)
        }
        rebuildLiveHeartWindow()
    }

    private func rebuildLiveHeartWindow() {
        let average = lastHeartRatesPositiveCount > 0
            ? Int((Double(lastHeartRatesTotal) / Double(lastHeartRatesPositiveCount)).rounded())
            : nil
        let sparkline = compactHeartSparkline(lastHeartRates)
        assignIfChanged(\.liveHeartWindow,
                        LiveHeartWindow(sparkline: sparkline,
                                        average: average,
                                        peak: lastHeartRatesPeak))
    }

    private func compactHeartSparkline(_ values: [Int], targetCount: Int = 18) -> [Int] {
        guard values.count > targetCount, targetCount > 1 else { return values }
        let maxIndex = values.count - 1
        let step = Double(maxIndex) / Double(targetCount - 1)
        return (0..<targetCount).map { sample in
            let index = min(maxIndex, Int((Double(sample) * step).rounded()))
            return values[index]
        }
    }

    var recentFramesNewestFirst: [AtriaFrame] {
        Array(frames.suffix(maxFrames).reversed())
    }

    private func maybeHandleCommandResponseFrame(_ frame: AtriaFrame?, uuid: CBUUID) {
        guard let frame, frame.opcode == 0x24 else { return }
        AtriaDebugLog("ATRIADBG cmdResp ch=%@ payload=%@",
              uuid.uuidString,
              frame.payload.map { String(format: "%02x", $0) }.joined())
        handleCommandResponsePayload([UInt8](frame.payload))
        record(frame: frame)
    }

    private func handleParsedProprietaryUpdate(_ update: ParsedProprietaryUpdate, uuid: CBUUID) {
        switch update {
        case .realtime(let packet):
            dbgRealtimeFrames += 1
            handleParsedRealtimePacket(packet)
        case .commandResponse(let frame):
            maybeHandleCommandResponseFrame(frame, uuid: uuid)
        case .historyMetadata(let payload):
            handleHistoryMetadata(payload)
        case .historical(let payload):
            handleHistoricalData(payload)
        case .unknown(let payload, let fullFrame):
            handleUnknownProtocolPayload(payload, fullFrame: fullFrame)
        }
    }

    private static let mainActorPacketApplyYieldInterval = 6

    @discardableResult
    nonisolated static func trimPendingQueue<Element>(_ queue: inout [Element],
                                                       consumedCount: inout Int,
                                                       limit: Int) -> Int {
        precondition(limit >= 0)
        precondition(consumedCount >= 0 && consumedCount <= queue.count)
        let unconsumedCount = queue.count - consumedCount
        guard unconsumedCount > limit else { return 0 }

        if consumedCount > 0 {
            queue.removeFirst(consumedCount)
            consumedCount = 0
        }
        let overflow = queue.count - limit
        queue.removeFirst(overflow)
        return overflow
    }

    private func handleParsedRealtimePackets(_ packets: [ParsedRealtimePacket]) async {
        beginRealtimePacketBatch()
        for (index, packet) in packets.enumerated() {
            dbgPropFrames += 1
            dbgRealtimeFrames += 1
            handleParsedRealtimePacket(packet)
            if index < packets.count - 1,
               (index + 1).isMultiple(of: Self.mainActorPacketApplyYieldInterval) {
                await Task.yield()
            }
        }
        endRealtimePacketBatch()
    }

    private nonisolated func enqueueRealtimePacket(_ packet: ParsedRealtimePacket) {
        var shouldScheduleDrain = false
        realtimePacketQueueLock.lock()
        pendingRealtimePackets.append(packet)
        Self.trimPendingQueue(&pendingRealtimePackets,
                              consumedCount: &pendingRealtimePacketHead,
                              limit: Self.pendingRealtimePacketLimit)
        if !realtimePacketDrainScheduled {
            realtimePacketDrainScheduled = true
            shouldScheduleDrain = true
        }
        realtimePacketQueueLock.unlock()
        guard shouldScheduleDrain else { return }
        Task { [weak self] in
            await self?.drainPendingRealtimePackets()
        }
    }

    private nonisolated func dequeuePendingRealtimePacketBatch(limit: Int) -> [ParsedRealtimePacket] {
        realtimePacketQueueLock.lock()
        let availableCount = pendingRealtimePackets.count - pendingRealtimePacketHead
        let count = min(limit, availableCount)
        let batch = count > 0
            ? Array(pendingRealtimePackets[pendingRealtimePacketHead..<(pendingRealtimePacketHead + count)])
            : []
        if count > 0 {
            pendingRealtimePacketHead += count
            if pendingRealtimePacketHead >= pendingRealtimePackets.count {
                pendingRealtimePackets.removeAll(keepingCapacity: true)
                pendingRealtimePacketHead = 0
            } else if pendingRealtimePacketHead >= 64,
                      pendingRealtimePacketHead * 2 >= pendingRealtimePackets.count {
                pendingRealtimePackets.removeFirst(pendingRealtimePacketHead)
                pendingRealtimePacketHead = 0
            }
        }
        realtimePacketQueueLock.unlock()
        return batch
    }

    private nonisolated func finishRealtimePacketDrainIfIdle() -> Bool {
        realtimePacketQueueLock.lock()
        let isIdle = pendingRealtimePacketHead >= pendingRealtimePackets.count
        if isIdle {
            pendingRealtimePackets.removeAll(keepingCapacity: true)
            pendingRealtimePacketHead = 0
            realtimePacketDrainScheduled = false
        }
        realtimePacketQueueLock.unlock()
        return isIdle
    }

    private nonisolated func drainPendingRealtimePackets() async {
        var batchesSinceRunLoopTurn = 0
        while true {
            let batch = dequeuePendingRealtimePacketBatch(limit: Self.realtimePacketBatchSize)
            if batch.isEmpty {
                if finishRealtimePacketDrainIfIdle() {
                    return
                }
                continue
            }
            await applyRealtimePacketBatch(batch)
            batchesSinceRunLoopTurn += 1
            if batchesSinceRunLoopTurn >= 8 {
                // A resumed app can receive a large CoreBluetooth backlog.
                // Yielding alone may immediately reschedule this same drain;
                // a tiny suspension gives the main run loop a real frame turn.
                batchesSinceRunLoopTurn = 0
                try? await Task.sleep(for: .milliseconds(2))
            } else {
                await Task.yield()
            }
        }
    }

    private func applyRealtimePacketBatch(_ packets: [ParsedRealtimePacket]) async {
        await handleParsedRealtimePackets(packets)
    }

    private func handlePendingHeartRateUpdates(_ updates: [PendingHeartRateUpdate]) async {
        beginAcceptedHeartRateBatch()
        for (index, update) in updates.enumerated() {
            recordHeartRateMeasurement(update.packet, rawData: update.rawData)
            if index < updates.count - 1,
               (index + 1).isMultiple(of: Self.mainActorPacketApplyYieldInterval) {
                await Task.yield()
            }
        }
        endAcceptedHeartRateBatch()
    }

    private nonisolated func enqueueHeartRateUpdate(_ update: PendingHeartRateUpdate) {
        var shouldScheduleDrain = false
        heartRatePacketQueueLock.lock()
        pendingHeartRateUpdates.append(update)
        Self.trimPendingQueue(&pendingHeartRateUpdates,
                              consumedCount: &pendingHeartRateUpdateHead,
                              limit: Self.pendingHeartRateUpdateLimit)
        if !heartRatePacketDrainScheduled {
            heartRatePacketDrainScheduled = true
            shouldScheduleDrain = true
        }
        heartRatePacketQueueLock.unlock()
        guard shouldScheduleDrain else { return }
        Task { [weak self] in
            await self?.drainPendingHeartRateUpdates()
        }
    }

    private nonisolated func dequeuePendingHeartRateUpdateBatch(limit: Int) -> [PendingHeartRateUpdate] {
        heartRatePacketQueueLock.lock()
        let availableCount = pendingHeartRateUpdates.count - pendingHeartRateUpdateHead
        let count = min(limit, availableCount)
        let batch = count > 0
            ? Array(pendingHeartRateUpdates[pendingHeartRateUpdateHead..<(pendingHeartRateUpdateHead + count)])
            : []
        if count > 0 {
            pendingHeartRateUpdateHead += count
            if pendingHeartRateUpdateHead >= pendingHeartRateUpdates.count {
                pendingHeartRateUpdates.removeAll(keepingCapacity: true)
                pendingHeartRateUpdateHead = 0
            } else if pendingHeartRateUpdateHead >= 64,
                      pendingHeartRateUpdateHead * 2 >= pendingHeartRateUpdates.count {
                pendingHeartRateUpdates.removeFirst(pendingHeartRateUpdateHead)
                pendingHeartRateUpdateHead = 0
            }
        }
        heartRatePacketQueueLock.unlock()
        return batch
    }

    private nonisolated func finishHeartRatePacketDrainIfIdle() -> Bool {
        heartRatePacketQueueLock.lock()
        let isIdle = pendingHeartRateUpdateHead >= pendingHeartRateUpdates.count
        if isIdle {
            pendingHeartRateUpdates.removeAll(keepingCapacity: true)
            pendingHeartRateUpdateHead = 0
            heartRatePacketDrainScheduled = false
        }
        heartRatePacketQueueLock.unlock()
        return isIdle
    }

    private nonisolated func drainPendingHeartRateUpdates() async {
        var batchesSinceRunLoopTurn = 0
        while true {
            let batch = dequeuePendingHeartRateUpdateBatch(limit: Self.heartRatePacketBatchSize)
            if batch.isEmpty {
                if finishHeartRatePacketDrainIfIdle() {
                    return
                }
                continue
            }
            await applyPendingHeartRateUpdates(batch)
            batchesSinceRunLoopTurn += 1
            if batchesSinceRunLoopTurn >= 8 {
                batchesSinceRunLoopTurn = 0
                try? await Task.sleep(for: .milliseconds(2))
            } else {
                await Task.yield()
            }
        }
    }

    private func applyPendingHeartRateUpdates(_ updates: [PendingHeartRateUpdate]) async {
        await handlePendingHeartRateUpdates(updates)
    }

    private func handleParsedRealtimePacket(_ packet: ParsedRealtimePacket) {
        if packet.realtimeUnix > 0 {
            lastRealtimeUnix = packet.realtimeUnix
        }
        if hrConsistencyEnabled {
            lastRealtimeHR = (packet.hr, packet.frameTime)
            if realtimePacketBatchDepth > 0 {
                realtimeBatchPendingConsistencyAt = packet.frameTime
            } else {
                compareHRChannelsIfPossible(now: packet.frameTime, source: "0x28")
            }
        }

        let rrnum = packet.rrValues.count
        let standardRecentlyActive = lastStandardRRAt.map { packet.frameTime.timeIntervalSince($0) <= 2.5 } ?? false
        if !standardRecentlyActive {
            if !packet.rrValues.isEmpty {
                usedRealtimeRRValues += packet.rrValues.count
                addRRBatch(intervalsMS: packet.rrValues,
                           endingAt: packet.frameTime,
                           source: "0x28",
                           opcode: "28",
                           expectedHR: nil)
            }
            updateRRContinuityQuality(now: packet.frameTime, rrCount: rrnum, source: "0x28")
            if autoCapturePending, autoCaptureRRThreshold > 0 {
                updateAdaptiveAutoCapture(now: packet.frameTime, rrnum: rrnum, source: "0x28")
            }
        }
        if realtimePacketBatchDepth > 0 {
            realtimeBatchPendingRestart = (now: packet.frameTime, rrnum: rrnum)
            if packet.realtimeUnix > 0 {
                realtimeBatchPendingHistorySweepUnix = packet.realtimeUnix
            }
        } else {
            maybeRestartRealtimeAfterZeroRR(now: packet.frameTime, rrnum: rrnum)
            if historyRecentSweepEnabled {
                maybeSendRecentHistorySweep(realtimeUnix: packet.realtimeUnix)
            }
        }

        if !packet.rrValues.isEmpty || packet.truncated {
            decodedRealtimeRRValues += packet.rrValues.count
        }
    }

    @discardableResult
    private func persistFinishedSession(_ saved: SavedSession, reason: String) -> Bool {
        if longWearModeEnabled,
           saved.duration < minimumFinishedLongWearDuration,
           reason != "user_stop",
           reason != "manual_finish" {
            persistActiveSessionJournalIfNeeded(reason: "\(reason)_short_fragment_checkpoint", force: true)
            ActiveSessionJournal.recordClose(status: "retained_short_fragment",
                                             reason: reason,
                                             label: saved.label,
                                             samples: saved.points.count,
                                             duration: saved.duration)
            AtriaDebugLog("ATRIADBG session_finish status=skipped reason=long_wear_short_fragment finish_reason=%@ samples=%d rr_samples=%d duration_s=%.0f min_duration_s=%.0f label=%@ action=retain_active_journal",
                          reason,
                          saved.points.count,
                          saved.rrSampleCount,
                          saved.duration,
                          minimumFinishedLongWearDuration,
                          saved.label)
            return false
        }
        guard onSessionEnd?(saved) == true else {
            ActiveSessionJournal.recordClose(status: "store_failed",
                                             reason: reason,
                                             label: saved.label,
                                             samples: saved.points.count,
                                             duration: saved.duration)
            AtriaDebugLog("ATRIADBG active_session_journal status=retained reason=store_failed finish_reason=%@ label=%@ samples=%d",
                  reason,
                  saved.label,
                  saved.points.count)
            return false
        }
        clearFinishedSessionJournal(after: saved, reason: reason)
        return true
    }

    func clearFinishedSessionJournal(after saved: SavedSession, reason: String) {
        activeJournalDirtySamples = 0
        activeJournalPendingTimestampRefresh = false
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
        lastActiveJournalPersistedSampleCount = 0
        lastActiveJournalPersistedRRCount = 0
        lastActiveJournalSavedResearchAggregates = .zero
        ActiveSessionJournal.recordClose(status: "cleared",
                                         reason: reason,
                                         label: saved.label,
                                         samples: saved.points.count,
                                         duration: saved.duration)
        ActiveSessionJournal.clear()
        AtriaDebugLog("ATRIADBG active_session_journal status=cleared reason=%@ label=%@ samples=%d duration_s=%.0f close_recorded=1",
              reason,
              saved.label,
              saved.points.count,
              saved.duration)
    }

    @discardableResult
    private func clearUnsavableActiveJournalIfNeeded(reason: String) -> Bool {
        guard longWearModeEnabled, !session.isEmpty, session.count < 2 else { return false }
        let label = captureLabel.isEmpty ? "All-day wear" : captureLabel
        let duration = max(0, (session.last?.t ?? sessionStart).timeIntervalSince(sessionStart))
        activeJournalDirtySamples = 0
        activeJournalPendingTimestampRefresh = false
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
        lastActiveJournalPersistedSampleCount = 0
        lastActiveJournalPersistedRRCount = 0
        lastActiveJournalSavedResearchAggregates = .zero
        ActiveSessionJournal.recordClose(status: "cleared_unsavable",
                                         reason: reason,
                                         label: label,
                                         samples: session.count,
                                         duration: duration)
        ActiveSessionJournal.clear()
        AtriaDebugLog("ATRIADBG active_session_journal status=cleared reason=%@ label=%@ samples=%d duration_s=%.0f action=drop_unsavable_stale_segment",
                      reason,
                      label,
                      session.count,
                      duration)
        return true
    }

    /// Refresh the off-main historical-gravity motion summary for the current live
    /// session window. Runs the multi-MB archive parse on a utility queue so it can
    /// never block the MainActor (the freeze `snapshotSession` used to cause). Rate-
    /// limited to ~30 s and keyed by the session origin, so a new rolled/reset
    /// segment invalidates the previous value. Fire-and-forget; the result is picked
    /// up by the next `snapshotSession`.
    private func refreshHistoricalMotionCache(start: Date, end: Date) {
        guard !historicalMotionRefreshInFlight else { return }
        if cachedHistoricalMotionOrigin == start,
           let at = cachedHistoricalMotionAt,
           Date().timeIntervalSince(at) < 30 {
            return
        }
        historicalMotionRefreshInFlight = true
        Task.detached(priority: .utility) { [weak self, start, end] in
            let summary = HistoricalArchive.motionFeatureSummary(start: start, end: end)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cachedHistoricalMotion = summary
                self.cachedHistoricalMotionOrigin = start
                self.cachedHistoricalMotionAt = Date()
                self.historicalMotionRefreshInFlight = false
            }
        }
    }

    /// Snapshot the current HR session into a persistable record without
    /// resetting it, so unattended long runs survive debugger/device drops.
    func snapshotSession(label: String,
                         strengthSets: [LoggedSet] = [],
                         excludedIntervals: [ExcludedInterval] = []) -> SavedSession? {
        guard let first = session.first, let last = session.last, session.count > 1 else { return nil }
        let start = first.t
        let points: [SavedSession.Point]
        if sessionPointsCache.count == session.count,
           sessionOriginTime == start {
            points = sessionPointsCache
        } else {
            points = session.map { SavedSession.Point(t: $0.t.timeIntervalSince(start), bpm: $0.bpm) }
        }

        let rrPoints: [SavedSession.RRPoint]
        if sessionOriginTime == start,
           rrPointsCache.count == rrArchive.count {
            rrPoints = rrPointsCache
        } else {
            rrPoints = rrArchive
                .filter { $0.t >= start && $0.t <= last.t.addingTimeInterval(1) }
                .map { SavedSession.RRPoint(t: $0.t.timeIntervalSince(start),
                                            ms: Int($0.ms.rounded())) }
        }
        let motionShortStats = sleepMotionShortSummary()
        let liveIMU = imuFeatureSummary()
        // Historical-gravity motion evidence NEVER parses the archive on the
        // MainActor here (device-reported tab-switch freeze, 2026-07-09): it reads
        // the background-refreshed off-main cache (`cachedHistoricalMotion`, keyed by
        // this session's `start`). If the cache isn't warm for this session yet (its
        // first checkpoint, or a just-rolled segment) it falls back to nil -- the
        // HR-only sleep tier -- and kicks off an off-main refresh so the next
        // checkpoint has it (negligible for multi-hour sleep windows). Still skipped
        // entirely under thermal / Low-Power pressure (shouldDeferNonEssentialAnalysis),
        // mirroring the long-wear supervisor's own autosave/diagnostic deferral.
        let historicalIMU: HistoricalArchive.MotionFeatureSummary?
        if liveIMU.stillnessRatio != nil || powerThermalGovernor.shouldDeferNonEssentialAnalysis {
            historicalIMU = nil
        } else if cachedHistoricalMotionOrigin == start {
            historicalIMU = cachedHistoricalMotion
            refreshHistoricalMotionCache(start: start, end: last.t)
        } else {
            historicalIMU = nil
            refreshHistoricalMotionCache(start: start, end: last.t)
        }
        // The live 0x33 decoder still infers offset/endian/scale. Preserve those
        // values as diagnostics, but only validated historical gravity may
        // influence sleep/wake classification.
        let classifierIMUStillnessRatio = historicalIMU?.stillnessRatio
        let classifierIMUMovementIntensity = historicalIMU?.movementIntensity
        let motionEvidenceSource = historicalIMU != nil ? "historical_gravity" : sleepMotionSource
        let motionEvidenceValidated = historicalIMU?.lowMotionReady ?? false
        let sessionAggregateMatchesCache = sessionOriginTime == start
            && sessionPointsCache.count == session.count
            && sessionHeartRateAggregateCount == session.count
        let averageHR: Int
        let hrStandardDeviation: Double
        let minimumHR: Int
        if sessionAggregateMatchesCache, let sessionMinHeartRate {
            averageHR = sessionHeartRateTotal / max(sessionHeartRateAggregateCount, 1)
            hrStandardDeviation = sqrt(max(0, sessionHeartRateM2) / Double(sessionHeartRateAggregateCount))
            minimumHR = sessionMinHeartRate
        } else {
            averageHR = session.map(\.bpm).reduce(0, +) / max(session.count, 1)
            hrStandardDeviation = Self.standardDeviation(session.map { Double($0.bpm) })
            minimumHR = session.map(\.bpm).min() ?? averageHR
        }
        let restingHeartRate = restingHR ?? min(averageHR, minimumHR)
        let sleepWake = AtriaSleepWakeResearch.classify(duration: last.t.timeIntervalSince(start),
                                                        averageHR: averageHR,
                                                        restingHR: restingHeartRate,
                                                        imuStillnessRatio: classifierIMUStillnessRatio,
                                                        imuMovementIntensity: classifierIMUMovementIntensity,
                                                        strapSteps: strapStepResearchCount > 0 ? strapStepResearchCount : nil,
                                                        windowStart: start,
                                                        hrStandardDeviation: hrStandardDeviation)
        let respiratoryRate = sleepWake.state == "sleep_research" && hrvSnapshot?.isReady == true
            ? hrvSnapshot?.respiratoryRate
            : nil
        let profile = AthleteProfile.load()
        let activeCalories = activeCaloriesForSnapshot(rest: restingHeartRate,
                                                       profile: profile,
                                                       excludedIntervals: excludedIntervals)
        let caloriesConfidence: String? = session.count > 1 ? (profile.hasEnergyProfile ? "estimate" : "needs_profile") : nil
        return SavedSession(id: liveSessionID, start: start, end: last.t,
                            label: label.trimmingCharacters(in: .whitespaces), points: points,
                            hrv: hrv > 0 ? hrv : nil,
                            respiratoryRate: respiratoryRate,
                            rrPoints: rrPoints.isEmpty ? nil : rrPoints,
                            hrvReferenceValidated: false,
                            motionHintCount: sleepMotionHintCount,
                            motionHintKinds: sleepMotionHintKinds,
                            motionEvidenceSource: motionEvidenceSource,
                            motionEvidenceValidated: motionEvidenceValidated,
                            motionShortCount: motionShortStats.count > 0 ? motionShortStats.count : nil,
                            motionShortMean: motionShortStats.mean,
                            motionShortMin: motionShortStats.min,
                            motionShortMax: motionShortStats.max,
                            motionShortOverOneCount: motionShortStats.count > 0 ? motionShortStats.overOne : nil,
                            imuSampleCount: decodedIMUSampleCount > 0 ? decodedIMUSampleCount : nil,
                            imuFrameCount: protocolIMUFrameCount > 0 ? protocolIMUFrameCount : nil,
                            imuSampleRateHz: liveIMU.sampleRateHz,
                            imuScale: imuInferredScale,
                            imuEndian: imuInferredEndian,
                            imuStillnessRatio: liveIMU.stillnessRatio ?? historicalIMU?.stillnessRatio,
                            imuMovementIntensity: liveIMU.movementIntensity ?? historicalIMU?.movementIntensity,
                            imuActivityBursts: decodedIMUSampleCount > 0 ? imuActivityBurstCount : nil,
                            imuValidationState: decodedIMUSampleCount > 0 ? imuValidationState : nil,
                            strapStepResearchCount: strapStepResearchCount > 0 ? strapStepResearchCount : nil,
                            strapStepResearchAgreement: nil,
                            strapStepResearchState: strapStepResearchCount > 0 ? strapStepResearchState : nil,
                            sleepWakeResearchState: sleepWake.state == "learning" ? nil : sleepWake.state,
                            sleepWakeResearchConfidence: sleepWake.confidence == "none" ? nil : sleepWake.confidence,
                            sleepWakeResearchReason: sleepWake.reason,
                            sensorResearchProbeFrames: researchProbeFrameCount > 0 ? researchProbeFrameCount : nil,
                            spo2ResearchCandidateFrames: researchProbeOxygenCandidateFrames > 0 ? researchProbeOxygenCandidateFrames : nil,
                            skinTempResearchCandidateFrames: researchProbeTemperatureCandidateFrames > 0 ? researchProbeTemperatureCandidateFrames : nil,
                            skinTempResearchCandidateValueSum: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueSum : nil,
                            skinTempResearchCandidateValueCount: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueCount : nil,
                            biologicalSex: profile.biologicalSex,
                            activeCalories: activeCalories,
                            caloriesConfidence: caloriesConfidence,
                            hrRaw2A37: sessionRawHRNotifications,
                            hrAccepted: sessionAcceptedHRSamples,
                            hrZero: sessionZeroHRSamples,
                            hrArtifactHeld: sessionHeldArtifacts,
                            hrArtifactDropped: sessionDroppedArtifacts,
                            hrRawGaps: sessionRawHRGaps,
                            hrAcceptedGaps: sessionAcceptedHRGaps,
                            hrMaxRawGap: sessionMaxRawHRGap,
                            hrMaxAcceptedGap: sessionMaxAcceptedHRGap,
                            strengthSets: strengthSets.isEmpty ? nil : strengthSets,
                            excludedIntervals: excludedIntervals.isEmpty ? nil : excludedIntervals,
                            eventTimeZoneIdentifier: liveSessionEventTimeZoneIdentifier)
    }

    private func resetSessionMotionDiagnostics() {
        sleepMotionHintCount = 0
        sleepMotionHintKinds = "none"
        sleepMotionHintKindCounts.removeAll(keepingCapacity: true)
        sleepMotionShortValues.removeAll(keepingCapacity: true)
        sleepMotionSource = "unavailable"
        resetIMUFeatureStats()
    }

    private func recordIMUFeatures(_ decoded: AtriaIMUDecoder.DecodeResult) {
        let now = Date()
        if let previous = imuLastFrameAt {
            let delta = now.timeIntervalSince(previous)
            if delta > 0.02, delta < 10 {
                imuSampleRateHzSum += Double(decoded.samples.count) / delta
                imuSampleRateHzCount += 1
            }
        }
        imuLastFrameAt = now
        decodedIMUSampleCount += decoded.samples.count
        imuInferredScale = decoded.scale
        imuInferredEndian = decoded.endian.rawValue
        rollStrapStepResearchDayIfNeeded(now: now, currentSessionCount: strapStepResearchCount)
        let stepEstimate = AtriaStrapStepResearch.estimate(samples: decoded.samples,
                                                           sampleRateHz: imuFeatureSummary().sampleRateHz)
        strapStepResearchCount += stepEstimate.steps
        strapStepResearchPeakCount += stepEstimate.peaks
        strapStepResearchState = stepEstimate.state
        publishLiveStrapStepResearchIfNeeded(now: now)
        assignIfChanged(\.liveStrapStepResearchState, strapStepResearchState)
        imuStillnessRatioSum += decoded.stillnessRatio
        imuMovementIntensitySum += decoded.movementIntensity
        imuActivityBurstCount += decoded.activityBursts
        if decoded.gravityValidated {
            imuGravityValidatedFrameCount += 1
        }
        imuValidationState = imuGravityValidatedFrameCount > 0 ? "gravity_validated_research" : "research_unvalidated"
    }

    private func applyR10MotionSnapshot(_ snapshot: AtriaR10MotionPipeline.Snapshot) {
        let now = Date()
        let previousSteps = strapStepResearchCount
        rollStrapStepResearchDayIfNeeded(now: now, currentSessionCount: strapStepResearchCount)
        decodedIMUSampleCount = max(decodedIMUSampleCount, snapshot.samples)
        imuInferredScale = 4_096
        imuInferredEndian = AtriaIMUDecoder.Endian.little.rawValue
        imuStillnessRatioSum = snapshot.stillnessRatio * Double(max(1, snapshot.frames))
        imuMovementIntensitySum = snapshot.movementIntensity * Double(max(1, snapshot.frames))
        imuActivityBurstCount = snapshot.activityBursts
        imuGravityValidatedFrameCount = snapshot.gravityValidatedFrames
        imuSampleRateHzSum = Double(AtriaStrapPedometer.sampleRateHz)
        imuSampleRateHzCount = 1
        let reconciledTotals = Self.monotonicStrapStepTotals(
            currentSteps: strapStepResearchCount,
            currentRawSteps: strapStepResearchPeakCount,
            incomingSteps: snapshot.steps,
            incomingRawSteps: snapshot.rawSteps
        )
        // R10 work runs on its own serial queue and publishes back to the main
        // actor. A restore, reconnect, or explicit pipeline reset can therefore
        // leave a durable session prefix here while a delayed/connection-local
        // snapshot contains a smaller count. Never replace that prefix with the
        // lower snapshot. The pipeline remains responsible for adding future
        // motion to its seeded/committed prefix; this guard only prevents stale
        // state from moving daily and workout totals backwards.
        strapStepResearchCount = reconciledTotals.steps
        strapStepResearchPeakCount = reconciledTotals.rawSteps
        strapStepResearchState = snapshot.state
        publishLiveStrapStepResearchIfNeeded(now: now)
        assignIfChanged(\.liveStrapStepResearchState, snapshot.state)
        imuValidationState = "r10_fixed_layout_calibrating"
        if reconciledTotals.steps != previousSteps {
            let checkpointDue = Self.shouldCheckpointStrapSteps(
                currentSteps: reconciledTotals.steps,
                persistedSteps: lastActiveJournalSavedResearchAggregates.strapSteps,
                lastCheckpointAt: lastActiveJournalSaveAt,
                now: now
            )
            persistActiveSessionJournalIfNeeded(reason: "r10_step_update",
                                                force: checkpointDue)
            scheduleTrailingStrapStepCheckpoint(now: now,
                                                forceJustRequested: checkpointDue)
        }
    }

    /// Schedules the time half of the time+count checkpoint contract. The task
    /// is anchored to the earliest unsaved step and never postponed by later
    /// steps, so a short walk that ends below the count limit is still durable.
    /// If an incremental save is already in flight, retrying waits without doing
    /// I/O until that save settles.
    private func scheduleTrailingStrapStepCheckpoint(
        now: Date,
        forceJustRequested: Bool,
        retryAfterInFlightSave: Bool = false
    ) {
        guard strapStepResearchCount > lastActiveJournalSavedResearchAggregates.strapSteps else {
            activeJournalStepCheckpointTask?.cancel()
            activeJournalStepCheckpointTask = nil
            return
        }
        guard activeJournalStepCheckpointTask == nil else { return }

        let delay: TimeInterval
        if retryAfterInFlightSave {
            delay = 0.5
        } else if forceJustRequested {
            // The write started with the latest count. Recheck one complete
            // policy interval later only in case more steps arrived mid-save.
            delay = Self.strapStepCheckpointMaximumAge
        } else if let lastActiveJournalSaveAt {
            delay = max(0.05, Self.strapStepCheckpointMaximumAge
                - max(0, now.timeIntervalSince(lastActiveJournalSaveAt)))
        } else {
            delay = 0.05
        }

        activeJournalStepCheckpointTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.activeJournalStepCheckpointTask = nil
            let firedAt = Date()
            guard self.strapStepResearchCount
                    > self.lastActiveJournalSavedResearchAggregates.strapSteps else { return }
            if self.activeJournalSaveInFlight {
                self.scheduleTrailingStrapStepCheckpoint(
                    now: firedAt,
                    forceJustRequested: false,
                    retryAfterInFlightSave: true
                )
                return
            }
            let due = Self.shouldCheckpointStrapSteps(
                currentSteps: self.strapStepResearchCount,
                persistedSteps: self.lastActiveJournalSavedResearchAggregates.strapSteps,
                lastCheckpointAt: self.lastActiveJournalSaveAt,
                now: firedAt
            )
            if due {
                self.persistActiveSessionJournalIfNeeded(
                    reason: "r10_step_trailing_checkpoint",
                    force: true
                )
            }
            self.scheduleTrailingStrapStepCheckpoint(now: firedAt,
                                                     forceJustRequested: due)
        }
    }

    /// Returns true only for newly confirmed cumulative steps. A count limit
    /// bounds loss during brisk movement, while a time limit captures a small
    /// trailing remainder during slow movement. Future/corrupt checkpoint
    /// clocks fail safe by requesting one write; neither branch creates or
    /// extrapolates a step.
    nonisolated static func shouldCheckpointStrapSteps(
        currentSteps: Int,
        persistedSteps: Int,
        lastCheckpointAt: Date?,
        now: Date,
        maximumUnpersistedSteps: Int = strapStepCheckpointMaximumUnpersistedSteps,
        maximumCheckpointAge: TimeInterval = strapStepCheckpointMaximumAge
    ) -> Bool {
        let delta = currentSteps - max(0, persistedSteps)
        guard delta > 0 else { return false }
        if delta >= max(1, maximumUnpersistedSteps) { return true }
        guard let lastCheckpointAt else { return true }
        let age = now.timeIntervalSince(lastCheckpointAt)
        return age < 0 || age >= max(1, maximumCheckpointAge)
    }

    struct StrapStepTotals: Equatable {
        let steps: Int
        let rawSteps: Int
    }

    /// Reconciles an asynchronously delivered motion snapshot with the
    /// already-restored/session-persisted prefix. Counts may intentionally reset
    /// only when `resetLiveSessionState` starts a new persisted segment; within
    /// one live session they are cumulative and must be monotonic.
    nonisolated static func monotonicStrapStepTotals(currentSteps: Int,
                                                     currentRawSteps: Int,
                                                     incomingSteps: Int,
                                                     incomingRawSteps: Int) -> StrapStepTotals {
        StrapStepTotals(steps: max(0, max(currentSteps, incomingSteps)),
                        rawSteps: max(0, max(currentRawSteps, incomingRawSteps)))
    }

    private func imuFeatureSummary() -> (stillnessRatio: Double?, movementIntensity: Double?, sampleRateHz: Double?) {
        guard protocolIMUFrameCount > 0, decodedIMUSampleCount > 0 else { return (nil, nil, nil) }
        let frames = Double(max(r10MotionFrameCount > 0 ? r10MotionFrameCount : protocolIMUFrameCount, 1))
        let sampleRate = imuSampleRateHzCount > 0 ? imuSampleRateHzSum / Double(imuSampleRateHzCount) : nil
        return (imuStillnessRatioSum / frames, imuMovementIntensitySum / frames, sampleRate)
    }

    static func shouldPublishLiveStrapStepResearch(currentCount: Int,
                                                   publishedCount: Int,
                                                   lastPublishedAt: Date?,
                                                   now: Date,
                                                   force: Bool = false) -> Bool {
        if force { return true }
        guard currentCount != publishedCount else { return false }
        if publishedCount == 0, currentCount > 0 { return true }
        if abs(currentCount - publishedCount) >= liveStrapStepResearchPublishMinimumDelta { return true }
        guard let lastPublishedAt else { return true }
        return now.timeIntervalSince(lastPublishedAt) >= liveStrapStepResearchPublishMinimumInterval
    }

    nonisolated static func liveStrapStepResearchTrailingDelay(lastPublishedAt: Date?,
                                                               now: Date) -> TimeInterval {
        guard let lastPublishedAt else { return 0 }
        return max(0, liveStrapStepResearchPublishMinimumInterval
            - max(0, now.timeIntervalSince(lastPublishedAt)))
    }

    private func publishLiveStrapStepResearchIfNeeded(now: Date = Date(),
                                                      force: Bool = false) {
        rollStrapStepResearchDayIfNeeded(now: now, currentSessionCount: strapStepResearchCount)
        guard Self.shouldPublishLiveStrapStepResearch(currentCount: strapStepResearchCount,
                                                      publishedCount: liveStrapStepResearchCount,
                                                      lastPublishedAt: lastLiveStrapStepResearchPublishedAt,
                                                      now: now,
                                                      force: force) else {
            scheduleTrailingLiveStrapStepResearchPublish(now: now)
            return
        }
        pendingLiveStrapStepResearchPublishTask?.cancel()
        pendingLiveStrapStepResearchPublishTask = nil
        lastLiveStrapStepResearchPublishedAt = now
        assignIfChanged(\.liveStrapStepResearchCount, strapStepResearchCount)
        assignIfChanged(\.liveStrapStepResearchTodayCount,
                        Self.dayScopedStrapStepCount(sessionCount: strapStepResearchCount,
                                                     dayBaseline: strapStepResearchDayBaseline))
    }

    private func scheduleTrailingLiveStrapStepResearchPublish(now: Date) {
        guard strapStepResearchCount != liveStrapStepResearchCount else {
            pendingLiveStrapStepResearchPublishTask?.cancel()
            pendingLiveStrapStepResearchPublishTask = nil
            return
        }
        guard pendingLiveStrapStepResearchPublishTask == nil else { return }
        let delay = Self.liveStrapStepResearchTrailingDelay(
            lastPublishedAt: lastLiveStrapStepResearchPublishedAt,
            now: now
        )
        pendingLiveStrapStepResearchPublishTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            } else {
                await Task.yield()
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingLiveStrapStepResearchPublishTask = nil
            self.publishLiveStrapStepResearchIfNeeded()
        }
    }

    nonisolated static func dayScopedStrapStepCount(sessionCount: Int, dayBaseline: Int) -> Int {
        max(0, sessionCount - min(max(0, dayBaseline), max(0, sessionCount)))
    }

    private func rollStrapStepResearchDayIfNeeded(now: Date,
                                                  currentSessionCount: Int,
                                                  calendar: Calendar = .current) {
        let day = calendar.startOfDay(for: now)
        guard !calendar.isDate(day, inSameDayAs: strapStepResearchDay) else { return }
        strapStepResearchDay = day
        strapStepResearchDayBaseline = max(0, currentSessionCount)
        assignIfChanged(\.liveStrapStepResearchTodayCount, 0)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count >= 2 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }

    private func resetIMUFeatureStats(resetResearchAggregates: Bool = true) {
        pendingLiveStrapStepResearchPublishTask?.cancel()
        pendingLiveStrapStepResearchPublishTask = nil
        r10MotionPipeline.resetSynchronously()
        decodedIMUSampleCount = 0
        imuGravityValidatedFrameCount = 0
        imuStillnessRatioSum = 0
        imuMovementIntensitySum = 0
        imuActivityBurstCount = 0
        imuValidationState = "unavailable"
        imuSampleRateHzSum = 0
        imuSampleRateHzCount = 0
        imuLastFrameAt = nil
        imuInferredScale = nil
        imuInferredEndian = nil
        r10MotionFrameCount = 0
        lastR10MotionFrameAt = nil
        assignIfChanged(\.liveStrapMotionCapturedAt, nil)
        strapStepResearchCount = 0
        strapStepResearchDay = Calendar.current.startOfDay(for: Date())
        strapStepResearchDayBaseline = 0
        assignIfChanged(\.liveStrapStepResearchTodayCount, 0)
        strapStepResearchPeakCount = 0
        strapStepResearchState = "research_unvalidated"
        publishLiveStrapStepResearchIfNeeded(force: true)
        lastLiveStrapStepResearchPublishedAt = nil
        assignIfChanged(\.liveStrapStepResearchState, "research_unvalidated")
        if resetResearchAggregates {
            researchProbeFrameCount = 0
            researchProbeOxygenCandidateFrames = 0
            researchProbeTemperatureCandidateFrames = 0
            researchProbeTemperatureCandidateValueSum = 0
            researchProbeTemperatureCandidateValueCount = 0
        }
    }

    private func resetSessionSampleDiagnostics() {
        sessionRawHRNotifications = 0
        sessionAcceptedHRSamples = 0
        sessionZeroHRSamples = 0
        sessionHeldArtifacts = 0
        sessionDroppedArtifacts = 0
        sessionRawHRGaps = 0
        sessionAcceptedHRGaps = 0
        sessionMaxRawHRGap = 0
        sessionMaxAcceptedHRGap = 0
        lastRawHRNotificationAt = nil
    }

    private func applyCoexistenceRiskForDebugLaunch(arguments: [String]) {
#if DEBUG
        guard let riskIndex = arguments.firstIndex(of: "--atria-force-coexistence-risk"),
              arguments.indices.contains(arguments.index(after: riskIndex)) else { return }
        let value = arguments[arguments.index(after: riskIndex)]
        guard let risk = OfficialAppCoexistenceRisk(rawValue: value) else {
            AtriaDebugLog("ATRIADBG official_app_coexistence_debug status=invalid value=%@", value)
            return
        }
        persistOfficialAppCoexistenceRisk(risk, reason: "debug_launch_arg")
        AtriaDebugLog("ATRIADBG official_app_coexistence_debug status=forced value=%@", value)
#endif
    }

    private func applyOfflineSyncForDebugLaunch(arguments: [String]) {
#if DEBUG
        guard arguments.contains("--atria-force-offline-sync") else { return }
        let reason = value(after: "--atria-force-offline-sync-reason",
                           in: arguments) ?? "debug_launch_arg"
        let started = requestOfflineHistoricalSyncIfNeeded(reason: reason, force: true)
        AtriaDebugLog("ATRIADBG offline_sync_debug status=%@ reason=%@",
                      started ? "started" : "not_started",
                      reason)
#endif
    }
}

// MARK: - CBCentralManagerDelegate
extension AtriaBLEManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // CORE FIX (launch-start timing): issue the standing connect to the
        // saved strap directly on centralQueue, synchronously, BEFORE hopping
        // to @MainActor. At cold start the main actor can be saturated by the
        // launch render + deferred-load work for seconds; central.connect()
        // and retrievePeripherals(withIdentifiers:) are CoreBluetooth calls
        // safe to make from the manager's own delegate queue and must not
        // wait behind that UI work. The later @MainActor hop only publishes
        // state (peripheral, status, pendingKnownReconnectStartedAt) — it
        // never gates the radio's pursuit of the strap. This keeps the single
        // existing launch path (retrieve saved identifier + central.connect,
        // no scan) — no new reconnect variant is introduced.
        var earlyPendingConnect: CBPeripheral?
        if central.state == .poweredOn {
            let defaults = UserDefaults.standard
            // Connection-diagnostics logging (2026-07-06): this precheck used
            // to log ONLY the success branch, so the two most common real-world
            // causes of "auto-connect not working" -- no saved strap identifier
            // yet, and a saved identifier iOS can no longer retrieve (unpaired /
            // out of range at boot) -- left no trace in the ATRIADBG connection
            // timeline. Log each branch explicitly (zero runtime cost). The
            // connect call and its success line are byte-for-byte unchanged.
            if let uuidString = defaults.string(forKey: LinkDefaults.savedPeripheralUUID),
               let uuid = UUID(uuidString: uuidString) {
                if let saved = central.retrievePeripherals(withIdentifiers: [uuid]).first {
                    if saved.state != .connected {
                        central.connect(saved, options: nil)
                        earlyPendingConnect = saved
                        AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=powered_on_precheck action=pending_connect_early")
                    } else {
                        AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=powered_on_precheck action=already_connected saved_uuid=1")
                    }
                } else {
                    AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=powered_on_precheck action=retrieve_empty saved_uuid=1")
                }
            } else {
                AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=powered_on_precheck action=no_saved_uuid saved_uuid=0")
            }
        }
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                assignIfChanged(\.bluetoothPermissionDenied, false)
                assignIfChanged(\.isBluetoothReady, true)
                let reason = pendingScanReason ?? "central_powered_on"
                pendingScanReason = nil
                if let peripheral, peripheral.state == .connected {
                    peripheral.discoverServices(discoveryServicesForCurrentMode)
                } else if let earlyPendingConnect {
                    // The standing connect was already issued synchronously
                    // above; this only publishes bookkeeping/UI state for it.
                    earlyPendingConnect.delegate = self
                    self.peripheral = earlyPendingConnect
                    assignIfChanged(\.deviceName, earlyPendingConnect.name ?? deviceName)
                    recomputeConnectionStatus(reason: "event")
                    recordLinkAttempt(reason: "powered_on_\(reason)", peripheral: earlyPendingConnect)
                    markPendingKnownReconnect(reason: "powered_on_\(reason)")
                    AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=powered_on_%@ action=pending_connect", reason)
                } else if reconnectToSavedPeripheralIfPossible(reason: "powered_on_\(reason)") {
                    // Fallback path (e.g. saved peripheral was already connected,
                    // or became available only after the early precheck ran).
                    // Re-armed a standing pending connection to the known strap.
                    // No scan needed — iOS reconnects when it is in range.
                } else {
                    // No saved strap yet (first-time setup) — scan to find one.
                    startScan(reason: reason)
                }
                self.recomputeConnectionStatus(reason: "central_powered_on")
            case .poweredOff:
                assignIfChanged(\.bluetoothPermissionDenied, false)
                assignIfChanged(\.isBluetoothReady, false)
                preserveLongWearRangeLossRecovery(reason: "central_powered_off")
                self.isActivelyScanning = false
                self.recomputeConnectionStatus(reason: "central_powered_off")
            case .unauthorized:
                assignIfChanged(\.bluetoothPermissionDenied, true)
                assignIfChanged(\.isBluetoothReady, false)
                preserveLongWearRangeLossRecovery(reason: "central_unauthorized")
                self.isActivelyScanning = false
                self.recomputeConnectionStatus(reason: "central_unauthorized")
            default:
                assignIfChanged(\.bluetoothPermissionDenied, false)
                assignIfChanged(\.isBluetoothReady, false)
                preserveLongWearRangeLossRecovery(reason: "central_unavailable")
                self.isActivelyScanning = false
                self.recomputeConnectionStatus(reason: "central_unavailable")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        AtriaDebugLog("ATRIADBG ble_restore peripherals=%d", restored.count)
        guard let restoredPeripheral = restored.first else { return }
        Task { @MainActor in
            if self.forceFreshScanOnRestore {
                AtriaDebugLog("ATRIADBG ble_restore status=reuse_restored reason=fresh_scan_deferred peripherals=%d standard_hr_only=%d",
                      restored.count,
                      self.standardHROnlyMode ? 1 : 0)
            } else if self.standardHROnlyMode {
                AtriaDebugLog("ATRIADBG ble_restore status=reuse_restored reason=standard_hr_only peripherals=%d",
                      restored.count)
            }
            restoredPeripheral.delegate = self
            self.peripheral = restoredPeripheral
            self.assignIfChanged(\.deviceName, restoredPeripheral.name ?? self.deviceName)
            switch restoredPeripheral.state {
            case .connected:
                let savedPeripheralIdentifier = UserDefaults.standard
                    .string(forKey: LinkDefaults.savedPeripheralUUID)
                    .flatMap(UUID.init(uuidString:))
                self.batteryConnectionRestoredSamePeripheral =
                    Self.batteryRestorationPreservesNotificationEpoch(
                        restoredPeripheralIdentifier: restoredPeripheral.identifier,
                        savedPeripheralIdentifier: savedPeripheralIdentifier,
                        restoredPeripheralIsConnected: true
                    )
                self.clearPendingKnownReconnect(reason: "state_restore_connected")
                self.recomputeConnectionStatus(reason: "event")
                self.reconnectWatchdogTask?.cancel()
                self.connectedAt = Date()
                self.protectedR10ActivationGraceTask?.cancel()
                self.protectedR10ActivationGraceTask = nil
                self.protectedR10ActivationSent = false
                self.protectedR10ActivationAt = nil
                self.protectedR10FramesAfterActivation = 0
                self.protectedR10MissingFrameTask?.cancel()
                self.protectedR10MissingFrameTask = nil
                self.protectedR10StabilityTask?.cancel()
                self.protectedR10StabilityTask = nil
                self.recordLinkObservedConnected(reason: "state_restore_connected", peripheral: restoredPeripheral)
                self.scheduleRangeLossBackfillIfNeeded(reason: "state_restore_connected")
                if self.beginRetiredBatteryProbeRecoveryIfNeeded(restoredPeripheral) {
                    return
                }
                if self.motionHandshakeDiagnostic != nil {
                    self.recordMotionHandshakeEvidence(event: "restored_connected")
                    restoredPeripheral.discoverServices([Self.UUIDs.strapService])
                } else {
                    restoredPeripheral.discoverServices(self.discoveryServicesForCurrentMode)
                    self.resumeProtectedR10FromRestoredCache(restoredPeripheral)
                }
                AtriaDebugLog("ATRIADBG ble_restore status=connected name=%@", self.deviceName)
            case .connecting:
                self.batteryConnectionRestoredSamePeripheral = false
                self.recomputeConnectionStatus(reason: "event")
                self.markPendingKnownReconnect(reason: "state_restore_connecting")
                self.startReconnectWatchdog(reason: "state_restore_connecting", peripheral: restoredPeripheral)
                AtriaDebugLog("ATRIADBG ble_restore status=connecting name=%@", self.deviceName)
            default:
                self.batteryConnectionRestoredSamePeripheral = false
                self.recomputeConnectionStatus(reason: "event")
                self.recordLinkAttempt(reason: "state_restore", peripheral: restoredPeripheral)
                self.markPendingKnownReconnect(reason: "state_restore")
                central.connect(restoredPeripheral, options: nil)
                self.startReconnectWatchdog(reason: "state_restore", peripheral: restoredPeripheral)
                AtriaDebugLog("ATRIADBG ble_restore status=reconnect name=%@", self.deviceName)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        // Unfiltered scan: only attach if this is the strap (by service or name).
        let isStrap = advServices.contains(UUIDs.strapService)
            || advServices.contains(UUIDs.heartRateService)
            || (advName?.uppercased().contains("WHO") ?? false)
        guard isStrap else { return }
        let name = advName ?? "Strap"
        Task { @MainActor in
            guard self.peripheral == nil else { return }   // first match wins
            self.lastScanMatchAt = Date()
            AtriaDebugLog("ATRIADBG ble_scan status=matched name=%@ rssi=%@ services=%d",
                  name,
                  RSSI,
                  advServices.count)
            self.attach(to: peripheral, name: name)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        proprietaryFrameReassembler.reset()
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        Task { @MainActor in
            self.batteryConnectionRestoredSamePeripheral = false
            self.recentReconnectBatteryBaselineProjectionPublished = false
            if UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending) {
                failProprietaryBatteryRefresh(reason: "stale_pending_request_after_connect")
            }
            reconnectWatchdogTask?.cancel()
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            isActivelyScanning = false
            recomputeConnectionStatus(reason: "did_connect")
            // A reconnect is a new trust boundary. Proprietary restoration
            // traffic has produced false 0/100 values that otherwise survive in
            // memory across the link drop. Keep a credible mid-range value as a
            // visibly cached baseline, but never carry a boundary sentinel into
            // the new connection without a fresh stable series.
            let now = Date()
            self.batteryBaselineValidationStartedAt = now
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)
            defaults.set("new_link_unconfirmed",
                         forKey: BatteryDefaults.notificationLastError)
            let credibleLevel = defaults.object(forKey: BatteryDefaults.credibleLevel) as? Int
            let credibleAt = (defaults.object(forKey: BatteryDefaults.credibleAt) as? Double)
                .map(Date.init(timeIntervalSince1970:))
            let reconnectLevel = Self.reconnectBatteryDisplayLevel(
                currentLevel: self.batteryLevel,
                credibleLevel: credibleLevel,
                credibleAt: credibleAt,
                now: now,
                maxAge: Self.activeBatterySubscriptionBaselineMaximumAge
            )
            if reconnectLevel != self.batteryLevel {
                self.assignIfChanged(\.batteryLevel, reconnectLevel)
                self.lastAcceptedBatteryLevelAt = reconnectLevel >= 0 ? credibleAt : nil
            }
            self.pendingBatteryDropCandidate = nil
            self.batteryNotificationEpochHadRejectedCallback = false
            self.displayedBatteryLevelIsCached = reconnectLevel >= 0
            self.batteryReadingIsRecentBaseline = reconnectLevel >= 0
            defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
            defaults.set(true, forKey: BatteryDefaults.requiresFreshConfirmation)
            assignIfChanged(\.batteryIsCharging, false)
            assignIfChanged(\.batteryChargeStatus, .levelOnly)
            recordBatteryChargeEvidence(batteryChargeStatus, reason: "did_connect")
            connectedAt = Date()
            protectedR10ActivationGraceTask?.cancel()
            protectedR10ActivationGraceTask = nil
            protectedR10ActivationSent = false
            protectedR10ActivationAt = nil
            protectedR10FramesAfterActivation = 0
            protectedR10MissingFrameTask?.cancel()
            protectedR10MissingFrameTask = nil
            protectedR10StabilityTask?.cancel()
            protectedR10StabilityTask = nil
            dbgMTU = mtu
            recordLinkConnected(peripheral: peripheral)
            if beginRetiredBatteryProbeRecoveryIfNeeded(peripheral) {
                return
            }
            if motionHandshakeDiagnostic != nil {
                recordMotionHandshakeEvidence(event: "connected",
                                              detail: "discover_stream5_service_only")
                peripheral.discoverServices([Self.UUIDs.strapService])
            } else {
                peripheral.discoverServices(discoveryServicesForCurrentMode)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        proprietaryFrameReassembler.reset()
        Task { @MainActor in
            self.batteryConnectionRestoredSamePeripheral = false
            self.recentReconnectBatteryBaselineProjectionPublished = false
            if proprietaryBatteryRefreshPhase != .idle
                || UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending) {
                failProprietaryBatteryRefresh(reason: "link_disconnected_during_request")
            }
            let wasRealtimeArmedAtDisconnect = realtimeArmed
            let wasR10RetryActiveAtDisconnect = r10ArmRetryTask != nil
            let protectedActivationWasSent = protectedR10ActivationSent
            let protectedFrames = protectedR10FramesAfterActivation
            protectedR10ActivationGraceTask?.cancel()
            protectedR10ActivationGraceTask = nil
            protectedR10MissingFrameTask?.cancel()
            protectedR10MissingFrameTask = nil
            protectedR10StabilityTask?.cancel()
            protectedR10StabilityTask = nil
            protectedR10PassiveReprobeTimeoutTask?.cancel()
            protectedR10PassiveReprobeTimeoutTask = nil
            recomputeConnectionStatus(reason: "event")
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            batteryConfirmationReadTask?.cancel()
            batteryConfirmationReadTask = nil
            batteryConfirmationReadLevel = nil
            batteryLevelCharacteristic = nil
            batteryStatusCharacteristic = nil
            lastBatteryReadRequestedAt = nil
            realtimeArmed = false        // re-arm realtime after reconnect
            r10ArmRetryTask?.cancel()
            stopR10LivenessWatchdog(reason: "did_disconnect")
            stopProtocolHeartbeat()
            proprietaryNotifyFallbackTask?.cancel()
            proprietaryNotifyFallbackTask = nil
            activeProprietaryNotifyUUIDs.removeAll()
            strapStream5NotifyConfirmed = false
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: BatteryDefaults.notificationLeaseAt)
            defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)
            defaults.set("link_disconnected",
                         forKey: BatteryDefaults.notificationLastError)
            let disconnects = defaults.integer(forKey: LinkDefaults.disconnects) + 1
            let errorText = error?.localizedDescription ?? "nil"
            defaults.set(disconnects, forKey: LinkDefaults.disconnects)
            defaults.set("disconnected", forKey: LinkDefaults.lastStatus)
            defaults.set("did_disconnect", forKey: LinkDefaults.lastReason)
            defaults.set(errorText, forKey: LinkDefaults.lastError)
            let connectedDuration = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            let disconnectNow = Date()
            let wasUserRequestedDisconnect = userRequestedDisconnect
            let atriaOwnedOfflineSyncDisconnect = offlineHistoricalSyncInProgress
                || historyOnlyProbeEnabled
                || historyOnlyProbeMode
            let passiveReprobeAttemptAt = (defaults.object(
                forKey: Self.protectedR10PassiveReprobeAttemptAtKey
            ) as? Double).map(Date.init(timeIntervalSince1970:))
            let passiveReprobeDuration = passiveReprobeAttemptAt.map {
                disconnectNow.timeIntervalSince($0)
            }
            if Self.shouldAbortProtectedR10PassiveReprobeForDisconnect(
                reprobePending: defaults.bool(forKey: Self.protectedR10PassiveReprobePendingKey),
                userRequestedDisconnect: wasUserRequestedDisconnect,
                atriaOwnedOfflineSyncDisconnect: atriaOwnedOfflineSyncDisconnect,
                reprobeDuration: passiveReprobeDuration
            ) {
                let failures = defaults.integer(
                    forKey: Self.protectedR10PassiveReprobeFailureCountKey
                ) + 1
                defaults.set(failures,
                             forKey: Self.protectedR10PassiveReprobeFailureCountKey)
                defaults.set(false,
                             forKey: Self.protectedR10PassiveReprobePendingKey)
                defaults.set(true,
                             forKey: Self.protectedR10StreamSuppressedKey)
                defaults.set("passive_reprobe_short_disconnect",
                             forKey: Self.protectedR10DisconnectStormReasonKey)
                defaults.set("passive_reprobe_failed_hr_preserved",
                             forKey: RadioDefaults.passiveR10Status)
                AtriaDebugLog("ATRIADBG protected_r10 status=passive_reprobe_failed reprobe_s=%.1f connected_s=%.1f failures=%d action=resuppress_stream5_before_reconnect_backoff_no_command",
                              passiveReprobeDuration ?? -1,
                              connectedDuration,
                              failures)
            }
            let previousProtectedEarlyDisconnects = defaults.integer(
                forKey: Self.protectedR10EarlyDisconnectsKey
            )
            if motionHandshakeDiagnostic == nil,
               protectedActivationWasSent,
               !wasUserRequestedDisconnect,
               !atriaOwnedOfflineSyncDisconnect,
               connectedDuration > 0,
               connectedDuration <= Self.protectedR10EarlyDisconnectWindow {
                let early = previousProtectedEarlyDisconnects + 1
                defaults.set(early, forKey: Self.protectedR10EarlyDisconnectsKey)
                AtriaDebugLog("ATRIADBG protected_r10 status=early_disconnect count=%d duration_s=%.1f frames=%d",
                              early, connectedDuration, protectedFrames)
                if Self.shouldLatchProtectedR10RollbackForEarlyDisconnect(
                    activationSent: protectedActivationWasSent,
                    connectedDuration: connectedDuration,
                    previousEarlyDisconnects: previousProtectedEarlyDisconnects
                ) {
                    latchProtectedR10Rollback(reason: "repeated_early_disconnects")
                }
            }
            if motionHandshakeDiagnostic != nil {
                recordMotionHandshakeEvidence(
                    event: "disconnected",
                    detail: String(format: "duration_%.1fs_error_%@", connectedDuration, errorText)
                )
            }
            defaults.set(connectedDuration, forKey: "atria.ble.lastConnectedDuration")
            defaults.set(lastRawHRNotificationAt.map { disconnectNow.timeIntervalSince($0) } ?? -1,
                         forKey: "atria.ble.disconnectRawHRAge")
            defaults.set(lastR10MotionFrameAt.map { disconnectNow.timeIntervalSince($0) } ?? -1,
                         forKey: "atria.ble.disconnectR10Age")
            defaults.set(offlineHistoricalSyncInProgress,
                         forKey: "atria.ble.disconnectOfflineSyncActive")
            defaults.set(wasRealtimeArmedAtDisconnect,
                         forKey: "atria.ble.disconnectRealtimeArmed")
            defaults.set(wasR10RetryActiveAtDisconnect,
                         forKey: "atria.ble.disconnectR10RetryActive")
            defaults.set(disconnectNow.timeIntervalSince1970,
                         forKey: "atria.ble.lastDisconnectDiagnosticAt")
            let useFreshScan = forceFreshScanAfterDisconnect
            let reconnectPolicy = useFreshScan ? "fresh_scan" : "reconnect_same_peripheral"
            forceFreshScanAfterDisconnect = false
            if wasUserRequestedDisconnect {
                sessionAwaitingUnexpectedReconnect = false
            }
            if atriaOwnedOfflineSyncDisconnect {
                AtriaDebugLog("ATRIADBG official_app_coexistence status=ignored reason=atria_owned_offline_sync_disconnect action=keep_current_risk")
            } else if !wasUserRequestedDisconnect && connectedDuration > 0 && connectedDuration < 90 {
                persistOfficialAppCoexistenceRisk(.suspected, reason: "short_disconnect_after_connect")
            }
            let activeExplicitWorkout = AtriaPendingWorkoutIntent.isActiveForBLEContinuity()
            let shouldPreserveLongWearSession = Self.shouldPreserveSessionOnUnexpectedDisconnect(
                longWearEnabled: longWearModeEnabled,
                activeExplicitWorkout: activeExplicitWorkout,
                userRequestedDisconnect: wasUserRequestedDisconnect
            )
            userRequestedDisconnect = false
            connectedAt = nil
            txCharacteristic = nil
            heartRateCharacteristic = nil
            lastMissingHeartRateDiscoveryAt = nil
            dbgTxReady = false
            // Don't fragment long-wear runs on transient lifecycle/radio drops.
            // The active journal is enough durability for a reconnect; the
            // session should only be finished on explicit stop or long-gap roll.
            var autoSaveStatus = "skipped"
            var autoSaveSamples = session.count
            var autoSaveDuration = 0
            if shouldPreserveLongWearSession {
                sessionAwaitingUnexpectedReconnect = !wasUserRequestedDisconnect
                preserveLongWearRangeLossRecovery(reason: "disconnect")
                autoSaveStatus = session.isEmpty ? "skipped_continuity_empty" : (activeExplicitWorkout
                    ? "checkpointed_explicit_workout_continuity"
                    : "checkpointed_continuity")
                autoSaveDuration = max(0, Int(((session.last?.t ?? sessionStart).timeIntervalSince(sessionStart)).rounded()))
            } else if session.count >= autoSaveMinSamples,
               let saved = finishSession(label: captureLabel.isEmpty ? "Auto-saved" : captureLabel) {
                if persistFinishedSession(saved, reason: "disconnect_auto_save") {
                    autoSaveStatus = "saved"
                } else {
                    autoSaveStatus = "store_failed"
                }
                autoSaveSamples = saved.points.count
                autoSaveDuration = Int(saved.duration.rounded())
            } else if clearUnsavableActiveJournalIfNeeded(reason: "disconnect_unsavable") {
                autoSaveStatus = "cleared_unsavable"
                autoSaveSamples = session.count
                autoSaveDuration = max(0, Int(((session.last?.t ?? sessionStart).timeIntervalSince(sessionStart)).rounded()))
            }
            defaults.set(autoSaveStatus, forKey: LinkDefaults.lastAutoSaveStatus)
            defaults.set(autoSaveSamples, forKey: LinkDefaults.lastAutoSaveSamples)
            defaults.set(autoSaveDuration, forKey: LinkDefaults.lastAutoSaveDuration)
            AtriaDebugLog("ATRIADBG ble_link status=disconnected reason=did_disconnect error=%@ disconnects=%d autosave=%@ samples=%d duration_s=%d action=%@",
                  errorText,
                  disconnects,
                  autoSaveStatus,
                  autoSaveSamples,
                  autoSaveDuration,
                  reconnectPolicy)
            if wasUserRequestedDisconnect {
                if self.peripheral === peripheral {
                    self.peripheral = nil
                }
                recomputeConnectionStatus(reason: "event")
                AtriaDebugLog("ATRIADBG ble_link status=disconnected reason=user_disconnect action=stay_disconnected")
                return
            }
            if shouldPreserveLongWearSession,
               !activeExplicitWorkout,
               defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) {
                let recoveryReason = defaults.string(
                    forKey: OfflineSyncDefaults.rangeLossBackfillReason
                ) ?? "long_wear_range_loss"
                if requestOfflineHistoricalSyncIfNeeded(reason: recoveryReason) {
                    recomputeConnectionStatus(reason: "offline_history_first_reconnect")
                    AtriaDebugLog("ATRIADBG offline_sync status=history_first_reconnect reason=%@ action=own_next_connection_then_restore_protected_hr_r10",
                                  recoveryReason)
                    return
                }
            }
            if useFreshScan {
                if self.peripheral === peripheral {
                    self.peripheral = nil
                }
                recomputeConnectionStatus(reason: "event")
                let freshReason = longWearModeEnabled ? "long_wear_disconnect" : "stale_data_recovery"
                // Even on a forced fresh recovery, prefer a standing pending connect
                // to the KNOWN strap over scanning — it reconnects without giving up.
                if reconnectToSavedPeripheralIfPossible(reason: "\(freshReason)_known_strap") {
                    return
                }
                AtriaDebugLog("ATRIADBG ble_link status=disconnected reason=%@ action=fresh_scan",
                      freshReason)
                startScan(reason: freshReason)
                return
            }
            // Auto-reconnect: keep the strap connected as it moves in/out of range.
            recordLinkAttempt(reason: "did_disconnect_reconnect", peripheral: peripheral)
            markPendingKnownReconnect(reason: "did_disconnect_reconnect")
            central.connect(peripheral, options: nil)
            startReconnectWatchdog(reason: "did_disconnect_reconnect", peripheral: peripheral)
            recomputeConnectionStatus(reason: "event")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        proprietaryFrameReassembler.reset()
        Task { @MainActor in
            reconnectWatchdogTask?.cancel()
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            recordLinkFailure(reason: "did_fail_to_connect", error: error)
            connectedAt = nil
            self.realtimeArmed = false
            self.r10ArmRetryTask?.cancel()
            self.stopProtocolHeartbeat()
            self.proprietaryNotifyFallbackTask?.cancel()
            self.proprietaryNotifyFallbackTask = nil
            self.activeProprietaryNotifyUUIDs.removeAll()
            self.strapStream5NotifyConfirmed = false
            self.txCharacteristic = nil
            self.heartRateCharacteristic = nil
            self.lastMissingHeartRateDiscoveryAt = nil
            self.dbgTxReady = false
            let savedUUID = UserDefaults.standard.string(forKey: LinkDefaults.savedPeripheralUUID)
                .flatMap(UUID.init(uuidString:))
            let disposition = Self.failedConnectRecoveryDisposition(
                isSavedPeripheral: savedUUID == peripheral.identifier,
                isActuallyConnecting: peripheral.state == .connecting)
            switch disposition {
            case .reconnectKnownAfterBackoff:
                self.peripheral = peripheral
                peripheral.delegate = self
                self.recomputeConnectionStatus(reason: "event")
                self.requestFreshScanReconnect(peripheral: peripheral,
                                               reason: "did_fail_to_connect_recovery")
            case .waitForExistingConnect:
                self.peripheral = peripheral
                peripheral.delegate = self
                self.recomputeConnectionStatus(reason: "event")
                AtriaDebugLog("ATRIADBG ble_link status=failed reason=did_fail_to_connect action=wait_existing_connect")
            case .scan:
                if self.peripheral === peripheral {
                    self.peripheral = nil
                }
                self.recomputeConnectionStatus(reason: "event")
                self.startScan(reason: "did_fail_to_connect_recovery")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension AtriaBLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            self.recordLinkObservedConnected(reason: "service_discovery", peripheral: peripheral)
        }
        for service in peripheral.services ?? [] {
            let characteristics: [CBUUID]?
            if motionHandshakeDiagnostic != nil {
                switch service.uuid {
                case Self.UUIDs.strapService:
                    characteristics = motionHandshakeDiagnostic?.sendSingleR10Activation == true
                        ? [Self.UUIDs.strapStream5, Self.UUIDs.strapTX]
                        : [Self.UUIDs.strapStream5]
                case Self.UUIDs.heartRateService:
                    characteristics = [Self.UUIDs.heartRateMeasure]
                default:
                    characteristics = nil
                }
            } else if standardHROnlyMode, !historyOnlyProbeMode {
                characteristics = Self.protectedStandardHRCharacteristics(
                    for: service.uuid,
                    streamSuppressed: protectedR10StreamSuppressed
                )
            } else {
                characteristics = Self.discoveryCharacteristics(for: service.uuid)
            }
            guard let characteristics else { continue }
            if service.uuid == Self.UUIDs.strapService {
                Task { @MainActor in
                    if self.strapModel == .unknown, !self.debugForceUnknownStrapGeneration {
                        self.strapModel = .strap4Class
                        AtriaDebugLog("ATRIADBG model_gate status=assume_4_class reason=proprietary_service service=%@", service.uuid.uuidString)
                    }
                }
            }
            peripheral.discoverCharacteristics(characteristics, for: service)
        }
        // A strap that attached via name/HR-service matching but does NOT expose
        // the 4.0-class 61080001 service is likely newer hardware (5.0/MG). It must
        // surface as unknown — never silently inherit strap4Class capabilities.
        let serviceUUIDs = (peripheral.services ?? []).map(\.uuid)
        if !serviceUUIDs.contains(Self.UUIDs.strapService) {
            let serviceList = serviceUUIDs.map(\.uuidString).joined(separator: ",")
            Task { @MainActor in
                if self.strapModel == .unknown {
                    AtriaDebugLog("ATRIADBG model_gate status=unrecognized_service reason=no_4_class_service services=%@", serviceList)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if motionHandshakeDiagnostic != nil {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.UUIDs.strapStream5,
                   characteristic.properties.contains(.notify) {
                    if !characteristic.isNotifying {
                        peripheral.setNotifyValue(true, for: characteristic)
                        Task { @MainActor in
                            self.recordMotionHandshakeEvidence(event: "stream5_notify_requested")
                        }
                    } else {
                        Task { @MainActor in
                            self.recordMotionHandshakeEvidence(event: "stream5_already_notifying")
                            self.scheduleMotionHandshakeStandardHRAddition(peripheral: peripheral)
                        }
                    }
                } else if characteristic.uuid == Self.UUIDs.heartRateMeasure {
                    Task { @MainActor in
                        self.heartRateCharacteristic = characteristic
                        self.recordMotionHandshakeEvidence(event: "hr_characteristic_discovered")
                    }
                    if characteristic.properties.contains(.notify), !characteristic.isNotifying {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                } else if characteristic.uuid == Self.UUIDs.strapTX,
                          self.motionHandshakeDiagnostic?.sendSingleR10Activation == true {
                    Task { @MainActor in
                        self.txCharacteristic = characteristic
                        self.recordMotionHandshakeEvidence(event: "activation_tx_discovered",
                                                           detail: "write_without_response_\(characteristic.properties.contains(.writeWithoutResponse) ? 1 : 0)")
                    }
                }
            }
            return
        }
        var foundTX: CBCharacteristic?
        var foundHeartRateCharacteristic: CBCharacteristic?
        var foundBatteryLevelCharacteristic: CBCharacteristic?
        var foundBatteryStatusCharacteristic: CBCharacteristic?
        var radioCounters: [(key: String, reason: String)] = []
        var skippedCustomNotify = false
        var usedStandardHROnly = false
        var requestedCustomNotifyCount = 0
        var passiveR10AlreadyNotifying = false
        let discoveryUsesProtectedStandardHR = Self.discoveryShouldUseProtectedStandardHR(
            standardSnapshot: standardHROnlyMode,
            historyOnlyProbeMode: historyOnlyProbeMode
        )
        let alreadyActiveProprietaryNotifications = discoveryUsesProtectedStandardHR
            ? Set<CBUUID>()
            : Self.alreadyActiveProprietaryNotifications(
                (service.characteristics ?? []).map { ($0.uuid, $0.isNotifying) }
            )
        for ch in service.characteristics ?? [] {
            if ch.uuid == Self.UUIDs.strapRX,
               UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending) {
                Task { @MainActor in
                    self.handleProprietaryBatteryResponseCharacteristic(ch,
                                                                        peripheral: peripheral)
                }
                continue
            }
            switch ch.uuid {
            case UUIDs.heartRateMeasure, UUIDs.batteryLevel, UUIDs.batteryLevelStatus:
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    if ch.uuid == UUIDs.heartRateMeasure {
                        // Sparse duty cycle keeps HR notify OFF across reconnects.
                        // The independent 2A19 subscription remains safe to keep.
                        Task { @MainActor in
                            if self.dutyCycleState != .sparseSentinel {
                                if !ch.isNotifying {
                                    peripheral.setNotifyValue(true, for: ch)
                                }
                            } else {
                                AtriaDebugLog("ATRIADBG duty_cycle action=skip_hr_notify_subscribe reason=reconnect_sparse")
                            }
                        }
                    } else if ch.uuid == UUIDs.batteryLevelStatus {
                        // Full-protocol diagnostics may observe 2A1B directly.
                        // Standard 2A19 is subscribed exactly once below through
                        // requestStrapStatusRead, which owns the no-read policy.
                        if !ch.isNotifying {
                            peripheral.setNotifyValue(true, for: ch)
                        }
                    }
                }
                if ch.uuid == UUIDs.batteryLevel || ch.uuid == UUIDs.batteryLevelStatus {
                    if ch.uuid == UUIDs.batteryLevel {
                        foundBatteryLevelCharacteristic = ch
                    } else {
                        foundBatteryStatusCharacteristic = ch
                    }
                }
                if ch.uuid == UUIDs.heartRateMeasure {
                    foundHeartRateCharacteristic = ch
                }
            case UUIDs.manufacturerName, UUIDs.modelNumber,
                 UUIDs.firmwareRevision, UUIDs.hardwareRevision:
                peripheral.readValue(for: ch)
            case UUIDs.strapTX:
                if discoveryUsesProtectedStandardHR, !protectedR10StreamSuppressed {
                    foundTX = ch
                    usedStandardHROnly = true
                } else if discoveryUsesProtectedStandardHR {
                    usedStandardHROnly = true
                    radioCounters.append((RadioDefaults.txSkipped, "protected_r10_rollback"))
                } else {
                    foundTX = ch
                }
            default:
                if discoveryUsesProtectedStandardHR,
                   !protectedR10StreamSuppressed,
                   ch.uuid == Self.UUIDs.strapStream5,
                   ch.properties.contains(.notify) {
                    if !ch.isNotifying {
                        peripheral.setNotifyValue(true, for: ch)
                        requestedCustomNotifyCount += 1
                        radioCounters.append((RadioDefaults.customNotifyEnabled,
                                              "protected_r10_minimal"))
                    } else {
                        passiveR10AlreadyNotifying = true
                    }
                } else if discoveryUsesProtectedStandardHR, UUIDs.allNotify.contains(ch.uuid) {
                    // Do not mutate proprietary CCCDs while protecting 2A37.
                    // Enabling stream 5 and later disabling the restored
                    // subscription both caused repeated physical disconnects.
                    // A fresh restoration namespace plus an ingest guard below
                    // leaves these characteristics entirely untouched.
                    skippedCustomNotify = true
                    radioCounters.append((RadioDefaults.customNotifySkipped, "standard_hr_only"))
                } else if UUIDs.allNotify.contains(ch.uuid),
                   ch.properties.contains(.notify) {
                    if !ch.isNotifying {
                        peripheral.setNotifyValue(true, for: ch)
                        requestedCustomNotifyCount += 1
                        radioCounters.append((RadioDefaults.customNotifyEnabled, "full_protocol"))
                    }
                }
            }
        }
        if foundBatteryLevelCharacteristic != nil || foundBatteryStatusCharacteristic != nil {
            Task { @MainActor in
                if let foundBatteryLevelCharacteristic {
                    self.batteryLevelCharacteristic = foundBatteryLevelCharacteristic
                }
                if let foundBatteryStatusCharacteristic {
                    self.batteryStatusCharacteristic = foundBatteryStatusCharacteristic
                }
                if foundBatteryLevelCharacteristic != nil {
                    self.requestStrapStatusRead(reason: "battery_characteristic_discovered")
                }
            }
        }
        // Set the command characteristic and request realtime HR + RR intervals
        // (the HRV source) in ONE task, so tx is assigned before we send. Verified
        // command: [0x23, seq, 0x03, 0x01] → CMD_RESP ack → REALTIME_DATA stream.
        if foundTX != nil || foundHeartRateCharacteristic != nil || !radioCounters.isEmpty || requestedCustomNotifyCount > 0 || !alreadyActiveProprietaryNotifications.isEmpty || passiveR10AlreadyNotifying || skippedCustomNotify || usedStandardHROnly {
            Task { @MainActor in
                if let heartRateCharacteristic = foundHeartRateCharacteristic {
                    self.heartRateCharacteristic = heartRateCharacteristic
                    self.lastMissingHeartRateDiscoveryAt = nil
                    self.scheduleDebugMissingHeartRateCharacteristicAfterDiscoveryIfNeeded()
                }
                if usedStandardHROnly {
                    self.dbgLast = "standard hr only"
                } else if skippedCustomNotify {
                    self.dbgLast = "skipped custom notify"
                }
                if requestedCustomNotifyCount > 0 {
                    self.dbgSubsReq += requestedCustomNotifyCount
                }
                if !alreadyActiveProprietaryNotifications.isEmpty {
                    self.activeProprietaryNotifyUUIDs.formUnion(alreadyActiveProprietaryNotifications)
                    self.strapStream5NotifyConfirmed = alreadyActiveProprietaryNotifications.contains(Self.UUIDs.strapStream5)
                    AtriaDebugLog("ATRIADBG ble_restore_notifications status=seeded active=%d stream5=%d",
                                  self.activeProprietaryNotifyUUIDs.count,
                                  self.strapStream5NotifyConfirmed ? 1 : 0)
                }
                if passiveR10AlreadyNotifying {
                    self.activeProprietaryNotifyUUIDs.insert(Self.UUIDs.strapStream5)
                    self.strapStream5NotifyConfirmed = true
                    self.markPassiveR10SubscriptionConfirmed()
                }
                for counter in radioCounters {
                    self.incrementRadioCounter(counter.key, reason: counter.reason)
                }
                if let tx = foundTX {
                    self.txCharacteristic = tx
                    self.dbgTxReady = true
                    if discoveryUsesProtectedStandardHR {
                        self.sendProtectedR10ActivationIfReady()
                    } else if self.strapStream5NotifyConfirmed {
                        self.armRealtime()
                    } else if !self.armWhenProprietaryNotifyPairReadyIfNeeded(reason: "characteristics_discovered_notify_pair_ready") {
                        self.scheduleProprietaryArmFallbackIfNeeded(reason: "characteristics_discovered")
                    }
                }
            }
        } else if let tx = foundTX {
            Task { @MainActor in
                self.txCharacteristic = tx
                self.dbgTxReady = true
                if !self.armWhenProprietaryNotifyPairReadyIfNeeded(reason: "tx_only_discovered_notify_pair_ready") {
                    self.scheduleProprietaryArmFallbackIfNeeded(reason: "tx_only_discovered")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let msg = error.map { "ERR:\($0.localizedDescription.prefix(18))" } ?? "ok"
        AtriaDebugLog("ATRIADBG writeResult to=%@ -> %@", characteristic.uuid.uuidString, msg)
        Task { @MainActor in
            self.dbgWrite = msg
            if characteristic.uuid == self.txCharacteristic?.uuid {
                if error != nil,
                   self.proprietaryBatteryRefreshPhase == .awaitingResponse {
                    self.failProprietaryBatteryRefresh(reason: "write_failed")
                }
                self.handleHistoricalACKWriteResult(error: error)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let short = String(characteristic.uuid.uuidString.prefix(8))
        let notifying = characteristic.isNotifying
        let err = error?.localizedDescription
        let isData = characteristic.uuid == UUIDs.strapStream5
        AtriaDebugLog("ATRIADBG notifyState ch=%@ notifying=%d err=%@", characteristic.uuid.uuidString, notifying ? 1 : 0, error?.localizedDescription ?? "nil")
        Task { @MainActor in
            if characteristic.uuid == Self.UUIDs.batteryLevel {
                let defaults = UserDefaults.standard
                if let err {
                    self.batteryNotificationEpochHadRejectedCallback = true
                    defaults.set(err, forKey: BatteryDefaults.notificationLastError)
                    defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)
                    self.revokeBatteryNotificationLease(reason: "2A19_notify_error")
                } else if notifying {
                    // A successful subscribe/reactivation starts a clean battery
                    // notification epoch. Rejected callbacks from a prior failed
                    // epoch cannot strand this active change-driven lease.
                    self.batteryNotificationEpochHadRejectedCallback = false
                    defaults.set(Date().timeIntervalSince1970,
                                 forKey: BatteryDefaults.notificationConfirmedAt)
                    defaults.removeObject(forKey: BatteryDefaults.notificationLastError)
                    if let heartRateReceivedAt = self.lastRawHRNotificationAt {
                        self.promoteReconnectBatteryBaselineIfSafe(
                            now: Date(),
                            heartRateReceivedAt: heartRateReceivedAt,
                            reason: "2A19_notify_became_active"
                        )
                    }
                } else {
                    self.batteryNotificationEpochHadRejectedCallback = true
                    defaults.set("inactive", forKey: BatteryDefaults.notificationLastError)
                    defaults.removeObject(forKey: BatteryDefaults.notificationConfirmedAt)
                    self.revokeBatteryNotificationLease(reason: "2A19_notify_inactive")
                }
            }
            if self.motionHandshakeDiagnostic != nil {
                if let err {
                    self.recordMotionHandshakeEvidence(event: "notify_error",
                                                       detail: "\(short)_\(err)")
                } else if notifying, isData {
                    self.recordMotionHandshakeEvidence(event: "stream5_notify_active")
                    self.scheduleMotionHandshakeStandardHRAddition(peripheral: peripheral)
                } else if notifying, characteristic.uuid == Self.UUIDs.heartRateMeasure {
                    self.recordMotionHandshakeEvidence(event: "hr_notify_active")
                    self.sendMotionHandshakeSingleR10ActivationIfReady()
                } else {
                    self.recordMotionHandshakeEvidence(event: "notify_inactive", detail: short)
                }
                return
            }
            if characteristic.uuid == Self.UUIDs.strapRX,
               self.proprietaryBatteryRefreshPhase == .subscribingResponse {
                self.handleProprietaryBatteryResponseNotifyState(characteristic,
                                                                 error: error)
                return
            }
            if notifying, characteristic.uuid == Self.UUIDs.heartRateMeasure {
                self.sendProtectedR10ActivationIfReady()
            }
            if let err {
                self.pendingNotifyReenableUUIDs.remove(characteristic.uuid)
                self.dbgLast = "suberr \(short):\(err.prefix(14))"
                if isData {
                    self.strapStream5NotifyConfirmed = false
                    self.reassertR10NotificationIfConnected(reason: "stream5_notify_error")
                }
            } else if !notifying,
                      self.pendingNotifyReenableUUIDs.remove(characteristic.uuid) != nil {
                if Self.shouldEnableNotifications(isNotifying: characteristic.isNotifying) {
                    peripheral.setNotifyValue(true, for: characteristic)
                    AtriaDebugLog("ATRIADBG ble_notify_reassert status=reenable_after_off ch=%@",
                                  characteristic.uuid.uuidString)
                } else {
                    AtriaDebugLog("ATRIADBG ble_notify_reassert status=already_notifying ch=%@ action=skip_enable",
                                  characteristic.uuid.uuidString)
                }
            }
            if err != nil {
                return
            } else if notifying {
                self.dbgSubsActive += 1
                if Self.UUIDs.allNotify.contains(characteristic.uuid) {
                    self.activeProprietaryNotifyUUIDs.insert(characteristic.uuid)
                    if isData {
                        self.strapStream5NotifyConfirmed = true
                        if self.r10TransportIsExpected {
                            self.ensureR10LivenessWatchdog(reason: "stream5_notify_active")
                        }
                        if self.standardHROnlyMode,
                           !self.historyOnlyProbeEnabled,
                           Self.shouldObservePassiveR10InProtectedStandardHR(
                            characteristicUUID: characteristic.uuid
                           ) {
                            self.markPassiveR10SubscriptionConfirmed()
                        } else {
                            self.armRealtime()     // full protocol data char ready
                        }
                        self.sendProtectedR10ActivationIfReady()
                    } else if self.armWhenProprietaryNotifyPairReadyIfNeeded(reason: "notify_pair_ready") {
                    } else {
                        self.scheduleProprietaryArmFallbackIfNeeded(reason: "notify_state_\(short)")
                    }
                }
            } else if Self.UUIDs.allNotify.contains(characteristic.uuid) {
                self.activeProprietaryNotifyUUIDs.remove(characteristic.uuid)
                if isData {
                    self.strapStream5NotifyConfirmed = false
                    self.reassertR10NotificationIfConnected(reason: "stream5_notify_inactive")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            if characteristic.uuid == Self.UUIDs.batteryLevel {
                let defaults = UserDefaults.standard
                defaults.set(Date().timeIntervalSince1970,
                             forKey: BatteryDefaults.notificationLastCallbackAt)
                defaults.set(error.localizedDescription,
                             forKey: BatteryDefaults.notificationLastError)
                Task { @MainActor in
                    self.batteryNotificationEpochHadRejectedCallback = true
                }
            }
            AtriaDebugLog("ATRIADBG value_update ch=%@ status=rejected error=%@",
                          characteristic.uuid.uuidString,
                          error.localizedDescription)
            return
        }
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        let receivedAt = Date()
        let isProprietaryNotification = UUIDs.allNotify.contains(uuid)
        let isPendingOneShotBatteryResponse = uuid == Self.UUIDs.strapRX
            && UserDefaults.standard.bool(forKey: BatteryDefaults.proprietaryRefreshPending)
        if isProprietaryNotification,
           standardHROnlyMode,
           !Self.shouldAcceptProtectedProprietaryNotification(
            characteristicUUID: uuid,
            streamSuppressed: protectedR10StreamSuppressed,
            pendingOneShotBatteryResponse: isPendingOneShotBatteryResponse
           ) {
            // A restored legacy subscription may briefly deliver after an app
            // update. Ignore it completely; never decode it into steps or let
            // it influence the protected standard-HR connection.
            return
        }
        if !isProprietaryNotification {
            Task { @MainActor in
                self.recordRealGattData(at: receivedAt, source: uuid.uuidString)
                if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                    self.recomputeConnectionStatus(reason: "event")
                }
            }
        }
        if uuid == UUIDs.heartRateMeasure {
            let parsed = Self.parseHeartRatePacket(data)
            Task { @MainActor in
                self.recordHeartRateReadPollResultIfNeeded(parsed: parsed)
                if let parsed {
                    self.noteDutyCycleHeartRate(parsed.hr)
                }
            }
            enqueueHeartRateUpdate(PendingHeartRateUpdate(packet: parsed, rawData: data))
            return
        }
        if uuid == UUIDs.batteryLevel {
            UserDefaults.standard.set(receivedAt.timeIntervalSince1970,
                                      forKey: BatteryDefaults.notificationLastCallbackAt)
            guard let newLevel = Self.parseBatteryLevel(data) else {
                Task { @MainActor in
                    self.batteryNotificationEpochHadRejectedCallback = true
                }
                AtriaDebugLog("ATRIADBG battery source=2A19 status=rejected reason=malformed bytes=%@",
                              Self.hex([UInt8](data)))
                return
            }
            Task { @MainActor in
                // A GATT value from a CB-connected peripheral proves the link is
                // live. Record the activity and heal a status that a watchdog or a
                // transient central blip wrongly left non-connected (after state
                // restoration no didConnect fires, so HR is the only other healer
                // and it can't fire during a low-radio HR silence).
                if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                    self.recomputeConnectionStatus(reason: "event")
                }
                switch Self.batteryLevelAcceptanceDecision(
                    previousLevel: self.batteryLevel,
                    previousAcceptedAt: self.lastAcceptedBatteryLevelAt,
                    incomingLevel: newLevel,
                    receivedAt: receivedAt,
                    pending: self.pendingBatteryDropCandidate,
                    previousIsCached: self.displayedBatteryLevelIsCached,
                    requiresFreshConfirmation: UserDefaults.standard.bool(
                        forKey: BatteryDefaults.requiresFreshConfirmation
                    ),
                    trustedCurrentConnectionNotification: characteristic.isNotifying
                        && peripheral.state == .connected
                ) {
                case .quarantine(let candidate):
                    self.pendingBatteryDropCandidate = candidate
                    AtriaDebugLog("ATRIADBG battery level=%d source=2A19 status=quarantined previous=%d confirmations=%d span_s=%.1f reason=implausible_instant_drop bytes=%@",
                                  newLevel,
                                  self.batteryLevel,
                                  candidate.confirmations,
                                  candidate.lastSeenAt.timeIntervalSince(candidate.firstSeenAt),
                                  Self.hex([UInt8](data)))
                    self.scheduleBatteryConfirmationRead(incomingLevel: newLevel)
                    return
                case .accept:
                    self.batteryConfirmationReadTask?.cancel()
                    self.batteryConfirmationReadTask = nil
                    self.batteryConfirmationReadLevel = nil
                    self.pendingBatteryDropCandidate = nil
                    self.displayedBatteryLevelIsCached = false
                    self.batteryReadingIsRecentBaseline = false
                    self.batteryProjectionRevision &+= 1
                    UserDefaults.standard.removeObject(
                        forKey: BatteryDefaults.requiresFreshConfirmation
                    )
                    UserDefaults.standard.set(receivedAt.timeIntervalSince1970,
                                              forKey: BatteryDefaults.notificationLeaseAt)
                }
                self.lastAcceptedBatteryLevelAt = receivedAt
                // 2A19 exposes percentage, not external-power state. A single
                // small rise can be quantization/correction and must never claim
                // Charging. A decline is still strong not-charging evidence; 100%
                // may be surfaced as Full after its separate truth gate accepts it.
                let previous = batteryLevel
                let chargeEvidenceFromThisRead = Self.chargeEvidenceFromBatteryLevelChange(
                    previousLevel: previous,
                    newLevel: newLevel
                )
                if previous >= 0 {
                    let delta = newLevel - previous
                    if chargeEvidenceFromThisRead == .full {
                        assignIfChanged(\.batteryIsCharging, false)
                        assignIfChanged(\.batteryChargeStatus, .full)
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    } else if delta > 0 {
                        if batteryChargeStatus != .charging {
                            assignIfChanged(\.batteryIsCharging, false)
                            assignIfChanged(\.batteryChargeStatus, .levelOnly)
                        }
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    } else if delta < 0 {
                        assignIfChanged(\.batteryIsCharging, false)
                        assignIfChanged(\.batteryChargeStatus, .notCharging)
                        assignIfChanged(\.batteryRecentlyDropping, true)
                    } else if batteryChargeStatus == .charging {
                        assignIfChanged(\.batteryIsCharging, false)
                        assignIfChanged(\.batteryChargeStatus, .levelOnly)
                    }
                } else if chargeEvidenceFromThisRead == .full {
                    assignIfChanged(\.batteryChargeStatus, .full)
                    assignIfChanged(\.batteryRecentlyDropping, false)
                    clearBatteryDropMarker()
                }
                assignIfChanged(\.batteryLevel, newLevel)
                if self.r10MotionIsEligible, self.realtimeArmed {
                    self.ensureR10LivenessWatchdog(reason: "battery_eligible")
                    self.evaluateR10Liveness(now: receivedAt, reason: "battery_eligible")
                }
                persistBatteryLevel(batteryLevel, source: "live_2A19", chargeStatus: chargeEvidenceFromThisRead)
                if let chargeEvidenceFromThisRead {
                    recordBatteryChargeEvidence(chargeEvidenceFromThisRead, reason: "battery_level")
                } else if batteryChargeStatus != .charging {
                    recordBatteryChargeEvidence(batteryChargeStatus, reason: "battery_level")
                }
                AtriaDebugLog("ATRIADBG battery level=%d source=2A19 bytes=%@ persisted=1",
                      batteryLevel,
                      Self.hex([UInt8](data)))
            }
            return
        }
        if uuid == UUIDs.batteryLevelStatus {
            Task { @MainActor in
                if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                    self.recomputeConnectionStatus(reason: "event")
                }
                if let parsedStatus = Self.parseBatteryChargeStatus(data) {
                    let proposedStatus: BatteryChargeStatus = batteryLevel >= 100 && parsedStatus == .charging ? .full : parsedStatus
                    let hasPlausibleRiseEvidence = self.pendingBatteryDropCandidate == nil &&
                        (self.batteryChargeStatus == .charging || self.batteryChargeStatus == .full)
                    guard let status = Self.acceptedBatteryChargeStatus(
                        proposedStatus,
                        batteryLevel: self.batteryLevel,
                        hasPlausibleRiseEvidence: hasPlausibleRiseEvidence
                    ) else {
                        // A powered/full status packet cannot overrule a
                        // disputed level. Keep every projection fail-closed and
                        // leave the last credible percentage untouched.
                        self.assignIfChanged(\.batteryIsCharging, false)
                        self.assignIfChanged(\.batteryChargeStatus, .levelOnly)
                        self.recordBatteryChargeEvidence(.levelOnly,
                                                         reason: "battery_status_quarantined")
                        AtriaDebugLog("ATRIADBG battery_charge source=2A1B status=quarantined proposed=%@ level=%d level_disputed=%d bytes=%@",
                                      proposedStatus.rawValue,
                                      self.batteryLevel,
                                      self.pendingBatteryDropCandidate == nil ? 0 : 1,
                                      Self.hex([UInt8](data)))
                        return
                    }
                    assignIfChanged(\.batteryIsCharging, status == .charging)
                    assignIfChanged(\.batteryChargeStatus, status)
                    if self.r10MotionIsEligible, self.realtimeArmed {
                        self.ensureR10LivenessWatchdog(reason: "charging_eligible")
                        self.evaluateR10Liveness(now: receivedAt, reason: "charging_eligible")
                    }
                    if status == .charging || status == .full {
                        self.pendingBatteryDropCandidate = nil
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    }
                    persistBatteryChargeStatus(status, source: "live_2A1B")
                    recordBatteryChargeEvidence(status, reason: "battery_status")
                }
                AtriaDebugLog("ATRIADBG battery_charge source=2A1B status=%@ bytes=%@",
                      self.batteryChargeStatus.rawValue,
                      Self.hex([UInt8](data)))
            }
            return
        }
        if uuid == UUIDs.manufacturerName {
            Task { @MainActor in
                assignIfChanged(\.manufacturer, String(data: data, encoding: .utf8) ?? "—")
            }
            return
        }
        if uuid == UUIDs.modelNumber || uuid == UUIDs.firmwareRevision || uuid == UUIDs.hardwareRevision {
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Task { @MainActor in
                switch uuid {
                case UUIDs.modelNumber: assignIfChanged(\.modelNumber, text)
                case UUIDs.firmwareRevision: assignIfChanged(\.firmwareRevision, text)
                case UUIDs.hardwareRevision: assignIfChanged(\.hardwareRevision, text)
                default: break
                }
                AtriaDebugLog("ATRIADBG deviceinfo model=%@ hw=%@ fw=%@",
                              modelNumber, hardwareRevision, firmwareRevision)
            }
            return
        }

        let frameSource = Self.label(for: uuid)
        if uuid == UUIDs.strapStream7 {
            Task { @MainActor in
                recordResearchProbeCandidate(payload: [UInt8](data), source: .diagnostic)
            }
        }

        let completeFrames = proprietaryFrameReassembler.feed(data, source: frameSource)
        guard !completeFrames.isEmpty else { return }
        Task { @MainActor in
            self.recordRealGattData(at: receivedAt, source: uuid.uuidString)
            if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                self.recomputeConnectionStatus(reason: "event")
            }
        }

        let storesProprietaryFrames = storeProprietaryFramesMode
        let captureUntil = strapStepCalibrationCaptureUntil
        var pendingMainActorWork: [PendingProprietaryMainActorWork] = []
        pendingMainActorWork.reserveCapacity(completeFrames.count)
        for completeFrame in completeFrames {
            if let captureUntil, receivedAt <= captureUntil {
                AtriaStrapCalibrationArchive.shared.recordMotionFrame(
                    completeFrame,
                    source: frameSource,
                    receivedAt: receivedAt
                )
            }
            if let r10Frame = AtriaR10MotionDecoder.decode(frame: completeFrame) {
                r10MotionPipeline.ingest(r10Frame, receivedAt: receivedAt) { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.applyR10MotionSnapshot(snapshot)
                    }
                }
                if !storesProprietaryFrames {
                    let payloadLength = max(0, completeFrame.count - 8)
                    pendingMainActorWork.append(.r10Metadata(payloadLength: payloadLength))
                    continue
                }
            }

            let parsedRealtimePacket = storesProprietaryFrames
                ? nil
                : Self.parseFastRealtimeProprietaryPacket(completeFrame)
            if let parsedRealtimePacket {
                enqueueRealtimePacket(parsedRealtimePacket)
                continue
            }
            let parsedProprietaryUpdate = storesProprietaryFrames
                ? nil
                : Self.parseProprietaryUpdate(completeFrame, source: frameSource)
            let parsedStoredFrame = storesProprietaryFrames
                ? AtriaFrame.parse(completeFrame, source: frameSource)
                : nil
            pendingMainActorWork.append(.frame(completeFrame,
                                               parsedUpdate: parsedProprietaryUpdate,
                                               storedFrame: parsedStoredFrame))
        }

        guard !pendingMainActorWork.isEmpty else { return }
        Task { @MainActor in
            for work in pendingMainActorWork {
                if case let .r10Metadata(payloadLength) = work {
                    recordDecodedR10Metadata(sourceUUID: uuid,
                                             payloadLength: payloadLength,
                                             receivedAt: receivedAt)
                    continue
                }
                guard case let .frame(completeFrame, parsedProprietaryUpdate, parsedStoredFrame) = work else {
                    continue
                }
                dbgPropFrames += 1
                if shouldLogVerboseBLEFrame() {
                    AtriaDebugLog("ATRIADBG frame ch=%@ len=%d hex=%@",
                                  uuid.uuidString.prefix(8).description,
                                  completeFrame.count,
                                  Self.hex([UInt8](completeFrame)))
                }
                let typeByte = Self.protocolTypeByte(in: completeFrame)
                let sig = "\(uuid.uuidString.prefix(8).suffix(2)):\(String(format: "%02x", typeByte))"
                if !dbgTypeSet.contains(sig) {
                    dbgTypeSet.insert(sig)
                    dbgLast = dbgTypeSet.sorted().joined(separator: " ")
                }
                if Self.isRealtimeProtocolFrame(completeFrame, typeByte: typeByte) {
                    dbgRealtimeFrames += 1
                }
                if let parsedProprietaryUpdate {
                    if case .realtime = parsedProprietaryUpdate {
                        dbgRealtimeFrames -= 1
                    }
                    handleParsedProprietaryUpdate(parsedProprietaryUpdate, uuid: uuid)
                } else {
                    if storeProprietaryFrames, let parsedStoredFrame {
                        record(frame: parsedStoredFrame)
                    }
                    handleProprietary(completeFrame, sourceUUID: uuid)
                }
            }
        }
    }

    private func persistBatteryLevel(_ level: Int, source: String, chargeStatus: BatteryChargeStatus? = nil) {
        guard level >= 0 && level <= 100 else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if let chargeStatus {
            recordChargePatternHourIfTransitioning(to: chargeStatus, defaults: defaults)
        }
        let previous = defaults.object(forKey: BatteryDefaults.level) as? Int
        if let previous, previous > level {
            defaults.set(previous, forKey: BatteryDefaults.previousLevel)
            defaults.set(defaults.object(forKey: BatteryDefaults.at) as? Double ?? now, forKey: BatteryDefaults.previousAt)
            defaults.set(previous - level, forKey: BatteryDefaults.dropDelta)
            defaults.set(now, forKey: BatteryDefaults.dropAt)
        }
        defaults.set(level, forKey: BatteryDefaults.level)
        defaults.set(now, forKey: BatteryDefaults.at)
        defaults.set(source, forKey: BatteryDefaults.source)
        if !Self.isBatterySentinel(level) {
            defaults.set(level, forKey: BatteryDefaults.credibleLevel)
            defaults.set(now, forKey: BatteryDefaults.credibleAt)
        }
        if let chargeStatus {
            defaults.set(chargeStatus.rawValue, forKey: BatteryDefaults.chargeStatus)
            defaults.set(now, forKey: BatteryDefaults.chargeAt)
        }
        updateStrapStreamState(reason: "battery_level", defaults: defaults)
        let effectiveChargeStatus = chargeStatus ?? batteryChargeStatus
        LocalNotificationScheduler.scheduleStrapChargeReminder(
            batteryLevel: level,
            isCharging: effectiveChargeStatus == .charging || effectiveChargeStatus == .full)
    }

    /// Records the local hour-of-day the first time a battery update observes a
    /// transition INTO `.charging` (i.e. the previously persisted charge status
    /// was something other than charging). Keeps at most the last 14 entries and
    /// dedupes to at most one record per rolling 4 h window so a single long
    /// charge session on the dock doesn't flood the sample with one hour value.
    private func recordChargePatternHourIfTransitioning(to status: BatteryChargeStatus,
                                                        defaults: UserDefaults,
                                                        now: Date = Date(),
                                                        calendar: Calendar = .current) {
        guard status == .charging else { return }
        let previousStatus = defaults.string(forKey: BatteryDefaults.chargeStatus)
        guard previousStatus != BatteryChargeStatus.charging.rawValue else { return }

        let lastRecordedAt = defaults.double(forKey: ChargePatternDefaults.lastRecordedAt)
        if lastRecordedAt > 0,
           now.timeIntervalSince1970 - lastRecordedAt < Self.chargePatternDedupeWindow {
            AtriaDebugLog("ATRIADBG charge_pattern status=skipped reason=dedupe_window_active last_s_ago=%.0f",
                          now.timeIntervalSince1970 - lastRecordedAt)
            return
        }

        let hour = calendar.component(.hour, from: now)
        var hours = defaults.array(forKey: ChargePatternDefaults.hours) as? [Int] ?? []
        hours.append(hour)
        if hours.count > Self.chargePatternMaxEntries {
            hours.removeFirst(hours.count - Self.chargePatternMaxEntries)
        }
        defaults.set(hours, forKey: ChargePatternDefaults.hours)
        defaults.set(now.timeIntervalSince1970, forKey: ChargePatternDefaults.lastRecordedAt)
        AtriaDebugLog("ATRIADBG charge_pattern status=recorded hour=%d sample_count=%d",
                      hour,
                      hours.count)
    }

    private func persistBatteryChargeStatus(_ status: BatteryChargeStatus, source: String) {
        let defaults = UserDefaults.standard
        recordChargePatternHourIfTransitioning(to: status, defaults: defaults)
        Self.persistBatteryChargeStatusProjection(status,
                                                  source: source,
                                                  defaults: defaults)
        if status == .charging || status == .full {
            clearBatteryDropMarker()
        }
        // A 2A1B packet contains charge state only. Re-persisting the in-memory
        // percentage here used to refresh its timestamp and make a stale or
        // disputed 0/100 look like fresh level evidence across widgets and
        // notifications. Only an accepted level-bearing packet may do that.
        updateStrapStreamState(reason: "battery_charge_status", defaults: defaults)
    }

    nonisolated static func persistBatteryChargeStatusProjection(
        _ status: BatteryChargeStatus,
        source: String,
        defaults: UserDefaults,
        now: Date = Date()
    ) {
        defaults.set(status.rawValue, forKey: BatteryDefaults.chargeStatus)
        defaults.set(now.timeIntervalSince1970, forKey: BatteryDefaults.chargeAt)
        defaults.set(source, forKey: "atria.battery.chargeSource")
    }

    private func clearBatteryDropMarker() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: BatteryDefaults.dropDelta)
        defaults.removeObject(forKey: BatteryDefaults.dropAt)
    }

    // Heart Rate Measurement per BLE spec: flags byte, uint8/uint16 BPM,
    // optional Energy Expended, then R-R intervals in 1/1024 seconds.
    nonisolated static func parseHeartRateMeasurement(_ data: Data) -> (hr: Int, rr: [Int], truncated: Bool)? {
        guard !data.isEmpty else { return nil }
        let flags = data[data.startIndex]
        var index = 1
        let hr: Int
        if flags & 0x01 != 0 {
            guard index + 1 < data.count else { return nil }
            hr = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2
        } else {
            guard index < data.count else { return nil }
            hr = Int(data[index])
            index += 1
        }
        if flags & 0x08 != 0 {
            guard index + 1 < data.count else { return nil }
            index += 2
        }
        var rr: [Int] = []
        var truncated = false
        if flags & 0x10 != 0 {
            let remainingBytes = max(data.count - index, 0)
            rr.reserveCapacity(remainingBytes / 2)
            while index + 1 < data.count {
                let raw = Int(data[index]) | (Int(data[index + 1]) << 8)
                rr.append((raw * 1_000 + 512) / 1_024)
                index += 2
            }
            truncated = index < data.count
        }
        return (hr, rr, truncated)
    }

    private nonisolated static func parseHeartRatePacket(_ data: Data) -> ParsedHeartRatePacket? {
        guard let measurement = parseHeartRateMeasurement(data) else { return nil }
        return ParsedHeartRatePacket(hr: measurement.hr,
                                     rrValues: measurement.rr,
                                     truncated: measurement.truncated,
                                     frameTime: Date())
    }

    private static func beatTimesEnding(at frameTime: Date, intervalsMS: [Int]) -> [(rr: Int, time: Date)] {
        guard !intervalsMS.isEmpty else { return [] }

        var remainingAfter = 0
        for rr in intervalsMS {
            remainingAfter += rr
        }

        var beats: [(rr: Int, time: Date)] = []
        beats.reserveCapacity(intervalsMS.count)
        for rr in intervalsMS {
            remainingAfter -= rr
            beats.append((rr: rr, time: frameTime.addingTimeInterval(-Double(remainingAfter) / 1000.0)))
        }
        return beats
    }

    private func shouldSkipRealtimeZeroRRTracking(now: Date,
                                                  rrCount: Int,
                                                  source: String,
                                                  lastTrackedAt: inout Date?) -> Bool {
        guard rrCount == 0, source == "0x28" else {
            lastTrackedAt = now
            return false
        }
        if let lastTrackedAt,
           now.timeIntervalSince(lastTrackedAt) < Self.zeroRRTrackingMinimumInterval {
            return true
        }
        lastTrackedAt = now
        return false
    }

    private nonisolated static func protocolTypeByte(in data: Data) -> UInt8 {
        guard let first = data.first else { return 0 }
        guard first == 0xAA, data.count > 4 else { return first }
        return data[data.index(data.startIndex, offsetBy: 4)]
    }

    private nonisolated static func isRealtimeProtocolFrame(_ data: Data, typeByte: UInt8) -> Bool {
        data.first == 0xAA && data.count > 4 && typeByte == Packet.realtime
    }

    private nonisolated static func parseProprietaryUpdate(_ data: Data,
                                                           source: String) -> ParsedProprietaryUpdate? {
        guard data.count >= 8, data.first == 0xAA else { return nil }
        let lenLowIndex = data.index(after: data.startIndex)
        let lenHighIndex = data.index(lenLowIndex, offsetBy: 1)
        let headerCRCIndex = data.index(lenHighIndex, offsetBy: 1)
        let len = Int(data[lenLowIndex]) | (Int(data[lenHighIndex]) << 8)
        guard data[headerCRCIndex] == crc8([data[lenLowIndex], data[lenHighIndex]]),
              len + 4 <= data.count,
              len >= 5 else { return nil }

        let payloadStart = data.index(headerCRCIndex, offsetBy: 1)
        let payloadEnd = data.index(data.startIndex, offsetBy: len)
        guard payloadStart < payloadEnd else { return nil }
        let payload = data[payloadStart..<payloadEnd]
        let expectedCRC = crc32(payload)
        let actualCRC = UInt32(data[payloadEnd])
            | (UInt32(data[data.index(payloadEnd, offsetBy: 1)]) << 8)
            | (UInt32(data[data.index(payloadEnd, offsetBy: 2)]) << 16)
            | (UInt32(data[data.index(payloadEnd, offsetBy: 3)]) << 24)
        guard expectedCRC == actualCRC else { return nil }

        switch payload.first {
        case Packet.realtime:
            guard payload.count >= 10 else { return nil }
            let heartRateIndex = payload.index(payload.startIndex, offsetBy: 8)
            let rrCountIndex = payload.index(payload.startIndex, offsetBy: 9)
            let rrnum = Int(payload[rrCountIndex])
            var decodedRR: [Int] = []
            decodedRR.reserveCapacity(rrnum)
            var truncated = false
            if rrnum > 0 {
                var rrIndex = payload.index(rrCountIndex, offsetBy: 1)
                for _ in 0..<rrnum {
                    let next = payload.index(rrIndex, offsetBy: 2, limitedBy: payload.endIndex)
                    guard let next, next <= payload.endIndex else {
                        truncated = true
                        break
                    }
                    let lo = Int(payload[rrIndex])
                    let hi = Int(payload[payload.index(after: rrIndex)])
                    decodedRR.append(lo | (hi << 8))
                    rrIndex = next
                }
            }

            let realtimeUnix: UInt32
            if payload.count >= 6 {
                realtimeUnix = UInt32(payload[payload.index(payload.startIndex, offsetBy: 2)])
                    | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 3)]) << 8)
                    | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 4)]) << 16)
                    | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 5)]) << 24)
            } else {
                realtimeUnix = 0
            }

            return .realtime(ParsedRealtimePacket(realtimeUnix: realtimeUnix,
                                                  hr: Int(payload[heartRateIndex]),
                                                  rrValues: decodedRR,
                                                  truncated: truncated,
                                                  frameTime: Date()))
        case 0x24:
            guard let frame = AtriaFrame.parse(data, source: source) else { return nil }
            return .commandResponse(frame)
        case Packet.metadata:
            return .historyMetadata([UInt8](payload))
        case Packet.historical:
            return .historical([UInt8](payload))
        case .some:
            return .unknown(payload: [UInt8](payload), fullFrame: [UInt8](data))
        case .none:
            return nil
        }
    }

    private nonisolated static func parseFastRealtimeProprietaryPacket(_ data: Data) -> ParsedRealtimePacket? {
        guard data.count >= 14, data.first == 0xAA else { return nil }
        let lenLowIndex = data.index(after: data.startIndex)
        let lenHighIndex = data.index(lenLowIndex, offsetBy: 1)
        let headerCRCIndex = data.index(lenHighIndex, offsetBy: 1)
        let len = Int(data[lenLowIndex]) | (Int(data[lenHighIndex]) << 8)
        guard len >= 10, len + 4 <= data.count else { return nil }
        guard data[headerCRCIndex] == crc8([data[lenLowIndex], data[lenHighIndex]]) else { return nil }

        let payloadStart = data.index(headerCRCIndex, offsetBy: 1)
        let payloadEnd = data.index(data.startIndex, offsetBy: len)
        guard payloadStart < payloadEnd else { return nil }
        let payload = data[payloadStart..<payloadEnd]
        guard payload.count >= 10, payload.first == Packet.realtime else { return nil }

        let checksumStart = payloadEnd
        let checksumEnd = data.index(checksumStart, offsetBy: 4)
        guard checksumEnd <= data.endIndex else { return nil }
        let expectedCRC = crc32(payload)
        let actualCRC = UInt32(data[checksumStart])
            | (UInt32(data[data.index(checksumStart, offsetBy: 1)]) << 8)
            | (UInt32(data[data.index(checksumStart, offsetBy: 2)]) << 16)
            | (UInt32(data[data.index(checksumStart, offsetBy: 3)]) << 24)
        guard expectedCRC == actualCRC else { return nil }

        let realtimeUnix = UInt32(payload[payload.index(payload.startIndex, offsetBy: 2)])
            | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 3)]) << 8)
            | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 4)]) << 16)
            | (UInt32(payload[payload.index(payload.startIndex, offsetBy: 5)]) << 24)
        let heartRateIndex = payload.index(payload.startIndex, offsetBy: 8)
        let rrCountIndex = payload.index(payload.startIndex, offsetBy: 9)
        let rrCount = Int(payload[rrCountIndex])
        var decodedRR: [Int] = []
        decodedRR.reserveCapacity(rrCount)
        var truncated = false
        if rrCount > 0 {
            var rrIndex = payload.index(rrCountIndex, offsetBy: 1)
            for _ in 0..<rrCount {
                let next = payload.index(rrIndex, offsetBy: 2, limitedBy: payload.endIndex)
                guard let next, next <= payload.endIndex else {
                    truncated = true
                    break
                }
                let lo = Int(payload[rrIndex])
                let hi = Int(payload[payload.index(after: rrIndex)])
                decodedRR.append(lo | (hi << 8))
                rrIndex = next
            }
        }

        return ParsedRealtimePacket(realtimeUnix: realtimeUnix,
                                    hr: Int(payload[heartRateIndex]),
                                    rrValues: decodedRR,
                                    truncated: truncated,
                                    frameTime: Date())
    }

    private nonisolated static func parseRealtimeProprietaryPacket(_ data: Data) -> ParsedRealtimePacket? {
        parseFastRealtimeProprietaryPacket(data)
            ?? {
                guard let update = parseProprietaryUpdate(data, source: ""),
                      case .realtime(let packet) = update else { return nil }
                return packet
            }()
    }

    // Heart Rate Measurement per BLE spec: flags byte, then uint8 or uint16 BPM.
    static func parseHeartRate(_ data: Data) -> Int {
        parseHeartRateMeasurement(data)?.hr ?? 0
    }

    nonisolated static func label(for uuid: CBUUID) -> String {
        switch uuid {
        case UUIDs.strapRX:      return "RX/resp"
        case UUIDs.strapStream4: return "stream4"
        case UUIDs.strapStream5: return "stream5"
        case UUIDs.strapStream7: return "stream7"
        default:                 return uuid.uuidString.prefix(8).lowercased()
        }
    }
}
