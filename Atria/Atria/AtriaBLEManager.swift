import Foundation
import CoreBluetooth
import CoreMotion
import UIKit

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

    private struct LongWearSupervisorConfig {
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
        let reason: String?
        let persistedPath: String
        let errorDescription: String?
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

        var supportsECG: Bool { self == .strapMG }
        var supportsBloodPressure: Bool { self == .strapMG }
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
    @Published private(set) var phoneStepsToday: Int = 0
    @Published private(set) var phoneDistanceTodayMeters: Double?
    @Published private(set) var phoneFloorsToday: Int?
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

    var supportsSpO2Probe: Bool { strapModel.supportsSpO2 }
    var supportsSkinTempProbe: Bool { strapModel.supportsSkinTemp }
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
    private var sessionOriginTime: Date?
    private var sessionPointsCache: [SavedSession.Point] = []
    private var rrPointsCache: [SavedSession.RRPoint] = []
    @Published var hasContact = false                  // sensor reporting a live pulse?
    private var recentValid: [Int] = []                // window for smoothing + artifact rejection
    private var pendingHRJump: (rate: Int, at: Date)?
    private var lastAcceptedHRAt: Date?
    private static let workoutHRArtifactJumpBPM = 50
    private static let workoutHRArtifactConfirmBPM = 15
    private static let workoutHRArtifactConfirmSeconds: TimeInterval = 10
    private static let workoutHRArtifactStaleMedianSeconds: TimeInterval = 5

    // Realtime command channel → HRV (RR intervals from REALTIME_DATA packets).
    private(set) var realtimeOn = false
    private(set) var hrv: Int = 0                      // RMSSD in ms
    private(set) var rrSamples = 0
    @Published var hrvSnapshot: HRVSnapshot?
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
    private var lastScanRequestMode = "filtered"
    private static let scanRequestDedupWindow: TimeInterval = 1.5
    private(set) var sleepMotionHintCount = 0
    private(set) var sleepMotionHintKinds = "none"
    private(set) var sleepMotionSource = "unavailable"
    private var sleepMotionHintKindCounts: [String: Int] = [:]
    private var sleepMotionShortValues: [Double] = []
    private let motionShortAuditThreshold = 1.0
    private let phoneMotionManager = CMMotionManager()
    private let phoneMotionStillThresholdG = 0.030
    private var phoneMotionLastVector: (x: Double, y: Double, z: Double)?
    private var phoneMotionDeltaSum = 0.0
    private var phoneMotionDeltaMax = 0.0
    private var phoneMotionSamples = 0
    private var phoneMotionOverStillThreshold = 0
    private var phoneMotionStartedAt: Date?
    private var phoneMotionLastLoggedSample = 0
    private let phonePedometer = CMPedometer()
    private var phoneStepEvidenceActive = false
    private var phoneStepStartedAt: Date?
    private var phoneStepCount = 0
    private var phoneStepDistanceMeters: Double?
    private var phoneStepFloorsAscended: Int?
    private var phoneStepFloorsDescended: Int?
    private var phoneStepLastLoggedCount = 0

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
    private var recentRRBeatTimes: [Date] = []
    private static let recentRRBeatWindowSeconds: TimeInterval = 10 * 60
    private var lastRecentRRBeatPruneAt: Date?
    private static let recentRRBeatPruneMinimumInterval: TimeInterval = 2
    private var lastRealtimeZeroRRQualityUpdateAt: Date?
    private var lastRealtimeZeroRRAutoCaptureUpdateAt: Date?
    private static let zeroRRTrackingMinimumInterval: TimeInterval = 0.5
    private var hrvLiveRefreshTask: Task<Void, Never>?
    private var pendingLiveHRVRefreshRequest: (now: Date, logKind: String, shouldLogConsole: Bool)?
    private var hrvLiveRefreshGeneration: UInt64 = 0
    private var contactStableSince: Date?
    private var hrvGateWasOpen = false
    private static let backgroundLiveHRVRefreshMinimumInterval: TimeInterval = 15
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
    private nonisolated let realtimePacketQueueLock = NSLock()
    private nonisolated(unsafe) var pendingRealtimePackets: [ParsedRealtimePacket] = []
    private nonisolated(unsafe) var pendingRealtimePacketHead = 0
    private nonisolated(unsafe) var realtimePacketDrainScheduled = false
    nonisolated private static let realtimePacketBatchSize = 12
    private var liveSessionID = UUID()
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
    }
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
        static let chargeStatus = "atria.battery.chargeStatus"
        static let chargeAt = "atria.battery.chargeAt"
        static let previousLevel = "atria.battery.previousLevel"
        static let previousAt = "atria.battery.previousAt"
        static let dropAt = "atria.battery.dropAt"
        static let dropDelta = "atria.battery.dropDelta"
    }
    private struct WorkoutCaptureEvidence {
        let diagnosis: String
        let action: String
        let sampleFields: String
    }
    enum RadioDefaults {
        static let standardHROnly = "atria.radio.standardHROnly"
        static let mode = "atria.radio.mode"
        static let customNotifySkipped = "atria.radio.customNotifySkipped"
        static let customNotifyEnabled = "atria.radio.customNotifyEnabled"
        static let txSkipped = "atria.radio.txSkipped"
        static let realtimeStartSkipped = "atria.radio.realtimeStartSkipped"
        static let lastReason = "atria.radio.lastReason"
    }
    enum CaptureDefaults {
        static let configured = "atria.capture.defaultsConfigured"
        static let protectedLongWearMigrated = "atria.capture.protectedLongWearMigrated"
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
    }
    enum KeepaliveDefaults {
        static let armed = "atria.keepalive.armed"
        static let lastStatus = "atria.keepalive.lastStatus"
        static let lastReason = "atria.keepalive.lastReason"
        static let lastAction = "atria.keepalive.lastAction"
        static let lastSilence = "atria.keepalive.lastSilence"
        static let ticks = "atria.keepalive.ticks"
    }
    enum CollectionProfileDefaults {
        static let profile = "atria.collection.profile"
    }

    enum Packet {
        static let command: UInt8 = 0x23
        static let realtime: UInt8 = 0x28
        static let historical: UInt8 = 0x2f
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
        static let toggleRealtimeHR: UInt8 = 0x03
        static let setClock: UInt8 = 0x0A
        static let getClock: UInt8 = 0x0B
        static let abortHistoricalTransmits: UInt8 = 0x14
        static let sendHistoricalData: UInt8 = 0x16
        static let historicalDataResult: UInt8 = 0x17
        static let getDataRange: UInt8 = 0x22
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

    var restingHR: Int? { sessionMinHeartRate }   // lowest sustained = resting proxy
    var peakHR: Int? { sessionMaxHeartRate }
    var avgHR: Int? {
        guard sessionSampleCount > 0 else { return nil }
        return sessionHeartRateTotal / sessionSampleCount
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
    private var pendingOfflineHistoricalSyncReason: String?
    private let offlineHistoricalSyncMinimumInterval: TimeInterval = 6 * 60 * 60
    private let offlineSyncLiveAcceptedHRProtectionWindow: TimeInterval = 45
    private let rangeLossBackfillRetryInterval: TimeInterval = 10 * 60
    private var rangeLossBackfillTask: Task<Void, Never>?
    @Published private(set) var standardHROnlyEnabled = UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
    @Published private(set) var longWearModeEnabled = UserDefaults.standard.bool(forKey: LongWearDefaults.enabled)
    @Published private(set) var collectionProfile = CollectionProfile.load()
    private nonisolated(unsafe) var standardHROnlyMode = UserDefaults.standard.bool(forKey: RadioDefaults.standardHROnly)
    private var historicalArchiveRows = 0
    private var historicalArchiveRowsSinceAck = 0
    private var historicalArchiveWriteFailures = 0
    private var lastHistoricalArchivePath = ""
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
    private var strapStepResearchCount = 0
    private var strapStepResearchPeakCount = 0
    private var strapStepResearchState = "research_unvalidated"
    private var researchProbeFrameCount = 0
    private var researchProbeOxygenCandidateFrames = 0
    private var researchProbeTemperatureCandidateFrames = 0
    private var researchProbeTemperatureCandidateValueSum = 0
    private var researchProbeTemperatureCandidateValueCount = 0
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
    private var debugActiveJournalFlushTask: Task<Void, Never>?
    private var debugManualCheckpointTask: Task<Void, Never>?
    private var debugNoDataWatchdogTask: Task<Void, Never>?
    private var debugHRContinuityWatchdogTask: Task<Void, Never>?
    private var debugRRPresenceWatchdogTask: Task<Void, Never>?
    private var debugMissingHeartRateCharacteristicTask: Task<Void, Never>?
    private var debugMissingHeartRateCharacteristicAfterDiscovery: TimeInterval?
    private var debugMissingHeartRateCharacteristicFired = false
    private var debugAcceptedHRWatchdogTask: Task<Void, Never>?
    private var hrConsistencyEnabled = false
    private var lastStandardHR: (bpm: Int, t: Date)?
    private var lastRealtimeHR: (bpm: Int, t: Date)?
    private var lastHRVRefreshAt: Date?
    private var lastRawHRNotificationAt: Date?
    /// Timestamp of the most recent inbound GATT value of ANY kind (battery, HR,
    /// device-info…). Battery (0x2A19) reads recur every few seconds on a live
    /// link, so this proves the link is alive even when the HR stream (0x2A37) is
    /// briefly silent in low-radio mode — used so the no-data watchdog can't tear
    /// down a genuinely connected peripheral.
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
    // Foreground updates can stay responsive without recomputing every pulse.
    private let liveHRVRefreshMinimumInterval: TimeInterval = 1.5
    private var sampleDiagnostics = SampleDiagnosticsSnapshot.load()
    private var sampleDiagnosticsFlushTask: Task<Void, Never>?
    private var hrConsistencyPairs = 0
    private var hrConsistencyDeltaSum = 0
    private var hrConsistencyMaxDelta = 0
    private var hrConsistencyRecentDeltas: [Int] = []
    private var hrConsistencyLastLogAt: Date?
    private var verboseBLEFrameLogging = false
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
    }

    private var central: CBCentralManager!
    private let centralQueue = DispatchQueue(label: "com.adidshaft.atria.ble-central",
                                             qos: .utility)
    private nonisolated let historicalArchiveQueue = DispatchQueue(label: "com.adidshaft.atria.historical-archive",
                                                                   qos: .utility)
    private var peripheral: CBPeripheral?
    private let maxFrames = 200
    private let centralRestoreIdentifier = "com.adidshaft.atria.ble-central"
    private let minimumEventDrivenCheckpointInterval: TimeInterval = 180
    private var lastEventDrivenCheckpointAt: Date?
    private let reconnectWatchdogSeconds: TimeInterval = 20
    private var reconnectWatchdogTask: Task<Void, Never>?
    private var scanRetryTask: Task<Void, Never>?
    private var scanWideningTask: Task<Void, Never>?
    private var pendingScanReason: String?
    private var freshScanFallbackTask: Task<Void, Never>?
    private var recoveryReconnectAttempt = 0
    private var pendingRecoveryReconnectReason: String?
    private var scanRetryCount = 0
    private let maxScanRetries = 4
    private var forceFreshScanOnRestore = false
    private var forceFreshScanAfterDisconnect = false
    private let minimumFinishedLongWearDuration: TimeInterval = 5 * 60
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
    private let activeJournalMaxAge: TimeInterval = 18 * 60 * 60
    private let activeJournalMaxSamples = 90_000
    private let activeJournalSegmentGapLimit: TimeInterval = 30
    private var activeJournalDirtySamples = 0
    private var activeJournalSaveInFlight = false
    private var activeJournalPendingSave = false
    private var lastActiveJournalSaveAt: Date?
    private var lastActiveJournalSavedSessionSampleCount = 0
    private var lastActiveJournalSavedRRArchiveCount = 0
    private var foregroundInteractiveMode = true
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
        super.init()
        let arguments = ProcessInfo.processInfo.arguments
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
            migrateOfflineSyncDefaultIfNeeded(arguments: arguments)
            if arguments.contains("--atria-long-wear-mode") {
                UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
                UserDefaults.standard.set(true, forKey: LongWearDefaults.userSelected)
                UserDefaults.standard.set(true, forKey: LongWearDefaults.enabled)
                longWearModeEnabled = true
            }
        }
        if !arguments.contains("--atria-full-protocol-mode"),
           arguments.contains("--atria-standard-hr-only") || arguments.contains("--atria-long-wear-mode") {
            standardHROnlyMode = true
            standardHROnlyEnabled = true
            forceFreshScanOnRestore = true
        }
        applyEarlyHistoricalLaunchConfiguration(arguments: arguments)
        hydrateCachedBatteryStateIfFresh()
        updateSessionPointCacheMode()
        logActiveMotionIMUCheckPlanIfRequested(arguments: arguments)
        updatePhoneMotionAuditState(reason: "init")
        powerThermalGovernor.onChange = { [weak self] mode in
            guard let self else { return }
            AtriaDebugLog("ATRIADBG power_thermal_governor mode=%@ multiplier=%.1f low_power=%d thermal=%@",
                  mode.rawValue,
                  self.powerThermalGovernor.cadenceMultiplier,
                  ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
                  Self.thermalStateLabel(ProcessInfo.processInfo.thermalState))
        }
        central = CBCentralManager(delegate: self,
                                   queue: centralQueue,
                                   options: [
                                       CBCentralManagerOptionRestoreIdentifierKey: centralRestoreIdentifier,
                                       CBCentralManagerOptionShowPowerAlertKey: true
        ])
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
        if !historyInitSweepCommands.isEmpty {
            historySkipDataRangeRequest = true
        }
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

    private func hydrateCachedBatteryStateIfFresh(maxAge: TimeInterval = 86_400) {
        let cached = Self.cachedBattery(maxAge: maxAge)
        guard cached.usable else { return }
        batteryLevel = cached.level
        batteryChargeStatus = cached.chargeStatus
        batteryIsCharging = cached.chargeStatus == .charging
        batteryRecentlyDropping = Self.cachedBatteryDrop().recent
    }

    private func resetProductionCaptureDefaultsForDebug() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CaptureDefaults.configured)
        defaults.removeObject(forKey: LongWearDefaults.enabled)
        defaults.removeObject(forKey: LongWearDefaults.userSelected)
        defaults.removeObject(forKey: RadioDefaults.standardHROnly)
        defaults.removeObject(forKey: LongWearDefaults.checkpointInterval)
        defaults.removeObject(forKey: LongWearDefaults.diagnosticInterval)
        defaults.removeObject(forKey: LongWearDefaults.workoutAutoSaveInterval)
        defaults.removeObject(forKey: LongWearDefaults.noDataTimeout)
        defaults.removeObject(forKey: LongWearDefaults.noDataCheckInterval)
        defaults.removeObject(forKey: LongWearDefaults.acceptedHRTimeout)
        defaults.removeObject(forKey: LongWearDefaults.label)
        defaults.removeObject(forKey: CollectionProfileDefaults.profile)
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
            defaults.set("Long wear", forKey: LongWearDefaults.label)
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
        recordRadioMode("standard_hr_only", reason: "protected_default")
        AtriaDebugLog("ATRIADBG capture_defaults status=enabled mode=protected_long_wear_default long_wear_default=1 standard_hr_only_default=1 offline_sync_default=1 reason=first_normal_launch explicit_mode_arg=%d checkpoint_interval_s=60 live_workout_interval_s=15 workout_autosave_interval_s=15 no_data_timeout_s=75 accepted_hr_timeout_s=45 hr_continuity_timeout_s=6 recovery_policy=staged_read_reassert_then_fresh_scan",
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
        recordRadioMode("standard_hr_only", reason: "protected_default_migration")
        AtriaDebugLog("ATRIADBG long_wear_mode status=migrated_default action=enabled reason=protected_background_collection_default")
    }

    private func migrateOfflineSyncDefaultIfNeeded(arguments: [String]) {
        guard !arguments.contains("--atria-full-protocol-mode") else { return }
        guard UserDefaults.standard.object(forKey: OfflineSyncDefaults.enabled) == nil else { return }
        UserDefaults.standard.set(true, forKey: OfflineSyncDefaults.enabled)
        AtriaDebugLog("ATRIADBG offline_sync status=migrated_default action=enabled reason=stored_session_backfill_default")
    }

    func setStandardHROnlyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
        applyStandardHROnly(enabled: enabled, persist: true, reconnect: true, reason: "user_toggle")
    }

    func setLongWearModeEnabled(_ enabled: Bool, rest: Int, maxHR: Int) {
        UserDefaults.standard.set(true, forKey: CaptureDefaults.configured)
        UserDefaults.standard.set(true, forKey: LongWearDefaults.userSelected)
        UserDefaults.standard.set(enabled, forKey: LongWearDefaults.enabled)
        longWearModeEnabled = enabled
        updateSessionPointCacheMode()
        updatePhoneMotionAuditState(reason: enabled ? "long_wear_enabled" : "long_wear_disabled")
        if enabled {
            applyStandardHROnly(enabled: true, persist: true, reconnect: true, reason: "long_wear")
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
            updatePhoneMotionAuditState(reason: "persisted_long_wear_disabled")
            return
        }
        longWearModeEnabled = true
        updateSessionPointCacheMode()
        guard !foregroundInteractiveMode else {
            return
        }
        updatePhoneMotionAuditState(reason: "persisted_long_wear_enabled")
        applyStandardHROnly(enabled: true, persist: true, reconnect: false, reason: "long_wear_persisted")
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
        let label = defaults.string(forKey: LongWearDefaults.label) ?? "Long wear"
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
        updatePhoneMotionAuditState(reason: "stop_long_wear")
        AtriaDebugLog("ATRIADBG long_wear_mode enabled=0 reason=%@ checkpoint_cancelled=1 live_workout_cancelled=1 workout_autosave_cancelled=1 no_data_watchdog_cancelled=1 hr_continuity_watchdog_cancelled=1 accepted_hr_watchdog_cancelled=1",
              reason)
    }

    private func pauseLongWearAutomation(reason: String) {
        delayedSessionSaveTask?.cancel()
        liveWorkoutDiagnosticTask?.cancel()
        workoutAutoSaveTask?.cancel()
        longWearSupervisorTask?.cancel()
        noDataWatchdogTask?.cancel()
        debugNoDataWatchdogTask?.cancel()
        hrContinuityWatchdogTask?.cancel()
        rrPresenceWatchdogTask?.cancel()
        debugHRContinuityWatchdogTask?.cancel()
        acceptedHRWatchdogTask?.cancel()
        debugAcceptedHRWatchdogTask?.cancel()
        debugRRPresenceWatchdogTask?.cancel()
        longWearSupervisorTask = nil
        UserDefaults.standard.set(false, forKey: CheckpointDefaults.armed)
        AtriaDebugLog("ATRIADBG long_wear_mode paused=1 reason=%@ foreground_interactive=%d",
              reason,
              foregroundInteractiveMode ? 1 : 0)
    }

    func handleInteractiveForeground(rest: Int, maxHR: Int) {
        resumeForegroundScanIfNeeded(reason: "scene_active")
        // Arm the silent-link safety net whenever we are foreground + long-wear,
        // including a fresh foreground launch where foregroundInteractiveMode is
        // already true (the all-night, screen-on scenario). Idempotent: only
        // starts when not already running.
        ensureForegroundKeepaliveWatchdog(reason: "scene_active")
        reassertHeartRateNotificationsIfConnected(reason: "scene_active")
        if foregroundInteractiveMode {
            return
        }
        foregroundInteractiveMode = true
        guard longWearModeEnabled else {
            updatePhoneMotionAuditState(reason: "interactive_foreground_without_long_wear")
            return
        }
        pauseLongWearAutomation(reason: "scene_active")
        updatePhoneMotionAuditState(reason: "scene_active")
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=1 action=defer_automation_keepalive_armed rest_hr=%d max_hr=%d",
              rest,
              maxHR)
    }

    private func reassertHeartRateNotificationsIfConnected(reason: String) {
        guard status == .connected, let peripheral else { return }
        if let characteristic = heartRateCharacteristic {
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
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

    /// Runs while long-wear is enabled, including app-switch/background
    /// transitions. It does nothing while data flows. If the link is `.connected`
    /// but has produced no 2A37 packet for an extended window, it re-asserts the
    /// subscription, then escalates to a fresh-scan reconnect if silence
    /// persists. requestFreshScanReconnect already backs off exponentially.
    private func ensureForegroundKeepaliveWatchdog(reason: String) {
        guard longWearModeEnabled else {
            stopForegroundKeepaliveWatchdog(reason: reason)
            return
        }
        guard foregroundKeepaliveTask == nil else { return }
        startForegroundKeepaliveWatchdog(reason: reason)
    }

    private func startForegroundKeepaliveWatchdog(reason: String) {
        foregroundKeepaliveTask?.cancel()
        foregroundKeepaliveReassertAt = nil
        foregroundKeepaliveLastJournalFlushAt = nil
        let silenceTimeout: TimeInterval = 75
        let initialSilenceTimeout: TimeInterval = 8
        let initialReconnectWindow: TimeInterval = 20
        let checkInterval: TimeInterval = 20
        let armedAt = Date()
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: KeepaliveDefaults.armed)
        defaults.set("armed", forKey: KeepaliveDefaults.lastStatus)
        defaults.set(reason, forKey: KeepaliveDefaults.lastReason)
        defaults.set("observe", forKey: KeepaliveDefaults.lastAction)
        defaults.set(0.0, forKey: KeepaliveDefaults.lastSilence)
        AtriaDebugLog("ATRIADBG foreground_keepalive armed=1 reason=%@ silence_timeout_s=%.0f check_interval_s=%.0f",
              reason, silenceTimeout, checkInterval)
        foregroundKeepaliveTask = Task { @MainActor in
            var nextSleep = initialSilenceTimeout
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(nextSleep))
                nextSleep = checkInterval
                if Task.isCancelled { break }
                guard longWearModeEnabled else { continue }
                guard status == .connected, let peripheral else { continue }
                let now = Date()
                let defaults = UserDefaults.standard
                defaults.set(defaults.integer(forKey: KeepaliveDefaults.ticks) + 1, forKey: KeepaliveDefaults.ticks)
                // Fall back to the keepalive's own arm time so silence is always
                // measurable — a state-restored connection (the overnight case)
                // can have no lastRawHRNotificationAt and no connectedAt at all,
                // which previously left this watchdog unable to ever fire.
                let reference = lastRawHRNotificationAt ?? connectedAt ?? armedAt
                let silence = now.timeIntervalSince(reference)
                let hasSeenPacket = lastRawHRNotificationAt != nil
                let effectiveSilenceTimeout = hasSeenPacket ? silenceTimeout : initialSilenceTimeout
                defaults.set(silence, forKey: KeepaliveDefaults.lastSilence)
                guard silence >= effectiveSilenceTimeout else {
                    foregroundKeepaliveReassertAt = nil
                    defaults.set("observing", forKey: KeepaliveDefaults.lastStatus)
                    defaults.set("observe", forKey: KeepaliveDefaults.lastAction)
                    // Keep the live session crash-safe even during a long
                    // foreground stretch (the supervisor that normally checkpoints
                    // is paused while foreground). Flush the active-session journal
                    // at most once a minute; persistActiveSessionJournalIfNeeded
                    // no-ops when nothing has changed, so this is cheap.
                    if foregroundKeepaliveLastJournalFlushAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
                        foregroundKeepaliveLastJournalFlushAt = now
                        flushActiveSessionJournal(reason: "foreground_keepalive_crash_safety")
                    }
                    continue
                }
                // First escalation: re-assert the 2A37 subscription and keep the
                // connection. Many silent links resume from a fresh subscribe.
                if foregroundKeepaliveReassertAt == nil {
                    foregroundKeepaliveReassertAt = now
                    if let characteristic = heartRateCharacteristic {
                        if characteristic.properties.contains(.notify) {
                            peripheral.setNotifyValue(true, for: characteristic)
                        }
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
                    continue
                }
                // Still silent after a re-assert window: the link is effectively
                // dead. Reconnect (backoff-guarded) and let it re-establish.
                let reconnectWindow = hasSeenPacket ? silenceTimeout : initialReconnectWindow
                guard now.timeIntervalSince(foregroundKeepaliveReassertAt ?? now) >= reconnectWindow else { continue }
                foregroundKeepaliveReassertAt = nil
                preserveLongWearRangeLossRecovery(reason: "foreground_keepalive")
                defaults.set("silent", forKey: KeepaliveDefaults.lastStatus)
                defaults.set("fresh_scan_reconnect", forKey: KeepaliveDefaults.lastAction)
                AtriaDebugLog("ATRIADBG foreground_keepalive status=silent silence_s=%.0f action=fresh_scan_reconnect",
                      silence)
                requestFreshScanReconnect(peripheral: peripheral, reason: "foreground_keepalive")
            }
        }
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
    }

    func refreshPhoneStepsToday(reason: String) {
        guard CMPedometer.isStepCountingAvailable() else {
            phoneStepsToday = 0
            phoneDistanceTodayMeters = nil
            phoneFloorsToday = nil
            AtriaDebugLog("ATRIADBG phone_steps_today status=unavailable reason=%@ source=CMPedometer", reason)
            return
        }
        let start = Calendar.current.startOfDay(for: Date())
        let now = Date()
        phonePedometer.queryPedometerData(from: start, to: now) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    AtriaDebugLog("ATRIADBG phone_steps_today status=error reason=%@ error=%@ source=CMPedometer", reason, String(describing: error))
                    return
                }
                guard let data else { return }
                self.recordPhoneStepsToday(data)
                AtriaDebugLog("ATRIADBG phone_steps_today status=ready reason=%@ steps=%d distance_m=%@ source=CMPedometer validated=1",
                              reason,
                              self.phoneStepsToday,
                              Self.formatDouble(self.phoneDistanceTodayMeters))
            }
        }
        startPhoneStepEvidenceIfNeeded(start: start, reason: "today_\(reason)")
    }

    func pausePhoneStepUpdates(reason: String) {
        stopPhoneStepEvidence(reason: reason)
    }

    func handleUnattendedMode(rest: Int, maxHR: Int, reason: String) {
        if !foregroundInteractiveMode {
            ensureForegroundKeepaliveWatchdog(reason: reason)
            return
        }
        foregroundInteractiveMode = false
        guard longWearModeEnabled else {
            stopForegroundKeepaliveWatchdog(reason: reason)
            updatePhoneMotionAuditState(reason: reason)
            return
        }
        updatePhoneMotionAuditState(reason: reason)
        ensureForegroundKeepaliveWatchdog(reason: reason)
        startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=0 action=resume_automation reason=%@ rest_hr=%d max_hr=%d",
              reason,
              rest,
              maxHR)
    }

    func handleSceneBackgroundTransition(reason: String, rest: Int, maxHR: Int) {
        foregroundInteractiveMode = false
        flushLifecycleRealtimeState(reason: reason)
        updatePhoneMotionAuditState(reason: reason)
        if longWearModeEnabled {
            startLongWearMode(rest: rest, maxHR: maxHR, reason: reason)
        } else {
            ensureForegroundKeepaliveWatchdog(reason: reason)
        }
        reassertHeartRateNotificationsIfConnected(reason: reason)
        AtriaDebugLog("ATRIADBG long_wear_mode foreground_interactive=0 action=background_keep_link reason=%@ connected=%d",
              reason,
              status == .connected ? 1 : 0)
    }

    @discardableResult
    func requestOfflineHistoricalSyncIfNeeded(reason: String, force: Bool = false) -> Bool {
        let defaults = UserDefaults.standard
        let now = Date()
        guard defaults.bool(forKey: OfflineSyncDefaults.enabled) else {
            defaults.set("disabled", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=skipped reason=%@ detail=disabled", reason)
            return false
        }
        guard !offlineHistoricalSyncInProgress else {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("coalesced", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=coalesced reason=%@", reason)
            return false
        }
        if !force, shouldProtectLiveStreamForOfflineSync(now: now) {
            pendingOfflineHistoricalSyncReason = reason
            defaults.set("deferred_live_link", forKey: OfflineSyncDefaults.lastStatus)
            defaults.set(reason, forKey: OfflineSyncDefaults.lastReason)
            AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=live_hr_recent action=keep_ble_stream accepted_age_s=%.1f samples=%d",
                  reason,
                  lastAcceptedHRAt.map { now.timeIntervalSince($0) } ?? -1,
                  session.count)
            return false
        }
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
        startOfflineHistoricalSync(reason: reason, force: force)
        return true
    }

    private func startOfflineHistoricalSync(reason: String, force: Bool) {
        flushActiveSessionJournal(reason: "offline_sync_preflight_\(reason)")
        offlineHistoricalSyncInProgress = true
        historyOnlyProbeEnabled = true
        historyOnlyProbeMode = true
        historyOnlyProbeArmed = false
        historyClockSyncEnabled = true
        historicalAckDisabled = false
        historyAckMode = "enddata"
        probeCommandMode = .withResponse
        historyInitSweepCommands = [
            [Cmd.abortHistoricalTransmits, 0x00],
            [Cmd.enterHighFreqSync, 0x00],
            [Cmd.sendHistoricalData, 0x00],
        ]
        historySkipDataRangeRequest = true
        historyDataRangeSweepEnabled = false
        historyDataRangePendingRequests.removeAll()
        ackedHistoryAckKeys.removeAll()
        txCharacteristic = nil
        realtimeArmed = false
        realtimeOn = false
        UserDefaults.standard.set("armed", forKey: OfflineSyncDefaults.lastStatus)
        UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
        AtriaDebugLog("ATRIADBG offline_sync status=armed reason=%@ mode=noop_backfill init_sweep=1400,6000,1600 ack_mode=enddata live_realtime=skipped metrics_fail_closed=1",
              reason)

        if let peripheral {
            guard force || !shouldProtectLiveStreamForOfflineSync(now: Date()) else {
                offlineHistoricalSyncInProgress = false
                historyOnlyProbeEnabled = false
                historyOnlyProbeMode = false
                historyOnlyProbeArmed = false
                historyClockSyncEnabled = false
                historyInitSweepCommands.removeAll()
                historySkipDataRangeRequest = false
                probeCommandMode = .withoutResponse
                pendingOfflineHistoricalSyncReason = reason
                UserDefaults.standard.set("deferred_live_link", forKey: OfflineSyncDefaults.lastStatus)
                UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
                AtriaDebugLog("ATRIADBG offline_sync status=deferred reason=%@ detail=live_hr_recent_late action=keep_ble_stream samples=%d",
                      reason,
                      session.count)
                return
            }
            dbgLast = "offline sync reconnect"
            switch peripheral.state {
            case .connected, .connecting:
                central.cancelPeripheralConnection(peripheral)
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

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            finishOfflineHistoricalSync(reason: reason)
        }
    }

    private func finishOfflineHistoricalSync(reason: String) {
        let rows = historicalArchiveRows
        historyOnlyProbeEnabled = false
        historyOnlyProbeMode = false
        historyOnlyProbeArmed = false
        historyClockSyncEnabled = false
        historyInitSweepCommands.removeAll()
        historySkipDataRangeRequest = false
        probeCommandMode = .withoutResponse
        offlineHistoricalSyncInProgress = false
        UserDefaults.standard.set(rows > 0 ? "archived" : "no_rows", forKey: OfflineSyncDefaults.lastStatus)
        UserDefaults.standard.set(reason, forKey: OfflineSyncDefaults.lastReason)
        AtriaDebugLog("ATRIADBG offline_sync status=%@ reason=%@ rows=%d failures=%d action=return_standard_hr metrics_fail_closed=1",
              rows > 0 ? "archived" : "no_rows",
              reason,
              rows,
              historicalArchiveWriteFailures)
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) {
            if rows > 0 {
                defaults.set(false, forKey: OfflineSyncDefaults.rangeLossBackfillPending)
                defaults.set(Date().timeIntervalSince1970, forKey: OfflineSyncDefaults.rangeLossBackfillStartedAt)
                assignIfChanged(\.rangeLossBackfillPending, false)
            } else {
                scheduleRangeLossBackfillRetry(reason: reason)
            }
        }
        applyStandardHROnly(enabled: true, persist: true, reconnect: true, reason: "offline_sync_complete")
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        if let pending = pendingOfflineHistoricalSyncReason {
            pendingOfflineHistoricalSyncReason = nil
            requestOfflineHistoricalSyncIfNeeded(reason: pending)
        }
    }

    private func markRangeLossBackfillRequired(reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: OfflineSyncDefaults.rangeLossBackfillPending)
        defaults.set(Date().timeIntervalSince1970, forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt)
        defaults.set(reason, forKey: OfflineSyncDefaults.rangeLossBackfillReason)
        assignIfChanged(\.rangeLossBackfillPending, true)
        pendingOfflineHistoricalSyncReason = reason
        AtriaDebugLog("ATRIADBG offline_sync status=pending_range_loss_backfill reason=%@ action=sync_after_reconnect",
              reason)
    }

    private func preserveLongWearRangeLossRecovery(reason: String) {
        guard longWearModeEnabled else { return }
        guard !offlineHistoricalSyncInProgress else {
            AtriaDebugLog("ATRIADBG offline_sync status=skip_range_loss_mark reason=%@ detail=sync_in_progress",
                          reason)
            return
        }
        persistActiveSessionJournalIfNeeded(reason: "\(reason)_continuity_checkpoint", force: true)
        markRangeLossBackfillRequired(reason: "long_wear_range_loss")
        if status == .connected {
            scheduleRangeLossBackfillIfNeeded(reason: reason)
        }
    }

    private func scheduleRangeLossBackfillIfNeeded(reason: String) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.enabled) else { return }
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else { return }
        guard !offlineHistoricalSyncInProgress else { return }
        rangeLossBackfillTask?.cancel()
        rangeLossBackfillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            guard UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) else { return }
            guard status != .poweredOff else { return }
            let backfillReason = UserDefaults.standard.string(forKey: OfflineSyncDefaults.rangeLossBackfillReason) ?? reason
            let protectedLiveStream = shouldProtectLiveStreamForOfflineSync()
            let forceStaleBackfill = shouldForceStaleRangeLossBackfill()
            AtriaDebugLog("ATRIADBG offline_sync status=requesting_range_loss_backfill reason=%@ trigger=%@ action=%@ live_protected=%d stale_force=%d",
                  backfillReason,
                  reason,
                  forceStaleBackfill ? "force_stale_backfill" : (protectedLiveStream ? "defer_live_stream" : "sync_when_available"),
                  protectedLiveStream ? 1 : 0,
                  forceStaleBackfill ? 1 : 0)
            if !requestOfflineHistoricalSyncIfNeeded(reason: backfillReason, force: forceStaleBackfill),
               UserDefaults.standard.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) {
                scheduleRangeLossBackfillRetry(reason: reason)
            }
        }
    }

    private func scheduleRangeLossBackfillRetry(reason: String) {
        rangeLossBackfillTask?.cancel()
        rangeLossBackfillTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(rangeLossBackfillRetryInterval))
            guard !Task.isCancelled else { return }
            scheduleRangeLossBackfillIfNeeded(reason: "\(reason)_retry")
        }
    }

    private func shouldForceStaleRangeLossBackfill(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending),
              let requestedAt = defaults.object(forKey: OfflineSyncDefaults.rangeLossBackfillRequestedAt) as? Double else {
            return false
        }
        return now.timeIntervalSince1970 - requestedAt >= rangeLossBackfillRetryInterval
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
        guard longWearModeEnabled else { return false }
        guard let peripheral, peripheral.state == .connected else { return false }
        guard hasContact else { return false }
        guard session.count >= autoSaveMinSamples else { return false }
        guard let lastAcceptedHRAt else { return false }
        return now.timeIntervalSince(lastAcceptedHRAt) <= offlineSyncLiveAcceptedHRProtectionWindow
    }

    private func resumeForegroundScanIfNeeded(reason: String) {
        guard peripheral == nil else { return }
        guard status == .disconnected || status == .poweredOff else { return }
        startScan(reason: "\(reason)_resume")
    }

    private func applyStandardHROnly(enabled: Bool, persist: Bool, reconnect: Bool, reason: String) {
        let previous = standardHROnlyMode
        standardHROnlyMode = enabled
        standardHROnlyEnabled = enabled
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
              enabled ? "standard_hr_only" : "full_protocol",
              persist ? 1 : 0,
              reconnect ? 1 : 0,
              reason)
        recordRadioMode(enabled ? "standard_hr_only" : "full_protocol", reason: reason)
        guard reconnect, previous != enabled, let peripheral else { return }
        txCharacteristic = nil
        heartRateCharacteristic = nil
        dbgTxReady = false
        realtimeArmed = false
        dbgLast = enabled ? "standard hr only pending reconnect" : "full protocol pending reconnect"
        central.cancelPeripheralConnection(peripheral)
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
        return "radio_mode=\(mode); radio_standard_hr_only=\(persistedStandardOnly ? 1 : 0); radio_custom_notify_skipped=\(defaults.integer(forKey: RadioDefaults.customNotifySkipped)); radio_custom_notify_enabled=\(defaults.integer(forKey: RadioDefaults.customNotifyEnabled)); radio_tx_skipped=\(defaults.integer(forKey: RadioDefaults.txSkipped)); radio_realtime_start_skipped=\(defaults.integer(forKey: RadioDefaults.realtimeStartSkipped)); radio_last_reason=\(reason)"
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
        return String(format: "offline_sync_enabled=%d; offline_sync_attempts=%d; offline_sync_last_status=%@; offline_sync_last_reason=%@; offline_range_loss_backfill_pending=%d; offline_range_loss_backfill_reason=%@; offline_range_loss_backfill_requested_age_s=%.1f; offline_range_loss_backfill_started_age_s=%.1f",
                      defaults.bool(forKey: OfflineSyncDefaults.enabled) ? 1 : 0,
                      defaults.integer(forKey: OfflineSyncDefaults.attempts),
                      status,
                      reason,
                      defaults.bool(forKey: OfflineSyncDefaults.rangeLossBackfillPending) ? 1 : 0,
                      rangeReason,
                      requestedAge,
                      startedAge)
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

    static func cachedBattery(maxAge: TimeInterval = 86_400) -> (level: Int, source: String, age: TimeInterval, chargeStatus: BatteryChargeStatus, chargeAge: TimeInterval, usable: Bool) {
        let defaults = UserDefaults.standard
        let level = defaults.object(forKey: BatteryDefaults.level) as? Int ?? -1
        let at = defaults.object(forKey: BatteryDefaults.at) as? Double
        let age = at.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        let source = evidenceToken(defaults.string(forKey: BatteryDefaults.source) ?? (level >= 0 ? "cached_2A19" : "none"))
        let rawCharge = defaults.string(forKey: BatteryDefaults.chargeStatus) ?? BatteryChargeStatus.levelOnly.rawValue
        let chargeStatus = BatteryChargeStatus(rawValue: rawCharge) ?? .levelOnly
        let chargeAt = defaults.object(forKey: BatteryDefaults.chargeAt) as? Double
        let chargeAge = chargeAt.map { max(0, Date().timeIntervalSince1970 - $0) } ?? -1
        let chargeFresh = chargeStatus == .levelOnly || (chargeAge >= 0 && chargeAge <= maxAge)
        return (level, source, age, chargeStatus, chargeAge, level >= 0 && age >= 0 && age <= maxAge && chargeFresh)
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
        resetRecoveryReconnectBackoff(reason: "did_connect")
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
        recordRadioMode(standardHROnlyMode ? "standard_hr_only" : "full_protocol", reason: "launch")
    }

    private func resetProtocolDiagnosticsForDebugLaunch(arguments: [String]) {
        protocolPacketCount = 0
        protocolIMUFrameCount = 0
        resetIMUFeatureStats()
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
        AtriaDebugLog("ATRIADBG active_motion_imu_check status=%@ delay_s=%.0f protocol_packets=%d protocol_imu_frames=%d protocol_diagnostic_frames=%d protocol_event_frames=%d protocol_unknown_frames=%d protocol_last_type=%@ protocol_last_kind=%@ sleep_motion_hint_count=%d sleep_motion_hint_kinds=%@ phone_motion_samples=%d phone_motion_over_still_threshold=%d phone_motion_validated=0 wrist_motion_validated=0 metric_promotions=0 action=%@",
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
              phoneMotionSamples,
              phoneMotionOverStillThreshold,
              signalSeen ? "inspect_protocol_before_any_metric_use" : "keep_sleep_motion_learning_until_validated")
    }

    private func recordRadioMode(_ mode: String, reason: String) {
        let defaults = UserDefaults.standard
        defaults.set(mode, forKey: RadioDefaults.mode)
        defaults.set(reason, forKey: RadioDefaults.lastReason)
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
        guard longWearModeEnabled else { return }
        guard session.isEmpty else {
            AtriaDebugLog("ATRIADBG active_session_journal status=restore_skipped reason=live_session_active samples=%d", session.count)
            return
        }
        guard let record = ActiveSessionJournal.load() else {
            AtriaDebugLog("ATRIADBG active_session_journal status=absent reason=%@", reason)
            return
        }
        guard record.schema == ActiveSessionJournal.schema else {
            ActiveSessionJournal.clear()
            AtriaDebugLog("ATRIADBG active_session_journal status=cleared reason=schema_mismatch schema=%d", record.schema)
            return
        }
        let now = Date()
        let age = now.timeIntervalSince(record.updatedAt)
        guard age <= activeJournalMaxAge else {
            ActiveSessionJournal.clear()
            AtriaDebugLog("ATRIADBG active_session_journal status=cleared reason=stale age_s=%.0f max_age_s=%.0f samples=%d",
                  age, activeJournalMaxAge, record.samples.count)
            return
        }
        let samples = record.samples
            .filter { now.timeIntervalSince($0.t) <= activeJournalMaxAge }
            .suffix(activeJournalMaxSamples)
        let rrSamples = (record.rrSamples ?? [])
            .filter { now.timeIntervalSince($0.t) <= activeJournalMaxAge }
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            ActiveSessionJournal.clear()
            AtriaDebugLog("ATRIADBG active_session_journal status=cleared reason=insufficient_samples samples=%d", record.samples.count)
            return
        }

        if age >= activeJournalSegmentGapLimit {
            let label = record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Long wear" : record.label
            let scopedRR = rrSamples.filter { $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1) }
            let saved = SavedSession(id: record.id,
                                     start: first.t,
                                     end: last.t,
                                     label: label,
                                     points: samples.map { SavedSession.Point(t: $0.t.timeIntervalSince(first.t), bpm: $0.bpm) },
                                     hrv: nil,
                                     rrPoints: scopedRR.isEmpty ? nil : scopedRR.map {
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
                                     hrRaw2A37: record.rawHRNotifications,
                                     hrAccepted: record.acceptedHRSamples,
                                     hrZero: record.zeroHRSamples,
                                     hrArtifactHeld: record.heldArtifacts,
                                     hrArtifactDropped: record.droppedArtifacts,
                                     hrRawGaps: record.rawHRGaps,
                                     hrAcceptedGaps: record.acceptedHRGaps,
                                     hrMaxRawGap: record.maxRawHRGap,
                                     hrMaxAcceptedGap: record.maxAcceptedHRGap)
            let persisted = persistFinishedSession(saved, reason: "stale_journal_restore")
            resetLiveSessionState(start: now)
            AtriaDebugLog("ATRIADBG active_session_journal status=%@ reason=stale_restore age_s=%.0f threshold_s=%.1f samples=%d rr_values=%d duration_s=%.0f action=%@",
                  persisted ? "closed" : "close_failed",
                  age,
                  activeJournalSegmentGapLimit,
                  saved.points.count,
                  saved.rrSampleCount,
                  saved.duration,
                  persisted ? "start_fresh_before_diagnostics" : "retain_store_for_retry")
            return
        }

        liveSessionID = record.id
        sessionStart = first.t
        session = samples.map { HRSample(t: $0.t, bpm: $0.bpm) }
        sessionSampleCount = session.count
        rebuildSessionHeartRateStats()
        var restoredTail: [Int] = []
        restoredTail.reserveCapacity(min(session.count, 60))
        for sample in session.suffix(60) {
            restoredTail.append(sample.bpm)
        }
        replaceLastHeartRates(restoredTail)

        var restoredRecentValid: [Int] = []
        restoredRecentValid.reserveCapacity(min(session.count, 5))
        for sample in session.suffix(5) {
            restoredRecentValid.append(sample.bpm)
        }
        recentValid = restoredRecentValid
        assignIfChanged(\.heartRate, median(recentValid) ?? last.bpm)
        assignIfChanged(\.hasContact, true)
        rrArchive = rrSamples
            .filter { $0.t >= first.t && $0.t <= last.t.addingTimeInterval(1) }
            .map { RRInterval(t: $0.t, ms: Double($0.ms), expectedHR: nil) }
        var restoredRecentBeatTimes: [Date] = []
        restoredRecentBeatTimes.reserveCapacity(min(rrArchive.count, 720))
        for beat in rrArchive where now.timeIntervalSince(beat.t) <= Self.recentRRBeatWindowSeconds {
            restoredRecentBeatTimes.append(beat.t)
        }
        recentRRBeatTimes = restoredRecentBeatTimes
        rebuildSessionCaches()
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
        activeJournalDirtySamples = 0
        lastActiveJournalSavedSessionSampleCount = session.count
        lastActiveJournalSavedRRArchiveCount = rrArchive.count
        if !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            captureLabel = record.label
        }
        let duration = last.t.timeIntervalSince(first.t)
        AtriaDebugLog("ATRIADBG active_session_journal status=restored reason=%@ samples=%d rr_values=%d duration_s=%.0f age_s=%.0f label=%@",
              reason, session.count, rrArchive.count, duration, age, captureLabel)
    }

    private func persistActiveSessionJournalIfNeeded(reason: String, force: Bool) {
        guard longWearModeEnabled else { return }
        guard !session.isEmpty else { return }
        if force,
           !activeJournalSaveInFlight,
           activeJournalDirtySamples == 0,
           lastActiveJournalSavedSessionSampleCount == session.count,
           lastActiveJournalSavedRRArchiveCount == rrArchive.count {
            return
        }
        let flushSampleInterval = foregroundInteractiveMode
            ? activeJournalInteractiveFlushSampleInterval
            : activeJournalFlushSampleInterval
        let minimumFlushInterval = foregroundInteractiveMode
            ? activeJournalInteractiveFlushMinimumInterval
            : activeJournalUnattendedFlushMinimumInterval
        let governedMinimumFlushInterval = min(minimumFlushInterval * powerThermalGovernor.cadenceMultiplier,
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
            return
        }
        let sessionWindow = Self.prunedJournalSamples(from: session,
                                                      now: now,
                                                      maxAge: activeJournalMaxAge,
                                                      maxSamples: activeJournalMaxSamples)
        guard let first = sessionWindow.first else { return }
        let last = sessionWindow.last?.t ?? first.t
        activeJournalSaveInFlight = true
        activeJournalPendingSave = false
        let sessionSnapshot = Array(sessionWindow)
        let rrArchiveSnapshot = Array(
            Self.prunedJournalRRSamples(from: rrArchive,
                                        now: now,
                                        first: first.t,
                                        last: last,
                                        maxAge: activeJournalMaxAge,
                                        maxSamples: activeJournalMaxSamples)
        )
        let liveSessionID = liveSessionID
        let label = captureLabel.isEmpty ? "Long wear" : captureLabel
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
        let powerMode = powerThermalGovernor.mode.rawValue
        let cadenceMultiplier = powerThermalGovernor.cadenceMultiplier
        let previousJournalSampleCount = lastActiveJournalSavedSessionSampleCount
        let previousJournalRRCount = lastActiveJournalSavedRRArchiveCount
        DispatchQueue.global(qos: .utility).async {
            let record = ActiveSessionJournalRecord(
                schema: ActiveSessionJournal.schema,
                id: liveSessionID,
                label: label,
                startedAt: first.t,
                updatedAt: now,
                samples: sessionSnapshot.map { ActiveSessionJournalRecord.Sample(t: $0.t, bpm: $0.bpm) },
                rrSamples: rrArchiveSnapshot.map { ActiveSessionJournalRecord.RRSample(t: $0.t, ms: Int($0.ms.rounded())) },
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
                cadenceMultiplier: cadenceMultiplier
            )
            let duration = last.timeIntervalSince(first.t)
            do {
                try ActiveSessionJournal.save(
                    record,
                    previousSampleCount: previousJournalSampleCount,
                    previousRRCount: previousJournalRRCount
                )
                DispatchQueue.main.async {
                    self.activeJournalSaveInFlight = false
                    self.activeJournalDirtySamples = 0
                    self.lastActiveJournalSaveAt = now
                    self.lastActiveJournalSavedSessionSampleCount = sessionSnapshot.count
                    self.lastActiveJournalSavedRRArchiveCount = rrArchiveSnapshot.count
                    AtriaDebugLog("ATRIADBG active_session_journal status=saved reason=%@ samples=%d rr_values=%d duration_s=%.0f dirty=0 label=%@",
                          reason, record.samples.count, record.rrSamples?.count ?? 0, duration, record.label)
                    if self.activeJournalPendingSave {
                        self.activeJournalPendingSave = false
                        self.activeJournalDirtySamples = max(self.activeJournalDirtySamples, flushSampleInterval)
                        self.persistActiveSessionJournalIfNeeded(reason: "pending_flush", force: false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.activeJournalSaveInFlight = false
                    self.activeJournalDirtySamples = max(self.activeJournalDirtySamples, flushSampleInterval)
                    AtriaDebugLog("ATRIADBG active_session_journal status=save_failed reason=%@ samples=%d error=%@",
                          reason, sessionSnapshot.count, error.localizedDescription)
                    if self.activeJournalPendingSave {
                        self.activeJournalPendingSave = false
                        self.persistActiveSessionJournalIfNeeded(reason: "pending_retry", force: false)
                    }
                }
            }
        }
    }

    private func configuredLongWearCheckpointInterval() -> TimeInterval {
        let configured = UserDefaults.standard.object(forKey: LongWearDefaults.checkpointInterval) as? Double ?? 60
        return max(10, min(configured, 3_600))
    }

    private func currentEventDrivenCheckpointInterval() -> TimeInterval {
        max(minimumEventDrivenCheckpointInterval, configuredLongWearCheckpointInterval())
            * powerThermalGovernor.cadenceMultiplier
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

    func flushLifecycleRealtimeState(reason: String) {
        flushSampleDiagnostics()
        flushActiveSessionJournal(reason: reason)
        AtriaDebugLog("ATRIADBG lifecycle_realtime_flush status=ok reason=%@ raw=%d accepted=%d",
                      reason,
                      sampleDiagnostics.rawNotifications,
                      sampleDiagnostics.acceptedSamples)
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

    private func requestFreshScanReconnect(peripheral target: CBPeripheral, reason: String) {
        pendingRecoveryReconnectReason = reason
        if freshScanFallbackTask != nil {
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_coalesced reason=%@ pending_reason=%@ attempt=%d action=wait_existing_backoff",
                  reason,
                  pendingRecoveryReconnectReason ?? "unknown",
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
            self.pendingRecoveryReconnectReason = nil
            self.freshScanFallbackTask = nil
            guard self.status != .connecting else {
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
                // Universal backstop: the link is STILL up (a watchdog fired on a
                // transient data gap, not a real drop). Never cancel a healthy
                // connection or show Disconnected — re-discover services to restart
                // the data pipeline and heal the displayed status. A genuinely dead
                // radio link is detected by iOS supervision -> didDisconnectPeripheral.
                self.peripheral = target
                if self.status != .connected { self.recomputeConnectionStatus(reason: "event") }
                target.discoverServices(Self.UUIDs.discoveryServices)
                self.resetRecoveryReconnectBackoff(reason: "\(scheduledReason)_live_link")
                AtriaDebugLog("ATRIADBG ble_link status=reconnect_skipped reason=%@ action=reassert_live_link",
                      scheduledReason)
                return
            }
            self.forceFreshScanAfterDisconnect = true
            self.central.cancelPeripheralConnection(target)
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
        return base * jitter * powerThermalGovernor.cadenceMultiplier
    }

    private func resetRecoveryReconnectBackoff(reason: String) {
        guard recoveryReconnectAttempt > 0 || pendingRecoveryReconnectReason != nil else { return }
        recoveryReconnectAttempt = 0
        pendingRecoveryReconnectReason = nil
        AtriaDebugLog("ATRIADBG ble_link status=reconnect_backoff_reset reason=%@", reason)
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
            updatePhoneMotionAuditState(reason: "full_protocol_launch_arg")
            applyStandardHROnly(enabled: false, persist: true, reconnect: true, reason: "full_protocol_launch_arg")
            AtriaDebugLog("ATRIADBG full_protocol_mode request=launch_arg action=disable_long_wear_and_low_radio")
        } else if arguments.contains("--atria-long-wear-mode") {
            UserDefaults.standard.set(true, forKey: LongWearDefaults.enabled)
            longWearModeEnabled = true
            updateSessionPointCacheMode()
            updatePhoneMotionAuditState(reason: "long_wear_launch_arg")
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
            storeProprietaryFrames = true
            storeProprietaryFramesMode = true
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
            AtriaDebugLog("ATRIADBG standard_hr_only enabled=1 realtime_start=skipped custom_notify=skipped history_ack=disabled")
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
        longWearSupervisorTask?.cancel()
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
            var lastCheckpointAt = Date()
            var lastDiagnosticAt = Date()
            var lastAutoSaveAt = Date()
            var lastThermalAnalysisDeferralLogAt: Date?
            var lastThermalCheckpointDeferralLogAt: Date?
            var lastHRContinuityActionAt: Date?
            var lastRRPresenceActionAt: Date?
            while !Task.isCancelled {
                let governedTick = config.baseTickInterval * powerThermalGovernor.cadenceMultiplier
                try? await Task.sleep(for: .seconds(governedTick))
                if Task.isCancelled { break }
                guard longWearModeEnabled, standardHROnlyMode else { continue }
                guard status == .connected else { continue }
                let now = Date()
                let cadenceMultiplier = powerThermalGovernor.cadenceMultiplier

                if now.timeIntervalSince(lastCheckpointAt) >= config.checkpointInterval * cadenceMultiplier {
                    if powerThermalGovernor.shouldSuspendNonEssentialWork {
                        persistActiveSessionJournalIfNeeded(reason: "thermal_critical_minimal_checkpoint", force: true)
                        if lastThermalCheckpointDeferralLogAt.map({ now.timeIntervalSince($0) >= 300 }) ?? true {
                            lastThermalCheckpointDeferralLogAt = now
                            AtriaDebugLog("ATRIADBG long_wear_supervisor thermal_checkpoint_deferral status=minimal_journal_only mode=%@ multiplier=%.1f samples=%d label=%@",
                                  powerThermalGovernor.mode.rawValue,
                                  cadenceMultiplier,
                                  session.count,
                                  config.label)
                        }
                    } else {
                        runLongWearSupervisorCheckpoint(index: checkpointIndex, label: config.label)
                    }
                    checkpointIndex += 1
                    lastCheckpointAt = now
                }

                let deferSessionAnalysis = powerThermalGovernor.shouldDeferNonEssentialAnalysis
                if deferSessionAnalysis,
                   (lastThermalAnalysisDeferralLogAt.map { now.timeIntervalSince($0) >= 300 } ?? true) {
                    lastThermalAnalysisDeferralLogAt = now
                    AtriaDebugLog("ATRIADBG long_wear_supervisor thermal_analysis_deferral status=deferred mode=%@ multiplier=%.1f low_power=%d thermal=%@ samples=%d label=%@",
                          powerThermalGovernor.mode.rawValue,
                          cadenceMultiplier,
                          ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0,
                          Self.thermalStateLabel(ProcessInfo.processInfo.thermalState),
                          session.count,
                          config.label)
                }

                if !deferSessionAnalysis,
                   now.timeIntervalSince(lastDiagnosticAt) >= config.diagnosticInterval * cadenceMultiplier {
                    runLongWearSupervisorDiagnostic(index: diagnosticIndex,
                                                    label: config.label,
                                                    rest: config.rest,
                                                    maxHR: config.maxHR)
                    diagnosticIndex += 1
                    lastDiagnosticAt = now
                }

                if !deferSessionAnalysis,
                   now.timeIntervalSince(lastAutoSaveAt) >= config.autoSaveInterval * cadenceMultiplier {
                    if runLongWearSupervisorAutoSave(index: autoSaveIndex,
                                                     label: config.label,
                                                     rest: config.rest,
                                                     maxHR: config.maxHR) {
                        break
                    }
                    autoSaveIndex += 1
                    lastAutoSaveAt = now
                }

                // Anchor the no-data gap to ANY GATT activity (battery included),
                // not just the HR stream — battery reads recur on a live link, so
                // the gap only grows when the link is genuinely silent everywhere.
                if let reference = lastRawHRNotificationAt ?? lastGattActivityAt ?? connectedAt {
                    let gap = now.timeIntervalSince(reference)
                    if gap >= config.noDataTimeout {
                        recoverNoDataWatchdog(label: config.label,
                                               status: "stale",
                                               gap: gap,
                                               timeout: config.noDataTimeout)
                    }
                }

                if let reference = lastRawHRNotificationAt ?? lastAcceptedHRAt ?? connectedAt {
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

                if let reference = lastAcceptedHRAt ?? connectedAt {
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
                guard lastRRPresenceActionAt.map({ now.timeIntervalSince($0) >= config.rrPresenceTimeout * cadenceMultiplier }) ?? true else {
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

    private func runLongWearSupervisorCheckpoint(index: Int, label: String) {
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

    private func runLongWearSupervisorDiagnostic(index: Int, label: String, rest: Int, maxHR: Int) {
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        guard session.count >= autoSaveMinSamples else {
            AtriaDebugLog("ATRIADBG live_workout status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
            return
        }
        guard let saved = snapshotSession(label: label) else {
            AtriaDebugLog("ATRIADBG live_workout status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, rest, maxHR, threshold, index, label)
            return
        }
        persistActiveSessionJournalIfNeeded(reason: "live_workout_diagnostic_supervisor", force: true)
        let readiness = saved.workoutReadiness(rest: rest, maxHR: maxHR)
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

    private func runLongWearSupervisorAutoSave(index: Int, label: String, rest: Int, maxHR: Int) -> Bool {
        let threshold = SavedSession.workoutElevatedThreshold(rest: rest, maxHR: maxHR)
        guard session.count >= autoSaveMinSamples else {
            AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=insufficient_samples samples=%d min_samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, autoSaveMinSamples, rest, maxHR, threshold, index, label)
            return false
        }
        guard let snapshot = snapshotSession(label: label) else {
            AtriaDebugLog("ATRIADBG workout_auto_save status=learning reason=snapshot_failed samples=%d rest_hr=%d max_hr=%d threshold_hr=%d tick=%d label=%@ source=long_wear_supervisor",
                  session.count, rest, maxHR, threshold, index, label)
            return false
        }
        persistActiveSessionJournalIfNeeded(reason: "workout_auto_save_check_supervisor", force: true)
        let readiness = snapshot.workoutReadiness(rest: rest, maxHR: maxHR)
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
        let savedReadiness = saved.workoutReadiness(rest: rest, maxHR: maxHR)
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
                guard let reference = lastRawHRNotificationAt ?? lastGattActivityAt ?? connectedAt else { continue }
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
            recoverNoDataWatchdog(label: captureLabel.isEmpty ? "Long wear" : captureLabel,
                                   status: "forced",
                                   gap: gap,
                                   timeout: 0)
        }
    }

    private func recoverNoDataWatchdog(label: String,
                                       status recoveryStatus: String,
                                       gap: TimeInterval,
                                       timeout: TimeInterval) {
        if historyOnlyProbeMode {
            AtriaDebugLog("ATRIADBG no_data_watchdog status=%@ gap_s=%.1f timeout_s=%.1f samples=%d checkpoint=skipped action=suppressed_history_only_probe",
                  recoveryStatus,
                  gap,
                  timeout,
                  session.count)
            return
        }
        let snapshot = snapshotSession(label: label)
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
        preserveLongWearRangeLossRecovery(reason: "no_data_watchdog")
        guard let peripheral else { return }
        // Never tear down a still-connected link. A no-data gap while the
        // peripheral is CB-connected is recovered by re-subscribing / re-
        // discovering — mirror the accepted_hr/hr_continuity escape hatch. iOS's
        // own connection supervision (didDisconnectPeripheral) is the only thing
        // that should declare a real drop; the watchdog must not cancel a live
        // peripheral or show "Disconnected" while it is connected.
        if peripheral.state == .connected {
            if status != .connected { recomputeConnectionStatus(reason: "event") }
            if let ch = heartRateCharacteristic, ch.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: ch)
            } else {
                peripheral.discoverServices(Self.UUIDs.discoveryServices)
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
                guard let reference = lastRawHRNotificationAt ?? lastAcceptedHRAt ?? connectedAt else { continue }
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
                                              label: captureLabel.isEmpty ? "Long wear" : captureLabel)
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
                                              label: captureLabel.isEmpty ? "Long wear" : captureLabel)
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
        AtriaDebugLog("ATRIADBG rr_presence_watchdog debug_force_schedule delay_s=%.1f", seconds)
        debugRRPresenceWatchdogTask = Task { @MainActor in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            guard !Task.isCancelled else { return }
            let deadline = Date().addingTimeInterval(20)
            while !Task.isCancelled,
                  (peripheral == nil || status != .connected),
                  Date() < deadline {
                try? await Task.sleep(for: .seconds(1))
            }
            guard !Task.isCancelled else { return }
            recoverRRPresenceWatchdog(label: captureLabel.isEmpty ? "Long wear" : captureLabel,
                                      status: "segment_hr_only",
                                      rrGap: 12,
                                      acceptedGap: 0,
                                      timeout: 12,
                                      consecutive: 1)
        }
    }

    private func performHRContinuityWatchdogAction(status actionStatus: String,
                                                   rawGap: TimeInterval,
                                                   acceptedGap: TimeInterval?,
                                                   timeout: TimeInterval,
                                                   label: String) {
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
            peripheral.setNotifyValue(true, for: characteristic)
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
                if let lastActionAt, now.timeIntervalSince(lastActionAt) < timeout {
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
        if canNotify {
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
        let label = captureLabel.isEmpty ? "Long wear" : captureLabel
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
                guard let reference = lastAcceptedHRAt ?? connectedAt else { continue }
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
            recoverAcceptedHRWatchdog(label: captureLabel.isEmpty ? "Long wear" : captureLabel,
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
        if historyOnlyProbeMode {
            AtriaDebugLog("ATRIADBG accepted_hr_watchdog status=%@ accepted_gap_s=%.1f raw_gap_s=%@ timeout_s=%.1f samples=%d checkpoint=skipped action=suppressed_history_only_probe",
                  recoveryStatus,
                  acceptedGap,
                  rawGap.map { String(format: "%.1f", $0) } ?? "missing",
                  timeout,
                  session.count)
            return
        }
        let snapshot = snapshotSession(label: label)
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
               characteristic.properties.contains(.notify) {
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
            AtriaDebugLog("ATRIADBG session_auto_save status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 phone_motion_source=%@ phone_motion_validated=%d phone_motion_wrist_validated=0 phone_motion_samples=%d phone_motion_mean_delta_g=%@ phone_motion_max_delta_g=%@ phone_motion_over_still_threshold=%d phone_motion_still_threshold_g=%.3f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@",
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
                  saved.phoneMotionSourceValue,
                  saved.phoneMotionValidatedValue ? 1 : 0,
                  saved.phoneMotionSamplesValue,
                  Self.formatDouble(saved.phoneMotionMeanDeltaG),
                  Self.formatDouble(saved.phoneMotionMaxDeltaG),
                  saved.phoneMotionOverStillThresholdValue,
                  saved.phoneMotionStillThresholdG ?? phoneMotionStillThresholdG,
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
                AtriaDebugLog("ATRIADBG session_auto_save status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 phone_motion_source=%@ phone_motion_validated=%d phone_motion_wrist_validated=0 phone_motion_samples=%d phone_motion_mean_delta_g=%@ phone_motion_max_delta_g=%@ phone_motion_over_still_threshold=%d phone_motion_still_threshold_g=%.3f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ interval_index=%d mode=periodic",
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
                      saved.phoneMotionSourceValue,
                      saved.phoneMotionValidatedValue ? 1 : 0,
                      saved.phoneMotionSamplesValue,
                      Self.formatDouble(saved.phoneMotionMeanDeltaG),
                      Self.formatDouble(saved.phoneMotionMaxDeltaG),
                      saved.phoneMotionOverStillThresholdValue,
                      saved.phoneMotionStillThresholdG ?? phoneMotionStillThresholdG,
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
                AtriaDebugLog("ATRIADBG session_checkpoint status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 phone_motion_source=%@ phone_motion_validated=%d phone_motion_wrist_validated=0 phone_motion_samples=%d phone_motion_mean_delta_g=%@ phone_motion_max_delta_g=%@ phone_motion_over_still_threshold=%d phone_motion_still_threshold_g=%.3f hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ checkpoint_index=%d mode=upsert source=%@",
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
                      saved.phoneMotionSourceValue,
                      saved.phoneMotionValidatedValue ? 1 : 0,
                      saved.phoneMotionSamplesValue,
                      Self.formatDouble(saved.phoneMotionMeanDeltaG),
                      Self.formatDouble(saved.phoneMotionMaxDeltaG),
                      saved.phoneMotionOverStillThresholdValue,
                      saved.phoneMotionStillThresholdG ?? phoneMotionStillThresholdG,
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
            AtriaDebugLog("ATRIADBG manual_checkpoint status=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d motion_short_count=%d motion_short_mean=%@ motion_short_min=%@ motion_short_max=%@ motion_short_over_1=%d motion_short_validated=0 phone_motion_source=%@ phone_motion_validated=%d phone_motion_wrist_validated=0 phone_motion_samples=%d phone_motion_mean_delta_g=%@ phone_motion_max_delta_g=%@ phone_motion_over_still_threshold=%d phone_motion_still_threshold_g=%.3f hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d resting_hr=%d hrv=%@ label=%@ mode=upsert source=launch_arg reset_live_session=0",
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
                  saved.phoneMotionSourceValue,
                  saved.phoneMotionValidatedValue ? 1 : 0,
                  saved.phoneMotionSamplesValue,
                  Self.formatDouble(saved.phoneMotionMeanDeltaG),
                  Self.formatDouble(saved.phoneMotionMaxDeltaG),
                  saved.phoneMotionOverStillThresholdValue,
                  saved.phoneMotionStillThresholdG ?? phoneMotionStillThresholdG,
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
        if let p = peripheral { central.cancelPeripheralConnection(p) }
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
            saved.discoverServices(Self.UUIDs.discoveryServices)
            AtriaDebugLog("ATRIADBG ble_link status=reconnect_known reason=%@ action=already_connected", reason)
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
            central.cancelPeripheralConnection(peripheral)
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
                self.central.connect(peripheral, options: nil)
                AtriaDebugLog("ATRIADBG ble_link watchdog reason=%@ action=keep_pending_connect_saved_strap", reason)
                return
            }
            self.recordLinkFailure(reason: "\(reason)_watchdog", error: nil)
            self.preserveLongWearRangeLossRecovery(reason: "\(reason)_watchdog")
            self.realtimeArmed = false
            self.txCharacteristic = nil
            self.dbgTxReady = false
            self.peripheral = nil
            central.cancelPeripheralConnection(peripheral)
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
                seedRecordingFromArchive(now: captureStart)
            }
            captureTimer?.invalidate()
            captureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let now = Date()
                    self.captureElapsedSeconds = now.timeIntervalSince(self.captureStart)
                    let cleanElapsed = now.timeIntervalSince(self.captureCleanWindowStart)
                    if self.refreshHRVSnapshot(now: now, logKind: "hrv_timer", shouldLogConsole: false)?.isReady == true,
                       self.autoStopCaptureWhenReady,
                       !self.autoStoppedReadyCapture {
                        self.autoStoppedReadyCapture = true
                        AtriaDebugLog("ATRIADBG autoCapture stop reason=ready_timer")
                        self.finishRecording(stopReason: "ready_timer")
                        return
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

    private func seedRecordingFromArchive(now: Date) {
        let seed = rrArchive
            .filter { now.timeIntervalSince($0.t) <= 305 }
            .sorted { $0.t < $1.t }
        guard !seed.isEmpty else { return }
        rrBuffer = seed
        rrBufferHead = 0
        rrSamples = seed.count
        hrvGateWasOpen = true
        if let last = seed.last {
            lastRRBeatTime = last.t
            lastRRExportElapsedMS = Int((last.t.timeIntervalSince(captureStart) * 1000).rounded())
        }
        logRow(kind: "hrv_quality", source: "app", opcode: "", len: "",
               value: String(format: "seeded_from_archive rr=%d window_s=%.0f",
                             seed.count, now.timeIntervalSince(seed.first?.t ?? now)))
        for rr in seed {
            logRow(kind: "rr_seed", source: "archive", opcode: "RR", len: "",
                   value: String(format: "%.0f", rr.ms), at: rr.t)
        }
        _ = refreshHRVSnapshot(now: now, logKind: "hrv_seed", shouldLogConsole: true)
    }

    @discardableResult
    private func refreshHRVSnapshot(now: Date,
                                    logKind: String,
                                    shouldLogConsole: Bool) -> HRVSnapshot? {
        hrvLiveRefreshGeneration &+= 1
        hrvLiveRefreshTask?.cancel()
        hrvLiveRefreshTask = nil
        lastHRVRefreshAt = now
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
        lastHRVRefreshAt = now
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
        guard let saved = snapshotSession(label: captureLabel.isEmpty ? "RR checkpoint" : captureLabel) else {
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=%@ samples=%d rr_samples=%d source=rr_quality",
                  reason, session.count, rrArchive.count)
            return
        }
        let checkpointPersisted = onSessionCheckpoint?(saved) == true
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ reason=%@ samples=%d rr_samples=%d motion_hints=%d motion_hint_kinds=%@ motion_source=%@ motion_validated=%d phone_motion_source=%@ phone_motion_validated=%d phone_motion_wrist_validated=0 phone_motion_samples=%d phone_motion_mean_delta_g=%@ phone_motion_max_delta_g=%@ phone_motion_over_still_threshold=%d phone_motion_still_threshold_g=%.3f hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f hrv=%@ label=%@ source=rr_quality",
              checkpointPersisted ? "saved" : "store_failed",
              reason,
              saved.points.count,
              saved.rrSampleCount,
              saved.motionHintCountValue,
              saved.motionHintKindsValue,
              saved.motionEvidenceSourceValue,
              saved.motionEvidenceValidatedValue ? 1 : 0,
              saved.phoneMotionSourceValue,
              saved.phoneMotionValidatedValue ? 1 : 0,
              saved.phoneMotionSamplesValue,
              Self.formatDouble(saved.phoneMotionMeanDeltaG),
              Self.formatDouble(saved.phoneMotionMaxDeltaG),
              saved.phoneMotionOverStillThresholdValue,
              saved.phoneMotionStillThresholdG ?? phoneMotionStillThresholdG,
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
        guard !foregroundInteractiveMode else { return }
        guard session.count >= autoSaveMinSamples else { return }
        let checkpointInterval = currentEventDrivenCheckpointInterval()
        if let lastEventDrivenCheckpointAt,
           now.timeIntervalSince(lastEventDrivenCheckpointAt) < checkpointInterval {
            return
        }
        if lastEventDrivenCheckpointAt == nil,
           now.timeIntervalSince(sessionStart) < checkpointInterval {
            return
        }
        if powerThermalGovernor.shouldSuspendNonEssentialWork {
            lastEventDrivenCheckpointAt = now
            persistActiveSessionJournalIfNeeded(reason: "thermal_critical_ble_event_checkpoint", force: true)
            AtriaDebugLog("ATRIADBG session_checkpoint status=deferred reason=thermal_critical_minimal_journal samples=%d rr_samples=%d source=ble_event mode=%@ interval_s=%.0f",
                  session.count,
                  rrArchive.count,
                  powerThermalGovernor.mode.rawValue,
                  checkpointInterval)
            return
        }
        let label = captureLabel.isEmpty ? "Unattended workout checkpoint" : captureLabel
        guard let saved = snapshotSession(label: label) else {
            AtriaDebugLog("ATRIADBG session_checkpoint status=skipped reason=event_snapshot_failed samples=%d rr_samples=%d source=ble_event",
                  session.count, rrArchive.count)
            return
        }

        lastEventDrivenCheckpointAt = now
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
        AtriaDebugLog("ATRIADBG session_checkpoint status=%@ samples=%d rr_samples=%d hr_raw_2a37=%d hr_accepted=%d hr_zero=%d hr_artifact_held=%d hr_artifact_dropped=%d hr_raw_gaps=%d hr_accepted_gaps=%d hr_max_raw_gap_s=%.1f hr_max_accepted_gap_s=%.1f duration_s=%.0f avg_hr=%d peak_hr=%d hrv=%@ label=%@ mode=upsert source=ble_event app_state=%@ interval_s=%.0f",
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
            return
        }

        var minRate = Int.max
        var maxRate = Int.min
        var total = 0
        for sample in session {
            minRate = min(minRate, sample.bpm)
            maxRate = max(maxRate, sample.bpm)
            total += sample.bpm
        }
        sessionMinHeartRate = minRate == Int.max ? nil : minRate
        sessionMaxHeartRate = maxRate == Int.min ? nil : maxRate
        sessionHeartRateTotal = total
    }

    private func recordSessionHeartRateStats(rate: Int) {
        sessionMinHeartRate = min(sessionMinHeartRate ?? rate, rate)
        sessionMaxHeartRate = max(sessionMaxHeartRate ?? rate, rate)
        sessionHeartRateTotal += rate
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
        sampleDiagnostics.acceptedSamples += 1
        let acceptedCount = sampleDiagnostics.acceptedSamples
        if let lastAcceptedHRAt {
            let gap = sampleTime.timeIntervalSince(lastAcceptedHRAt)
            if gap > SavedSession.workoutContinuityGapLimit {
                sessionAcceptedHRGaps += 1
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
            }
        }
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
            sampleDiagnostics.zeroSamples += 1
            setSampleDiagnosticsStatus("zero_contact", reason: "hr_zero")
            assignIfChanged(\.hasContact, false)
            contactStableSince = nil
            pendingHRJump = nil
            recentValid.removeAll(keepingCapacity: true)
            resetHRVWindow(reason: "contact lost")
            logRow(kind: "hr", source: "0x2A37", opcode: "", len: "", value: "0", at: sampleTime)
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
        // the first sample after a long BLE/contact gap.
        if let med = median(recentValid), recentValid.count >= 3, abs(rate - med) > Self.workoutHRArtifactJumpBPM {
            let gap = lastAcceptedHRAt.map { sampleTime.timeIntervalSince($0) } ?? 0
            let pendingAge = pendingHRJump.map { sampleTime.timeIntervalSince($0.at) }
            let decision = Self.hrArtifactJumpDecision(rate: rate,
                                                       median: med,
                                                       pendingRate: pendingHRJump?.rate,
                                                       pendingAge: pendingAge,
                                                       acceptedGap: gap)
            if decision.reason == "stale_median_after_gap" {
                pendingHRJump = nil
                AtriaDebugLog("ATRIADBG hr_artifact action=accept reason=stale_median_after_gap rate=%d median=%d gap_s=%.1f", rate, med, gap)
                acceptHeartRate(rate, at: sampleTime)
                return
            }
            if decision.reason == "confirmed_jump", let pending = pendingHRJump {
                pendingHRJump = nil
                AtriaDebugLog("ATRIADBG hr_artifact action=accept reason=confirmed_jump previous=%d rate=%d median=%d gap_s=%.1f", pending.rate, rate, med, gap)
                acceptHeartRate(pending.rate, at: pending.at)
                acceptHeartRate(rate, at: sampleTime)
                return
            }
            pendingHRJump = (rate, sampleTime)
            sessionHeldArtifacts += 1
            sampleDiagnostics.heldArtifacts += 1
            setSampleDiagnosticsStatus("artifact_hold", reason: "unconfirmed_jump")
            AtriaDebugLog("ATRIADBG hr_artifact action=hold reason=unconfirmed_jump rate=%d median=%d gap_s=%.1f", rate, med, gap)
            logRow(kind: "hr_artifact", source: "0x2A37", opcode: "", len: "", value: "\(rate)", at: sampleTime)
            return
        }

        if let pending = pendingHRJump {
            sessionDroppedArtifacts += 1
            sampleDiagnostics.droppedArtifacts += 1
            setSampleDiagnosticsStatus("artifact_drop", reason: "not_confirmed")
            AtriaDebugLog("ATRIADBG hr_artifact action=drop reason=not_confirmed previous=%d rate=%d", pending.rate, rate)
            pendingHRJump = nil
        }
        acceptHeartRate(rate, at: sampleTime)
    }

    private func acceptHeartRate(_ rate: Int, at sampleTime: Date) {
        let shouldForceFirstJournalSave = longWearModeEnabled && session.isEmpty
        recordAcceptedHRSample(rate: rate, at: sampleTime)
        recentValid.append(rate)
        if recentValid.count > 5 { recentValid.removeFirst() }
        appendLastHeartRate(rate)
        let displayRate = median(recentValid) ?? rate
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
        if acceptedHeartRateBatchDepth > 0 {
            acceptedHeartRateBatchPendingConsistencyAt = sampleTime
        } else {
            compareHRChannelsIfPossible(now: sampleTime, source: "2A37")
        }
        session.append(HRSample(t: sampleTime, bpm: rate))
        sessionSampleCount = session.count
        appendSessionPoint(rate: rate, at: sampleTime)
        recordSessionHeartRateStats(rate: rate)
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
        let governedMinimumInterval = minimumInterval * powerThermalGovernor.cadenceMultiplier
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

    private static func hrArtifactJumpDecision(rate: Int,
                                               median: Int,
                                               pendingRate: Int?,
                                               pendingAge: TimeInterval?,
                                               acceptedGap: TimeInterval) -> (action: String, reason: String) {
        if acceptedGap > workoutHRArtifactStaleMedianSeconds {
            return ("accept", "stale_median_after_gap")
        }
        if let pendingRate,
           let pendingAge,
           pendingAge <= workoutHRArtifactConfirmSeconds,
           abs(rate - pendingRate) <= workoutHRArtifactConfirmBPM,
           (rate - median).signum() == (pendingRate - median).signum() {
            return ("accept", "confirmed_jump")
        }
        return ("hold", "unconfirmed_jump")
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
        rollActiveSessionAfterLongGapIfNeeded(nextSampleTime: frameTime, reason: "standard_hr_gap")
        recordRawHRNotification(hr: measurement.hr, at: frameTime)
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
        recoverRRPresenceWatchdog(label: captureLabel.isEmpty ? "Long wear" : captureLabel,
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
        let timeout: TimeInterval = 6
        let rrGap = now.timeIntervalSince(lastStandardRRAt)
        guard rrGap >= timeout else { return }
        let acceptedGap = now.timeIntervalSince(lastAcceptedHRAt)
        guard acceptedGap <= 5 else { return }
        if let lastCurrentRRGapRecoveryAt,
           now.timeIntervalSince(lastCurrentRRGapRecoveryAt) < timeout {
            return
        }
        currentRRGapRecoveryCount += 1
        lastCurrentRRGapRecoveryAt = now
        recoverRRPresenceWatchdog(label: captureLabel.isEmpty ? "Long wear" : captureLabel,
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
        resetRRBuffer()
        rrSamples = 0
        hrv = 0
        lastHRVRefreshAt = nil
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
        guard !force, let lastHRVRefreshAt else { return true }
        let minimumInterval = foregroundInteractiveMode || isRecording
            ? liveHRVRefreshMinimumInterval
            : Self.backgroundLiveHRVRefreshMinimumInterval
        return now.timeIntervalSince(lastHRVRefreshAt) >= minimumInterval * powerThermalGovernor.cadenceMultiplier
    }

    private var shouldMaintainLiveTachogram: Bool {
        foregroundInteractiveMode && isRecording
    }

    // MARK: Command channel + HRV

    private var realtimeRetry: Task<Void, Never>?
    private var realtimeRestartTask: Task<Void, Never>?
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

    /// Send a COMMAND packet on CMD_TO_STRAP: [0x23, seq, cmd, data...].
    private func sendCommand(_ cmd: UInt8, _ data: [UInt8], mode: CommandWriteMode) {
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

    private var realtimeArmed = false

    /// Arm realtime ONCE the data characteristic (61080005) subscription is
    /// confirmed active. Sends STOP→START so the strap makes a fresh "on"
    /// transition while we're definitely subscribed (matches the macOS probe,
    /// which subscribed, settled, then sent START once).
    func armRealtime() {
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
        realtimeRetry = Task { @MainActor in
            // Wait for the TX characteristic (up to ~5s), then settle briefly so
            // the subscription is fully live (the macOS probe waited before sending).
            for _ in 0..<25 where txCharacteristic == nil { try? await Task.sleep(for: .milliseconds(200)) }
            guard txCharacteristic != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            // Byte-exact replica of the validated macOS command: START, enable=1,
            // as the FIRST command so seq=0 (frame aa0800a82300030199bce9cf).
            sendCommand(Cmd.toggleRealtimeHR, [0x01], mode: .withoutResponse)
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
                if realtimeStreamIsAlive {
                    AtriaDebugLog("ATRIADBG realtimeRetry status=stopped reason=stream_alive standard_hr_frames=%d realtime_frames=%d standard_rr=%d realtime_rr=%d",
                          standardHRFrames, dbgRealtimeFrames, decodedStandardRRValues, decodedRealtimeRRValues)
                    break
                }
                AtriaDebugLog("ATRIADBG realtimeRetry status=send_start reason=no_stream standard_hr_frames=%d realtime_frames=%d standard_rr=%d realtime_rr=%d",
                      standardHRFrames, dbgRealtimeFrames, decodedStandardRRValues, decodedRealtimeRRValues)
                sendCommand(Cmd.toggleRealtimeHR, [0x01], mode: .withoutResponse)
            }
        }
    }

    private var realtimeStreamIsAlive: Bool {
        standardHRFrames > 0 || dbgRealtimeFrames > 0 || decodedStandardRRValues > 0 || decodedRealtimeRRValues > 0
    }

    /// Historical fallback probe: keep live HRV off and ask the strap for its
    /// stored-session range. This keeps history transfer from poisoning a live
    /// RR capture and leaves all historical RR interpretations provisional.
    private func armHistoryOnlyProbe() {
        guard !historyOnlyProbeArmed else { return }
        historyOnlyProbeArmed = true
        realtimeOn = false
        realtimeRetry?.cancel()
        realtimeRestartTask?.cancel()
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
            if now.timeIntervalSince(lastRRContinuityPublishAt) < minimumInterval * powerThermalGovernor.cadenceMultiplier {
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
    private func handleProprietary(_ data: Data) {
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
            handleUnknownProtocolPayload(payload, fullFrame: b)
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

    private func handleUnknownProtocolPayload(_ payload: [UInt8], fullFrame: [UInt8]) {
        guard let type = payload.first else { return }
        let body = Array(payload.dropFirst())
        recordProtocolPacket(type: type, length: payload.count)
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

    private func recordProtocolPacket(type: UInt8, length: Int) {
        protocolPacketCount += 1
        protocolLastPacketType = String(format: "%02x", type)
        protocolLastPacketKind = Self.packetKind(type)
        protocolLastPacketLength = length
        if type == Packet.imu {
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
            AtriaDebugLog("ATRIADBG imu_candidate validated=%d validation_state=%@ len=%d offset=%d endian=%@ scale=%.0f sample_rate_hz=%@ samples=%d mean_g=%@ stillness_ratio=%@ movement_intensity=%@ bursts=%d strap_steps_research=%d phone_step_agreement=%@ metric_promotions=0 i16=%@ magnitudes=%@ payload=%@",
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
                  Self.formatDouble(AtriaStrapStepResearch.agreement(strapSteps: strapStepResearchCount,
                                                                     phoneSteps: phoneStepCount > 0 ? phoneStepCount : nil)),
                  i16Pairs.joined(separator: ","),
                  magnitudes.joined(separator: ","),
                  Self.hex(payload))
        }
    }

    private func recordResearchProbeCandidate(payload: [UInt8], source: AtriaResearchProbe.Source) {
        guard supportsSpO2Probe || supportsSkinTempProbe else { return }
        let summary = AtriaResearchProbe.analyze(payload: payload, source: source)
        applyModelMetadataIfExplicit(summary)
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
        guard let mapped, mapped != strapModel else { return }
        strapModel = mapped
        AtriaDebugLog("ATRIADBG model_gate status=metadata_explicit model=%@ evidence=%@ source=%@",
              mapped.rawValue,
              summary.modelEvidence.isEmpty ? "none" : summary.modelEvidence,
              summary.source.rawValue)
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
        if cmd == 0x02, body.count >= 14 {
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
            ackedHistoryAckKeys.insert(ackKey)
            let ack: [UInt8]
            let writeMode: CommandWriteMode
            if historyAckMode == "enddata" {
                ack = [0x01] + endData
                writeMode = .withResponse
            } else {
                ack = [0x01] + Self.le32(ackCursor) + [0x00, 0x00, 0x00, 0x00]
                writeMode = .withoutResponse
            }
            AtriaDebugLog("ATRIADBG historyAck mode=%@ key=%@ trim=%u cursor=%u end_data=%@ payload=%@ write_mode=%@",
                  historyAckMode, ackKey, trim, ackCursor, Self.hex(endData), Self.hex(ack), writeMode.rawValue)
            historicalArchiveRowsSinceAck = 0
            sendCommand(Cmd.historicalDataResult, ack, mode: writeMode)
        } else {
            AtriaDebugLog("ATRIADBG historyMeta seq=%d cmd=%02x kind=%@%@ u32=%@ u16=%@ payload=%@",
                  Int(seq), cmd, kind, fields, metadataU32, metadataU16, Self.hex(payload))
        }
    }

    private func handleHistoricalData(_ payload: [UInt8]) {
        recordResearchProbeCandidate(payload: payload, source: .historical)
        let clock = historyClockRef
        let historyClockSyncEnabled = historyClockSyncEnabled
        historicalArchiveQueue.async { [weak self] in
            let computation = Self.prepareHistoricalArchiveComputation(payload: payload,
                                                                       clock: clock,
                                                                       historyClockSyncEnabled: historyClockSyncEnabled)
            AtriaDebugLog("%@", computation.logMessage)
            let persistence = Self.persistHistoricalArchiveComputation(computation)
            Task { @MainActor [weak self] in
                self?.applyHistoricalArchivePersistenceResult(persistence)
            }
        }
    }

    private func applyHistoricalArchivePersistenceResult(_ result: HistoricalArchivePersistenceResult) {
        if result.succeeded {
            historicalArchiveRows += 1
            historicalArchiveRowsSinceAck += 1
            lastHistoricalArchivePath = HistoricalArchive.relativePath
            if result.archivedUndecodable {
                AtriaDebugLog("ATRIADBG historicalArchive status=archived_undecodable reason=%@ rows=%d rows_since_ack=%d failures=%d path=%@",
                      result.reason ?? "unknown",
                      historicalArchiveRows,
                      historicalArchiveRowsSinceAck,
                      historicalArchiveWriteFailures,
                      result.persistedPath)
            } else if historicalArchiveRows == 1 || historicalArchiveRows.isMultiple(of: 500) {
                AtriaDebugLog("ATRIADBG historicalArchive status=ok rows=%d rows_since_ack=%d failures=%d layout=%@ metric_usable=0 current_session_usable=%d path=%@",
                      historicalArchiveRows,
                      historicalArchiveRowsSinceAck,
                      historicalArchiveWriteFailures,
                      HistoricalArchive.layoutVersion,
                      result.currentSessionUsable ? 1 : 0,
                      result.persistedPath)
            }
            return
        }

        historicalArchiveWriteFailures += 1
        AtriaDebugLog("ATRIADBG historicalArchive status=error rows=%d rows_since_ack=%d failures=%d error=%@ action=skip_future_history_ack path=%@",
              historicalArchiveRows,
              historicalArchiveRowsSinceAck,
              historicalArchiveWriteFailures,
              result.errorDescription ?? "unknown",
              HistoricalArchive.relativePath)
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
        let usabilityReason = currentSessionUsable
            ? "current_session_replay_ready_metric_reference_pending"
            : "provisional_historical_layout_old_or_unvalidated"
        let payloadHex = Self.hex(payload)
        let logMessage = String(
            format: "ATRIADBG historicalData provisional=1 validated=0 seq=%02x cmd=%02x unix7=%u subsec11=%u flash13=%u len=%d strap4_v24_hr17=%d strap4_v24_rrnum18=%d strap4_v24_rr19=%@ k_rr64=%@ noop_gravity_mag=%@ noop_gravity_validated=%d clock_status=%@ clock_device_ref=%@ clock_wall_ref=%@ clock_drift_s=%@ clock_snapped_drift_s=%@ clock_corrected_unix7=%@ candidate_rr=%@ payload=%@",
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
                                              metricUsable: false,
                                              usabilityReason: usabilityReason)
        return HistoricalArchiveComputation(logMessage: logMessage, payload: .record(record))
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
                                                          reason: reason,
                                                          persistedPath: Self.documentsRelativePath(for: url),
                                                          errorDescription: nil)
            case .undecodable(let payload, let persistReason):
                url = try HistoricalArchive.appendUndecodable(payload: payload, reason: persistReason)
                archivedUndecodable = true
                reason = persistReason
                return HistoricalArchivePersistenceResult(succeeded: true,
                                                          archivedUndecodable: archivedUndecodable,
                                                          currentSessionUsable: false,
                                                          reason: reason,
                                                          persistedPath: Self.documentsRelativePath(for: url),
                                                          errorDescription: nil)
            }
        } catch {
            return HistoricalArchivePersistenceResult(succeeded: false,
                                                      archivedUndecodable: false,
                                                      currentSessionUsable: false,
                                                      reason: nil,
                                                      persistedPath: HistoricalArchive.relativePath,
                                                      errorDescription: String(describing: error).replacingOccurrences(of: " ", with: "_"))
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
    func checkpointCurrentSession(label: String, reason: String) -> Bool {
        guard let saved = snapshotSession(label: label) else {
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
        guard longWearModeEnabled, !session.isEmpty else { return }
        let previous = [lastRawHRNotificationAt, lastAcceptedHRAt, session.last?.t].compactMap { $0 }.max()
        guard let previous else { return }
        let gap = nextSampleTime.timeIntervalSince(previous)
        guard gap >= activeJournalSegmentGapLimit else { return }

        let label = captureLabel.isEmpty ? "Long wear" : captureLabel
        guard let saved = snapshotSession(label: label) else {
            resetLiveSessionState(start: nextSampleTime)
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
        AtriaDebugLog("ATRIADBG active_session_rollover status=%@ reason=%@ gap_s=%.1f threshold_s=%.1f saved_samples=%d saved_duration_s=%.0f action=%@",
              persisted ? "saved" : "store_failed",
              reason,
              gap,
              activeJournalSegmentGapLimit,
              saved.points.count,
              saved.duration,
              persisted ? "start_new_segment" : "retain_existing_segment")
    }

    private func resetLiveSessionState(start: Date) {
        session.removeAll(keepingCapacity: true)
        sessionSampleCount = 0
        sessionOriginTime = nil
        sessionPointsCache.removeAll(keepingCapacity: true)
        rrPointsCache.removeAll(keepingCapacity: true)
        sessionMinHeartRate = nil
        sessionMaxHeartRate = nil
        sessionHeartRateTotal = 0
        replaceLastHeartRates([])
        rrArchive.removeAll(keepingCapacity: true)
        recentRRBeatTimes.removeAll(keepingCapacity: true)
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
        resetSessionMotionDiagnostics()
        startPhoneStepEvidenceIfNeeded(start: start, reason: "live_session_reset")
        resetSessionSampleDiagnostics()
        sessionStart = start
        lastAcceptedHRAt = nil
        lastRawHRNotificationAt = nil
        lastStandardHR = nil
        pendingHRJump = nil
        recentValid.removeAll(keepingCapacity: true)
        liveSessionID = UUID()
        activeJournalDirtySamples = 0
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
        logClockCommandResponse([UInt8](frame.payload))
        logDataRangeCommandResponse([UInt8](frame.payload))
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
        while true {
            let batch = dequeuePendingRealtimePacketBatch(limit: Self.realtimePacketBatchSize)
            if batch.isEmpty {
                if finishRealtimePacketDrainIfIdle() {
                    return
                }
                continue
            }
            await applyRealtimePacketBatch(batch)
            await Task.yield()
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
        while true {
            let batch = dequeuePendingHeartRateUpdateBatch(limit: Self.heartRatePacketBatchSize)
            if batch.isEmpty {
                if finishHeartRatePacketDrainIfIdle() {
                    return
                }
                continue
            }
            await applyPendingHeartRateUpdates(batch)
            await Task.yield()
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
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
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
        let label = captureLabel.isEmpty ? "Long wear" : captureLabel
        let duration = max(0, (session.last?.t ?? sessionStart).timeIntervalSince(sessionStart))
        activeJournalDirtySamples = 0
        lastActiveJournalSavedSessionSampleCount = 0
        lastActiveJournalSavedRRArchiveCount = 0
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

    /// Snapshot the current HR session into a persistable record without
    /// resetting it, so unattended long runs survive debugger/device drops.
    func snapshotSession(label: String) -> SavedSession? {
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
        let phoneMotion = phoneMotionAuditSummary()
        let phoneSteps = phoneStepEvidenceSummary()
        let imu = imuFeatureSummary()
        let averageHR = session.map(\.bpm).reduce(0, +) / max(session.count, 1)
        let sleepWake = AtriaSleepWakeResearch.classify(duration: last.t.timeIntervalSince(start),
                                                        averageHR: averageHR,
                                                        restingHR: restingHR ?? min(averageHR, session.map(\.bpm).min() ?? averageHR),
                                                        imuStillnessRatio: imu.stillnessRatio,
                                                        imuMovementIntensity: imu.movementIntensity,
                                                        strapSteps: strapStepResearchCount > 0 ? strapStepResearchCount : nil)
        let respiratoryRate = sleepWake.state == "sleep_research" && hrvSnapshot?.isReady == true
            ? hrvSnapshot?.respiratoryRate
            : nil
        let profile = AthleteProfile.load()
        let activeCalories = Metrics.activeCalories(session,
                                                    rest: restingHR ?? min(averageHR, session.map(\.bpm).min() ?? averageHR),
                                                    profile: profile)
        let caloriesConfidence: String? = session.count > 1 ? (profile.hasEnergyProfile ? "estimate" : "needs_profile") : nil
        return SavedSession(id: liveSessionID, start: start, end: last.t,
                            label: label.trimmingCharacters(in: .whitespaces), points: points,
                            hrv: hrv > 0 ? hrv : nil,
                            respiratoryRate: respiratoryRate,
                            rrPoints: rrPoints.isEmpty ? nil : rrPoints,
                            hrvReferenceValidated: false,
                            motionHintCount: sleepMotionHintCount,
                            motionHintKinds: sleepMotionHintKinds,
                            motionEvidenceSource: sleepMotionSource,
                            motionEvidenceValidated: false,
                            motionShortCount: motionShortStats.count > 0 ? motionShortStats.count : nil,
                            motionShortMean: motionShortStats.mean,
                            motionShortMin: motionShortStats.min,
                            motionShortMax: motionShortStats.max,
                            motionShortOverOneCount: motionShortStats.count > 0 ? motionShortStats.overOne : nil,
                            imuSampleCount: decodedIMUSampleCount > 0 ? decodedIMUSampleCount : nil,
                            imuFrameCount: protocolIMUFrameCount > 0 ? protocolIMUFrameCount : nil,
                            imuSampleRateHz: imu.sampleRateHz,
                            imuScale: imuInferredScale,
                            imuEndian: imuInferredEndian,
                            imuStillnessRatio: imu.stillnessRatio,
                            imuMovementIntensity: imu.movementIntensity,
                            imuActivityBursts: decodedIMUSampleCount > 0 ? imuActivityBurstCount : nil,
                            imuValidationState: decodedIMUSampleCount > 0 ? imuValidationState : nil,
                            strapStepResearchCount: strapStepResearchCount > 0 ? strapStepResearchCount : nil,
                            strapStepResearchAgreement: AtriaStrapStepResearch.agreement(strapSteps: strapStepResearchCount,
                                                                                         phoneSteps: phoneSteps.steps > 0 ? phoneSteps.steps : nil),
                            strapStepResearchState: strapStepResearchCount > 0 ? strapStepResearchState : nil,
                            sleepWakeResearchState: sleepWake.state == "learning" ? nil : sleepWake.state,
                            sleepWakeResearchConfidence: sleepWake.confidence == "none" ? nil : sleepWake.confidence,
                            sleepWakeResearchReason: sleepWake.reason,
                            sensorResearchProbeFrames: researchProbeFrameCount > 0 ? researchProbeFrameCount : nil,
                            spo2ResearchCandidateFrames: researchProbeOxygenCandidateFrames > 0 ? researchProbeOxygenCandidateFrames : nil,
                            skinTempResearchCandidateFrames: researchProbeTemperatureCandidateFrames > 0 ? researchProbeTemperatureCandidateFrames : nil,
                            skinTempResearchCandidateValueSum: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueSum : nil,
                            skinTempResearchCandidateValueCount: researchProbeTemperatureCandidateValueCount > 0 ? researchProbeTemperatureCandidateValueCount : nil,
                            activeCalories: activeCalories,
                            caloriesConfidence: caloriesConfidence,
                            phoneMotionSource: phoneMotion.source,
                            phoneMotionValidated: phoneMotion.validated,
                            phoneMotionSamples: phoneMotion.samples > 0 ? phoneMotion.samples : nil,
                            phoneMotionMeanDeltaG: phoneMotion.meanDelta,
                            phoneMotionMaxDeltaG: phoneMotion.maxDelta,
                            phoneMotionOverStillThreshold: phoneMotion.samples > 0 ? phoneMotion.overThreshold : nil,
                            phoneMotionStillThresholdG: phoneMotion.threshold,
                            phoneStepSource: phoneSteps.source,
                            phoneStepValidated: phoneSteps.validated,
                            phoneStepCount: phoneSteps.steps > 0 ? phoneSteps.steps : nil,
                            phoneStepDistanceMeters: phoneSteps.distanceMeters,
                            phoneStepFloorsAscended: phoneSteps.floorsAscended,
                            phoneStepFloorsDescended: phoneSteps.floorsDescended,
                            hrRaw2A37: sessionRawHRNotifications,
                            hrAccepted: sessionAcceptedHRSamples,
                            hrZero: sessionZeroHRSamples,
                            hrArtifactHeld: sessionHeldArtifacts,
                            hrArtifactDropped: sessionDroppedArtifacts,
                            hrRawGaps: sessionRawHRGaps,
                            hrAcceptedGaps: sessionAcceptedHRGaps,
                            hrMaxRawGap: sessionMaxRawHRGap,
                            hrMaxAcceptedGap: sessionMaxAcceptedHRGap)
    }

    private func resetSessionMotionDiagnostics() {
        sleepMotionHintCount = 0
        sleepMotionHintKinds = "none"
        sleepMotionHintKindCounts.removeAll(keepingCapacity: true)
        sleepMotionShortValues.removeAll(keepingCapacity: true)
        sleepMotionSource = "unavailable"
        resetIMUFeatureStats()
        resetPhoneMotionAuditStats()
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
        let stepEstimate = AtriaStrapStepResearch.estimate(samples: decoded.samples,
                                                           sampleRateHz: imuFeatureSummary().sampleRateHz)
        strapStepResearchCount += stepEstimate.steps
        strapStepResearchPeakCount += stepEstimate.peaks
        strapStepResearchState = stepEstimate.state
        imuStillnessRatioSum += decoded.stillnessRatio
        imuMovementIntensitySum += decoded.movementIntensity
        imuActivityBurstCount += decoded.activityBursts
        if decoded.gravityValidated {
            imuGravityValidatedFrameCount += 1
        }
        imuValidationState = imuGravityValidatedFrameCount > 0 ? "gravity_validated_research" : "research_unvalidated"
    }

    private func imuFeatureSummary() -> (stillnessRatio: Double?, movementIntensity: Double?, sampleRateHz: Double?) {
        guard protocolIMUFrameCount > 0, decodedIMUSampleCount > 0 else { return (nil, nil, nil) }
        let frames = Double(max(protocolIMUFrameCount, 1))
        let sampleRate = imuSampleRateHzCount > 0 ? imuSampleRateHzSum / Double(imuSampleRateHzCount) : nil
        return (imuStillnessRatioSum / frames, imuMovementIntensitySum / frames, sampleRate)
    }

    private func resetIMUFeatureStats() {
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
        strapStepResearchCount = 0
        strapStepResearchPeakCount = 0
        strapStepResearchState = "research_unvalidated"
        researchProbeFrameCount = 0
        researchProbeOxygenCandidateFrames = 0
        researchProbeTemperatureCandidateFrames = 0
        researchProbeTemperatureCandidateValueSum = 0
        researchProbeTemperatureCandidateValueCount = 0
    }

    private func startPhoneMotionAudit() {
        guard !phoneMotionManager.isAccelerometerActive else { return }
        guard phoneMotionManager.isAccelerometerAvailable else {
            AtriaDebugLog("ATRIADBG phone_motion status=unavailable reason=accelerometer_unavailable source=phone_coremotion validated=0 wrist_motion_validated=0")
            return
        }
        phoneMotionManager.accelerometerUpdateInterval = 1.0
        phoneMotionStartedAt = Date()
        phoneMotionManager.startAccelerometerUpdates(to: .main) { [weak self] data, error in
            guard let self else { return }
            if let error {
                AtriaDebugLog("ATRIADBG phone_motion status=error reason=%@ source=phone_coremotion validated=0 wrist_motion_validated=0", String(describing: error))
                self.phoneMotionManager.stopAccelerometerUpdates()
                return
            }
            guard let acceleration = data?.acceleration else { return }
            self.recordPhoneMotionSample(x: acceleration.x, y: acceleration.y, z: acceleration.z)
        }
        AtriaDebugLog("ATRIADBG phone_motion status=started source=phone_coremotion interval_s=1.0 still_threshold_g=%.3f validated=0 wrist_motion_validated=0 action=corroborate_debug_rig_only",
              phoneMotionStillThresholdG)
    }

    private func stopPhoneMotionAudit(reason: String) {
        guard phoneMotionManager.isAccelerometerActive else { return }
        phoneMotionManager.stopAccelerometerUpdates()
        AtriaDebugLog("ATRIADBG phone_motion status=stopped reason=%@ source=phone_coremotion", reason)
    }

    private func updatePhoneMotionAuditState(reason: String) {
        let arguments = ProcessInfo.processInfo.arguments
        let needsAudit = arguments.contains("--atria-active-motion-imu-check")
        if needsAudit {
            startPhoneMotionAudit()
        } else {
            stopPhoneMotionAudit(reason: reason)
        }
    }

    private func recordPhoneMotionSample(x: Double, y: Double, z: Double) {
        if let previous = phoneMotionLastVector {
            let dx = x - previous.x
            let dy = y - previous.y
            let dz = z - previous.z
            let delta = sqrt(dx * dx + dy * dy + dz * dz)
            phoneMotionSamples += 1
            phoneMotionDeltaSum += delta
            phoneMotionDeltaMax = max(phoneMotionDeltaMax, delta)
            if delta > phoneMotionStillThresholdG {
                phoneMotionOverStillThreshold += 1
            }
            if phoneMotionSamples - phoneMotionLastLoggedSample >= 15 {
                phoneMotionLastLoggedSample = phoneMotionSamples
                AtriaDebugLog("ATRIADBG phone_motion status=sampled source=phone_coremotion_audit_only samples=%d mean_delta_g=%@ max_delta_g=%@ over_still_threshold=%d still_threshold_g=%.3f validated=0 wrist_motion_validated=0 action=corroborate_debug_rig_only",
                      phoneMotionSamples,
                      Self.formatDouble(phoneMotionDeltaSum / Double(phoneMotionSamples)),
                      Self.formatDouble(phoneMotionDeltaMax),
                      phoneMotionOverStillThreshold,
                      phoneMotionStillThresholdG)
            }
        }
        phoneMotionLastVector = (x, y, z)
    }

    private func resetPhoneMotionAuditStats() {
        phoneMotionDeltaSum = 0
        phoneMotionDeltaMax = 0
        phoneMotionSamples = 0
        phoneMotionOverStillThreshold = 0
        phoneMotionLastVector = nil
        phoneMotionStartedAt = Date()
        phoneMotionLastLoggedSample = 0
    }

    private func phoneMotionAuditSummary() -> (source: String, validated: Bool, samples: Int, meanDelta: Double?, maxDelta: Double?, overThreshold: Int, threshold: Double) {
        guard phoneMotionManager.isAccelerometerAvailable else {
            return ("unavailable", false, 0, nil, nil, 0, phoneMotionStillThresholdG)
        }
        let mean = phoneMotionSamples > 0 ? phoneMotionDeltaSum / Double(phoneMotionSamples) : nil
        let maxDelta = phoneMotionSamples > 0 ? phoneMotionDeltaMax : nil
        return ("phone_coremotion_audit_only", false, phoneMotionSamples, mean, maxDelta, phoneMotionOverStillThreshold, phoneMotionStillThresholdG)
    }

    private func startPhoneStepEvidenceIfNeeded(start: Date, reason: String) {
        guard CMPedometer.isStepCountingAvailable() else {
            resetPhoneStepEvidenceStats(start: start)
            AtriaDebugLog("ATRIADBG phone_steps status=unavailable reason=step_counting_unavailable source=phone_coremotion_pedometer validated=0 action=activity_adjunct_only")
            return
        }
        guard !phoneStepEvidenceActive else { return }
        resetPhoneStepEvidenceStats(start: start)
        phoneStepEvidenceActive = true
        phonePedometer.startUpdates(from: start) { [weak self] data, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.phoneStepEvidenceActive = false
                    self.phonePedometer.stopUpdates()
                    AtriaDebugLog("ATRIADBG phone_steps status=error reason=%@ source=phone_coremotion_pedometer validated=0 action=activity_adjunct_only", String(describing: error))
                    return
                }
                guard let data else { return }
                self.recordPhoneStepEvidence(data)
            }
        }
        AtriaDebugLog("ATRIADBG phone_steps status=started reason=%@ source=phone_coremotion_pedometer validated=0 action=activity_adjunct_only",
                      reason)
    }

    private func stopPhoneStepEvidence(reason: String) {
        guard phoneStepEvidenceActive else { return }
        phonePedometer.stopUpdates()
        phoneStepEvidenceActive = false
        AtriaDebugLog("ATRIADBG phone_steps status=stopped reason=%@ source=phone_coremotion_pedometer steps=%d distance_m=%@ validated=0 action=activity_adjunct_only",
                      reason,
                      phoneStepCount,
                      Self.formatDouble(phoneStepDistanceMeters))
    }

    private func recordPhoneStepEvidence(_ data: CMPedometerData) {
        phoneStepCount = data.numberOfSteps.intValue
        phoneStepDistanceMeters = data.distance?.doubleValue
        phoneStepFloorsAscended = data.floorsAscended?.intValue
        phoneStepFloorsDescended = data.floorsDescended?.intValue
        recordPhoneStepsToday(data)
        if phoneStepCount - phoneStepLastLoggedCount >= 100 {
            phoneStepLastLoggedCount = phoneStepCount
            AtriaDebugLog("ATRIADBG phone_steps status=sampled source=phone_coremotion_pedometer steps=%d distance_m=%@ floors_up=%d floors_down=%d validated=0 action=activity_adjunct_only",
                          phoneStepCount,
                          Self.formatDouble(phoneStepDistanceMeters),
                          phoneStepFloorsAscended ?? 0,
                          phoneStepFloorsDescended ?? 0)
        }
    }

    private func recordPhoneStepsToday(_ data: CMPedometerData) {
        phoneStepsToday = data.numberOfSteps.intValue
        phoneDistanceTodayMeters = data.distance?.doubleValue
        let up = data.floorsAscended?.intValue ?? 0
        let down = data.floorsDescended?.intValue ?? 0
        phoneFloorsToday = (up + down) > 0 ? up + down : nil
    }

    private func resetPhoneStepEvidenceStats(start: Date) {
        phoneStepStartedAt = start
        phoneStepCount = 0
        phoneStepDistanceMeters = nil
        phoneStepFloorsAscended = nil
        phoneStepFloorsDescended = nil
        phoneStepLastLoggedCount = 0
    }

    private func phoneStepEvidenceSummary() -> (source: String, validated: Bool, steps: Int, distanceMeters: Double?, floorsAscended: Int?, floorsDescended: Int?) {
        guard CMPedometer.isStepCountingAvailable() else {
            return ("unavailable", false, 0, nil, nil, nil)
        }
        return ("phone_coremotion_pedometer", false, phoneStepCount, phoneStepDistanceMeters, phoneStepFloorsAscended, phoneStepFloorsDescended)
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
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                assignIfChanged(\.bluetoothPermissionDenied, false)
                let reason = pendingScanReason ?? "central_powered_on"
                pendingScanReason = nil
                if let peripheral, peripheral.state == .connected {
                    peripheral.discoverServices(Self.UUIDs.discoveryServices)
                } else if reconnectToSavedPeripheralIfPossible(reason: "powered_on_\(reason)") {
                    // Re-armed a standing pending connection to the known strap.
                    // No scan needed — iOS reconnects when it is in range.
                } else {
                    // No saved strap yet (first-time setup) — scan to find one.
                    startScan(reason: reason)
                }
                self.recomputeConnectionStatus(reason: "central_powered_on")
            case .poweredOff:
                assignIfChanged(\.bluetoothPermissionDenied, false)
                preserveLongWearRangeLossRecovery(reason: "central_powered_off")
                self.isActivelyScanning = false
                self.recomputeConnectionStatus(reason: "central_powered_off")
            case .unauthorized:
                assignIfChanged(\.bluetoothPermissionDenied, true)
                preserveLongWearRangeLossRecovery(reason: "central_unauthorized")
                self.isActivelyScanning = false
                self.recomputeConnectionStatus(reason: "central_unauthorized")
            default:
                assignIfChanged(\.bluetoothPermissionDenied, false)
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
                self.clearPendingKnownReconnect(reason: "state_restore_connected")
                self.recomputeConnectionStatus(reason: "event")
                self.reconnectWatchdogTask?.cancel()
                self.connectedAt = Date()
                self.recordLinkObservedConnected(reason: "state_restore_connected", peripheral: restoredPeripheral)
                self.scheduleRangeLossBackfillIfNeeded(reason: "state_restore_connected")
                restoredPeripheral.discoverServices(Self.UUIDs.discoveryServices)
                AtriaDebugLog("ATRIADBG ble_restore status=connected name=%@", self.deviceName)
            case .connecting:
                self.recomputeConnectionStatus(reason: "event")
                self.markPendingKnownReconnect(reason: "state_restore_connecting")
                self.startReconnectWatchdog(reason: "state_restore_connecting", peripheral: restoredPeripheral)
                AtriaDebugLog("ATRIADBG ble_restore status=connecting name=%@", self.deviceName)
            default:
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
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        Task { @MainActor in
            reconnectWatchdogTask?.cancel()
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            isActivelyScanning = false
            recomputeConnectionStatus(reason: "did_connect")
            // Keep very fresh charge evidence visible while the immediate 2A19/2A1B
            // reads arrive. Older links still start level-only so we do not imply a
            // stale charger state is current.
            let cachedBattery = Self.cachedBattery(maxAge: 10 * 60)
            if cachedBattery.usable, cachedBattery.chargeStatus != .levelOnly {
                assignIfChanged(\.batteryLevel, cachedBattery.level)
                assignIfChanged(\.batteryIsCharging, cachedBattery.chargeStatus == .charging)
                assignIfChanged(\.batteryChargeStatus, cachedBattery.chargeStatus)
            } else {
                assignIfChanged(\.batteryIsCharging, false)
                assignIfChanged(\.batteryChargeStatus, .levelOnly)
            }
            connectedAt = Date()
            dbgMTU = mtu
            recordLinkConnected(peripheral: peripheral)
            peripheral.discoverServices(Self.UUIDs.discoveryServices)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            recomputeConnectionStatus(reason: "event")
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            realtimeArmed = false        // re-arm realtime after reconnect
            let defaults = UserDefaults.standard
            let disconnects = defaults.integer(forKey: LinkDefaults.disconnects) + 1
            let errorText = error?.localizedDescription ?? "nil"
            defaults.set(disconnects, forKey: LinkDefaults.disconnects)
            defaults.set("disconnected", forKey: LinkDefaults.lastStatus)
            defaults.set("did_disconnect", forKey: LinkDefaults.lastReason)
            defaults.set(errorText, forKey: LinkDefaults.lastError)
            let connectedDuration = connectedAt.map { Date().timeIntervalSince($0) } ?? 0
            let useFreshScan = forceFreshScanAfterDisconnect
            let reconnectPolicy = useFreshScan ? "fresh_scan" : "reconnect_same_peripheral"
            forceFreshScanAfterDisconnect = false
            let wasUserRequestedDisconnect = userRequestedDisconnect
            let atriaOwnedOfflineSyncDisconnect = offlineHistoricalSyncInProgress || historyOnlyProbeEnabled || historyOnlyProbeMode
            if atriaOwnedOfflineSyncDisconnect {
                AtriaDebugLog("ATRIADBG official_app_coexistence status=ignored reason=atria_owned_offline_sync_disconnect action=keep_current_risk")
            } else if !wasUserRequestedDisconnect && connectedDuration > 0 && connectedDuration < 90 {
                persistOfficialAppCoexistenceRisk(.suspected, reason: "short_disconnect_after_connect")
            }
            let shouldPreserveLongWearSession = longWearModeEnabled && !wasUserRequestedDisconnect
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
                preserveLongWearRangeLossRecovery(reason: "disconnect")
                autoSaveStatus = session.isEmpty ? "skipped_continuity_empty" : "checkpointed_continuity"
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
        Task { @MainActor in
            reconnectWatchdogTask?.cancel()
            freshScanFallbackTask?.cancel()
            freshScanFallbackTask = nil
            recordLinkFailure(reason: "did_fail_to_connect", error: error)
            connectedAt = nil
            if self.peripheral === peripheral {
                self.peripheral = nil
            }
            self.realtimeArmed = false
            self.txCharacteristic = nil
            self.heartRateCharacteristic = nil
            self.lastMissingHeartRateDiscoveryAt = nil
            self.dbgTxReady = false
            self.recomputeConnectionStatus(reason: "event")
            self.startScan(reason: "did_fail_to_connect_recovery")
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
            guard let characteristics = Self.discoveryCharacteristics(for: service.uuid) else { continue }
            if service.uuid == Self.UUIDs.strapService {
                Task { @MainActor in
                    if self.strapModel == .unknown {
                        self.strapModel = .strap4Class
                        AtriaDebugLog("ATRIADBG model_gate status=assume_4_class reason=proprietary_service service=%@", service.uuid.uuidString)
                    }
                }
            }
            peripheral.discoverCharacteristics(characteristics, for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        var foundTX: CBCharacteristic?
        var foundHeartRateCharacteristic: CBCharacteristic?
        var radioCounters: [(key: String, reason: String)] = []
        var skippedCustomNotify = false
        var usedStandardHROnly = false
        var requestedCustomNotifyCount = 0
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case UUIDs.heartRateMeasure, UUIDs.batteryLevel, UUIDs.batteryLevelStatus:
                if ch.properties.contains(.notify) || ch.properties.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: ch)
                }
                if ch.uuid == UUIDs.batteryLevel || ch.uuid == UUIDs.batteryLevelStatus {
                    peripheral.readValue(for: ch)
                }
                if ch.uuid == UUIDs.heartRateMeasure {
                    foundHeartRateCharacteristic = ch
                }
            case UUIDs.manufacturerName, UUIDs.modelNumber,
                 UUIDs.firmwareRevision, UUIDs.hardwareRevision:
                peripheral.readValue(for: ch)
            case UUIDs.strapTX:
                if standardHROnlyMode, !historyOnlyProbeMode {
                    usedStandardHROnly = true
                    radioCounters.append((RadioDefaults.txSkipped, "standard_hr_only"))
                } else {
                    foundTX = ch
                }
            default:
                if standardHROnlyMode, !historyOnlyProbeMode, UUIDs.allNotify.contains(ch.uuid) {
                    if ch.isNotifying {
                        peripheral.setNotifyValue(false, for: ch)
                    }
                    skippedCustomNotify = true
                    radioCounters.append((RadioDefaults.customNotifySkipped, "standard_hr_only"))
                } else if UUIDs.allNotify.contains(ch.uuid),
                   ch.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: ch)
                    requestedCustomNotifyCount += 1
                    radioCounters.append((RadioDefaults.customNotifyEnabled, "full_protocol"))
                }
            }
        }
        // Set the command characteristic and request realtime HR + RR intervals
        // (the HRV source) in ONE task, so tx is assigned before we send. Verified
        // command: [0x23, seq, 0x03, 0x01] → CMD_RESP ack → REALTIME_DATA stream.
        if foundTX != nil || foundHeartRateCharacteristic != nil || !radioCounters.isEmpty || requestedCustomNotifyCount > 0 || skippedCustomNotify || usedStandardHROnly {
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
                for counter in radioCounters {
                    self.incrementRadioCounter(counter.key, reason: counter.reason)
                }
                if let tx = foundTX {
                    self.txCharacteristic = tx
                    self.dbgTxReady = true
                }
            }
        } else if let tx = foundTX {
            Task { @MainActor in
                self.txCharacteristic = tx
                self.dbgTxReady = true
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let msg = error.map { "ERR:\($0.localizedDescription.prefix(18))" } ?? "ok"
        AtriaDebugLog("ATRIADBG writeResult to=%@ -> %@", characteristic.uuid.uuidString, msg)
        Task { @MainActor in self.dbgWrite = msg }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let short = String(characteristic.uuid.uuidString.prefix(8))
        let notifying = characteristic.isNotifying
        let err = error?.localizedDescription
        let isData = characteristic.uuid == UUIDs.strapStream5
        AtriaDebugLog("ATRIADBG notifyState ch=%@ notifying=%d err=%@", characteristic.uuid.uuidString, notifying ? 1 : 0, error?.localizedDescription ?? "nil")
        Task { @MainActor in
            if let err { self.dbgLast = "suberr \(short):\(err.prefix(14))" }
            else if notifying {
                self.dbgSubsActive += 1
                if isData { self.armRealtime() }     // data char ready → start realtime
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        if uuid == UUIDs.heartRateMeasure {
            enqueueHeartRateUpdate(PendingHeartRateUpdate(packet: Self.parseHeartRatePacket(data), rawData: data))
            return
        }
        if uuid == UUIDs.batteryLevel {
            let newLevel = Int(data.first ?? 0)
            Task { @MainActor in
                // A GATT value from a CB-connected peripheral proves the link is
                // live. Record the activity and heal a status that a watchdog or a
                // transient central blip wrongly left non-connected (after state
                // restoration no didConnect fires, so HR is the only other healer
                // and it can't fire during a low-radio HR silence).
                self.lastGattActivityAt = Date()
                if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                    self.recomputeConnectionStatus(reason: "event")
                }
                // Infer charging from the in-session battery trend. WHOOP exposes
                // 2A19 level only, not a direct charge flag, so the first/flat read
                // remains "level only". A rise is charging evidence; a drop is
                // not-charging evidence. 100% is surfaced as full.
                let previous = batteryLevel
                if previous >= 0 {
                    let delta = newLevel - previous
                    if newLevel >= 100 {
                        assignIfChanged(\.batteryIsCharging, false)
                        assignIfChanged(\.batteryChargeStatus, .full)
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    } else if delta > 0 && delta <= 5 {
                        assignIfChanged(\.batteryIsCharging, true)
                        assignIfChanged(\.batteryChargeStatus, .charging)
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    } else if delta < 0 {
                        assignIfChanged(\.batteryIsCharging, false)
                        assignIfChanged(\.batteryChargeStatus, .notCharging)
                        assignIfChanged(\.batteryRecentlyDropping, true)
                    }
                } else if newLevel >= 100 {
                    assignIfChanged(\.batteryChargeStatus, .full)
                    assignIfChanged(\.batteryRecentlyDropping, false)
                    clearBatteryDropMarker()
                }
                assignIfChanged(\.batteryLevel, newLevel)
                persistBatteryLevel(batteryLevel, source: "live_2A19", chargeStatus: batteryChargeStatus)
                AtriaDebugLog("ATRIADBG battery level=%d source=2A19 bytes=%@ persisted=1",
                      batteryLevel,
                      Self.hex([UInt8](data)))
            }
            return
        }
        if uuid == UUIDs.batteryLevelStatus {
            Task { @MainActor in
                self.lastGattActivityAt = Date()
                if central.state == .poweredOn, peripheral.state == .connected, self.status != .connected {
                    self.recomputeConnectionStatus(reason: "event")
                }
                if let parsedStatus = Self.parseBatteryChargeStatus(data) {
                    let status: BatteryChargeStatus = batteryLevel >= 100 && parsedStatus == .charging ? .full : parsedStatus
                    assignIfChanged(\.batteryIsCharging, status == .charging)
                    assignIfChanged(\.batteryChargeStatus, status)
                    if status == .charging || status == .full {
                        assignIfChanged(\.batteryRecentlyDropping, false)
                        clearBatteryDropMarker()
                    }
                    persistBatteryChargeStatus(status, source: "live_2A1B")
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

        let storesProprietaryFrames = storeProprietaryFramesMode
        let frameSource = Self.label(for: uuid)
        let parsedRealtimePacket = storesProprietaryFrames ? nil : Self.parseFastRealtimeProprietaryPacket(data)
        if let parsedRealtimePacket, !storesProprietaryFrames {
            enqueueRealtimePacket(parsedRealtimePacket)
            return
        }
        let parsedProprietaryUpdate = storesProprietaryFrames
            ? nil
            : Self.parseProprietaryUpdate(data, source: frameSource)
        let parsedStoredFrame = storesProprietaryFrames ? AtriaFrame.parse(data, source: frameSource) : nil
        Task { @MainActor in
            dbgPropFrames += 1
            if verboseBLEFrameLogging {
                AtriaDebugLog("ATRIADBG frame ch=%@ len=%d hex=%@",
                      uuid.uuidString.prefix(8).description,
                      data.count,
                      Self.hex([UInt8](data)))
            }
            if uuid == UUIDs.strapStream7 {
                recordResearchProbeCandidate(payload: [UInt8](data), source: .diagnostic)
            }
            // The "type" byte: for aa-framed packets it's payload[0] (index 4);
            // for unframed (identity) it's index 0.
            let typeByte = Self.protocolTypeByte(in: data)
            let sig = "\(uuid.uuidString.prefix(8).suffix(2)):\(String(format: "%02x", typeByte))"
            if !dbgTypeSet.contains(sig) { dbgTypeSet.insert(sig); dbgLast = dbgTypeSet.sorted().joined(separator: " ") }
            if Self.isRealtimeProtocolFrame(data, typeByte: typeByte) {
                dbgRealtimeFrames += 1
            }
            if let parsedProprietaryUpdate {
                if case .realtime = parsedProprietaryUpdate {
                    dbgRealtimeFrames -= 1
                }
                handleParsedProprietaryUpdate(parsedProprietaryUpdate, uuid: uuid)
            } else {
                if storeProprietaryFrames {
                    if let frame = parsedStoredFrame {
                        record(frame: frame)
                    }
                }
                handleProprietary(data)
            }
        }
    }

    private func persistBatteryLevel(_ level: Int, source: String, chargeStatus: BatteryChargeStatus? = nil) {
        guard level >= 0 && level <= 100 else { return }
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
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
        if let chargeStatus {
            defaults.set(chargeStatus.rawValue, forKey: BatteryDefaults.chargeStatus)
            defaults.set(now, forKey: BatteryDefaults.chargeAt)
        }
    }

    private func persistBatteryChargeStatus(_ status: BatteryChargeStatus, source: String) {
        let defaults = UserDefaults.standard
        defaults.set(status.rawValue, forKey: BatteryDefaults.chargeStatus)
        defaults.set(Date().timeIntervalSince1970, forKey: BatteryDefaults.chargeAt)
        if status == .charging || status == .full {
            clearBatteryDropMarker()
        }
        if batteryLevel >= 0 {
            persistBatteryLevel(batteryLevel, source: source, chargeStatus: status)
        }
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
