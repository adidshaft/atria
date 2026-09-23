import Foundation
import CoreBluetooth
import CryptoKit

/// Exclusive diagnostic owner for the compact-IMU investigation.
///
/// When armed, 2A37 collection and durable HR storage continue. Automatic
/// proprietary writers are blocked: 69 banking, 16 catch-up, repeated 6A,
/// workout activation, silent-stream companion repair, zombie CCCD OFF/ON,
/// and mid-link `setNotify` repair. At most one stream-5 CCCD notify-enable
/// is allowed per connection epoch / new CB peripheral connect if the
/// characteristic is not already notifying **and** at least 15 minutes
/// have passed since the last leftover-2B assemble or stream-5-driven
/// `connectionTimeout`. Otherwise the epoch logs `stream5_cooldown_skip`
/// and keeps 2A37. After the cooldown the next new link-up may enable
/// again; restoration and mid-link repair must not rewrite CCCD. Extra
/// 03/04/07 notify is once per process. One later `6A/01` is allowed only
/// after `armSingleEnable()` during the isolated live-enable trial. The
/// documented Gen4 compact sequence `03/01 → 6A/01 → 14/00` is allowed
/// only after `armOfficialGen4Compact()`. All-day recovery `14/00` then
/// `6A/01` is allowed only after `armAllDayAbortThen6A()`. One software
/// strap reset (`0x1D/00`) is allowed only after `armSoftwareReset()`,
/// and 6A/01 then waits for a new connection epoch.
enum AtriaIMUDiagnosticTransport {
    static let quietLeaseArgument = "--atria-imu-quiet-lease"
    static let extraNotifyLinkUpArgument = "--atria-imu-extra-notify-linkup"
    static let liveOtherUUIDSource = "live_other_uuid"
    static let singleEnableArgument = "--atria-imu-single-6a"
    static let officialGen4CompactArgument = "--atria-imu-official-gen4-compact"
    static let allDayRecoveryArgument = "--atria-imu-allday-abort-then-6a"
    /// H2: turn historical IMU off, then one live `6A/01`. Not `03` and not `14`.
    static let releaseHistoricalThen6AArgument = "--atria-imu-69off-then-6a"
    /// Gen5-style revision byte. Gen4 one-byte `6A/01` ACK'd as off on this strap.
    static let rev1IMUArgument = "--atria-imu-6a-rev1"
    /// Harvard identity (`GET_HELLO` opcode `0x23`, payload `00`) then one `6A/01`.
    static let helloThen6AArgument = "--atria-imu-hello-then-6a"
    /// Stop the leftover R10 pipe (`3F/00`) before one compact `6A/01`.
    static let stopR10Then6AArgument = "--atria-imu-stop-r10-then-6a"
    static let softwareResetArgument = "--atria-imu-software-reset"
    static let recordSecondsArgument = "--atria-imu-record-seconds"
    static let enableAfterSecondsArgument = "--atria-imu-enable-after-seconds"
    static let allDayRecoveryAfterSecondsArgument = "--atria-imu-allday-recovery-after-seconds"
    static let resetAfterSecondsArgument = "--atria-imu-reset-after-seconds"
    /// OpenStrap/whoof `REBOOT_STRAP`. Named without `Cmd.reboot` so history
    /// source-inspection tests do not treat diagnostic use as automatic recovery.
    static let softwareResetOpcode: UInt8 = 0x1D
    static let softwareResetPayload: [UInt8] = [0x00]
    static let currentRunPointerFilename = "atria-imu-diagnostic-current-run-v1.json"
    static let defaultRecordDuration: TimeInterval = 30 * 60
    static let stream5CooldownSeconds: TimeInterval = 15 * 60
    static let stream5CooldownSkipReason = "stream5_cooldown_skip"
    /// Full 2A37 hex at ~1 Hz on the BLE callback was enough to trip
    /// `cpu_resource_fatal` (build 254). Stream-5 RX hex stays at full rate.
    static let heartRateSummaryInterval: TimeInterval = 30

    enum NotifyPhase: String, Sendable {
        case heartRate
        case battery
        case initialDiscovery
        case restoration
        case midLinkRepair
        case unspecified
    }

    struct WriteDecision: Equatable, Sendable {
        let allow: Bool
        let reason: String
    }

    struct NotifyDecision: Equatable, Sendable {
        let allow: Bool
        let reason: String
    }

    struct HarvardCommand: Equatable, Sendable {
        let sequence: UInt8
        let opcode: UInt8
        let payload: [UInt8]
    }

    private static let lock = NSLock()
    private static var runID = ""
    private static var processID: Int32 = 0
    private static var buildIdentity = ""
    private static var startedAt: Date?
    private static var monotonicOrigin: TimeInterval = 0
    private static var stopReason = ""
    private static var recordDuration: TimeInterval = defaultRecordDuration
    private static var connectionEpoch: UInt64 = 0
    private static var initialProprietarySubscribeOpen = false
    private static var initialStream5Established = false
    private static var stream5NotifyWriteConsumed = false
    private static var stream5NotifyWritesThisEpoch = 0
    private static var extraNotifyWriteConsumed: Set<String> = []
    private static var extraNotifyLinkUpWrites = 0
    private static var stream5EnabledThisEpoch = false
    private static var leftover2BThisEpoch = false
    private static var stream5CooldownUntilMono: TimeInterval = 0
    private static var stream5CooldownSkipCount = 0
    /// Tests only. Production uses `ProcessInfo.processInfo.systemUptime`.
    static var monotonicNowOverride: TimeInterval?
    private static var setupFailureRecorded = false
    private static var singleEnableArmed = false
    private static var singleEnableConsumed = false
    private static var officialGen4Armed = false
    private static var officialGen4Consumed = false
    private static var officialGen4Step = 0
    private static var allDayRecoveryArmed = false
    private static var allDayRecoveryConsumed = false
        private static var allDayRecoveryStep = 0
    private static var releaseHistoricalArmed = false
    private static var releaseHistoricalConsumed = false
    private static var releaseHistoricalStep = 0
    private static var rev1IMUArmed = false
    private static var rev1IMUConsumed = false
    private static var helloThen6AArmed = false
    private static var helloThen6AConsumed = false
    private static var helloThen6AStep = 0
    private static var stopR10Armed = false
    private static var stopR10Consumed = false
    private static var stopR10Step = 0
    private static var softwareResetRequestedFlag = false
    private static var softwareResetArmed = false
    private static var softwareResetConsumed = false
    private static var softwareResetEpoch: UInt64 = 0
    private static var unexpectedWriteCount = 0
    private static var blockedWriteCount = 0
    private static var allowedWriteCount = 0
    private static var compact33Count = 0
    private static var native34Count = 0
    private static var equalQuality34Count = 0
    private static var liveCompactDeviceTimestamps: [UInt32] = []
    /// Typed `0x33` frames that fail planar decode (not checksum-exception trailers).
    private static var compactCorruptCount = 0
    private static var nativeR10Count = 0
    private static var nativeR11Count = 0
    private static var withheldHistoryCount = 0
    private static var incompleteTailCount = 0
    private static var crcFailCount = 0
    private static var recorderWriteFailures = 0
    private static var durationElapsedLogged = false
    private static var heartRateRxTotalCount = 0
    private static var heartRateRxSinceSummary = 0
    private static var lastHeartRateSummaryMono: TimeInterval = 0
    private static var lastHeartRateSummaryBPM: Int?
    private static let recorderWriteQueue = DispatchQueue(
        label: "com.adidshaft.atria.imu-recorder",
        qos: .utility
    )
    private static var handle: FileHandle?
    private static var documentsOverride: URL?
    private static var cachedRawBytes: UInt64 = 0
    private static var cachedRawSHA = ""
    private static var cachedRawAt: TimeInterval = 0
    /// Tests only. Production always uses `ProcessInfo.processIdentifier`.
    static var processIdentifierOverride: Int32?

    static var documentsDirectoryOverride: URL? {
        get { lock.withLock { documentsOverride } }
        set { lock.withLock { documentsOverride = newValue } }
    }

    /// DVT `process launch` sometimes delivers app flags as one whitespace
    /// string instead of separate argv tokens. Split those so the lease
    /// still arms.
    static func expandedLaunchArguments(_ arguments: [String]) -> [String] {
        var expanded: [String] = []
        for argument in arguments {
            if argument.contains(where: { $0.isWhitespace }),
               argument.contains("--atria-") {
                expanded.append(
                    contentsOf: argument.split(whereSeparator: \.isWhitespace).map(String.init)
                )
            } else {
                expanded.append(argument)
            }
        }
        return expanded
    }

    static func isQuietLeaseActive(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let expanded = expandedLaunchArguments(arguments)
        if expanded.contains(quietLeaseArgument)
            || expanded.contains(singleEnableArgument)
            || expanded.contains(officialGen4CompactArgument)
            || expanded.contains(allDayRecoveryArgument)
            || expanded.contains(releaseHistoricalThen6AArgument)
            || expanded.contains(rev1IMUArgument)
            || expanded.contains(helloThen6AArgument)
            || expanded.contains(stopR10Then6AArgument) {
            return true
        }
        if environment["ATRIA_IMU_QUIET_LEASE"] == "1" {
            return true
        }
        // A SpringBoard/DVT successor process may lose argv. Persisted
        // intent re-arms THIS pid's recorder; it is not proof a stale
        // JSONL is still being written.
        return UserDefaults.standard.bool(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmed
        )
    }

    static func liveProcessIdentifier() -> Int32 {
        processIdentifierOverride ?? ProcessInfo.processInfo.processIdentifier
    }

    /// Connect-time CCCD on notify UUIDs other than stream-5. Not a Harvard
    /// command and not a mid-link stream-5 rewrite.
    static func isExtraNotifyLinkUpActive(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(extraNotifyLinkUpArgument)
    }

    static let extraNotifyUUIDs: [CBUUID] = [
        AtriaBLEManager.UUIDs.strapRX,
        AtriaBLEManager.UUIDs.strapStream4,
        AtriaBLEManager.UUIDs.strapStream7,
    ]

    static func shouldRequestExtraNotifyAtLinkUp(
        uuid: CBUUID,
        alreadyNotifying: Bool,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        guard isExtraNotifyLinkUpActive(arguments: arguments) else { return false }
        guard extraNotifyUUIDs.contains(uuid) else { return false }
        guard !alreadyNotifying else { return false }
        return lock.withLock { !extraNotifyWriteConsumed.contains(uuid.uuidString) }
    }

    static func durableCompactIMUSource(
        characteristic: CBUUID,
        stream5Label: String
    ) -> String {
        characteristic == AtriaBLEManager.UUIDs.strapStream5
            ? stream5Label
            : liveOtherUUIDSource
    }

    /// Standard-HR production connect/reseat must not emit 6A, 3F, or the
    /// all-day historical IMU toggle (0x69). Quiet lease uses the same gate
    /// so a missed argv cannot leave the writers live while the investigation
    /// is running. Explicit workout/calibration ownership may still arm 0x69.
    static func shouldInhibitAutomaticConnectIMUCommands(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardHROnlyMode: Bool
    ) -> Bool {
        isQuietLeaseActive(arguments: arguments, environment: environment)
            || standardHROnlyMode
    }

    static func isDiagnosticLaunchArgument(_ argument: String) -> Bool {
        let tokens = expandedLaunchArguments([argument])
        return tokens.contains { token in
            token == quietLeaseArgument
                || token == extraNotifyLinkUpArgument
                || token == AtriaStrapCalibrationArchive.importArchivedArgument
                || token == AtriaStrapCalibrationArchive.materializeSamplesArgument
                || token == singleEnableArgument
                || token == officialGen4CompactArgument
                || token == allDayRecoveryArgument
                || token == softwareResetArgument
                || token.hasPrefix(recordSecondsArgument)
                || token.hasPrefix(enableAfterSecondsArgument)
                || token.hasPrefix(allDayRecoveryAfterSecondsArgument)
                || token.hasPrefix(resetAfterSecondsArgument)
        }
    }

    static func recordDurationSeconds(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> TimeInterval {
        let arguments = expandedLaunchArguments(arguments)
        for argument in arguments {
            let prefix = recordSecondsArgument + "="
            if argument.hasPrefix(prefix),
               let value = TimeInterval(argument.dropFirst(prefix.count)),
               value > 0 {
                return value
            }
        }
        guard let index = arguments.firstIndex(of: recordSecondsArgument),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]),
              value > 0 else {
            return defaultRecordDuration
        }
        return value
    }

    static func enableAfterSeconds(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> TimeInterval? {
        let arguments = expandedLaunchArguments(arguments)
        for argument in arguments {
            let prefix = enableAfterSecondsArgument + "="
            if argument.hasPrefix(prefix),
               let value = TimeInterval(argument.dropFirst(prefix.count)),
               value > 0 {
                return value
            }
        }
        guard let index = arguments.firstIndex(of: enableAfterSecondsArgument),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]),
              value > 0 else {
            return nil
        }
        return value
    }

    static func resetAfterSeconds(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> TimeInterval? {
        let arguments = expandedLaunchArguments(arguments)
        for argument in arguments {
            let prefix = resetAfterSecondsArgument + "="
            if argument.hasPrefix(prefix),
               let value = TimeInterval(argument.dropFirst(prefix.count)),
               value > 0 {
                return value
            }
        }
        guard let index = arguments.firstIndex(of: resetAfterSecondsArgument),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]),
              value > 0 else {
            return nil
        }
        return value
    }

    static func isSoftwareResetRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(softwareResetArgument)
    }

    static func isOfficialGen4CompactRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(officialGen4CompactArgument)
    }

    static func isStopR10Then6ARequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(stopR10Then6AArgument)
    }

    static func isHelloThen6ARequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(helloThen6AArgument)
    }

    static func isRev1IMURequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(rev1IMUArgument)
    }

    static func isReleaseHistoricalThen6ARequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(releaseHistoricalThen6AArgument)
    }

    static func isAllDayRecoveryRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        expandedLaunchArguments(arguments).contains(allDayRecoveryArgument)
    }

    static func allDayRecoveryAfterSeconds(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> TimeInterval? {
        let arguments = expandedLaunchArguments(arguments)
        for argument in arguments {
            let prefix = allDayRecoveryAfterSecondsArgument + "="
            if argument.hasPrefix(prefix),
               let value = TimeInterval(argument.dropFirst(prefix.count)),
               value > 0 {
                return value
            }
        }
        guard let index = arguments.firstIndex(of: allDayRecoveryAfterSecondsArgument),
              arguments.indices.contains(index + 1),
              let value = TimeInterval(arguments[index + 1]),
              value > 0 else {
            return nil
        }
        return value
    }

    static func compact33CountSnapshot() -> Int {
        lock.withLock { compact33Count }
    }

    static func hasInitialStream5() -> Bool {
        lock.withLock { initialStream5Established }
    }

    static func armQuietLease(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        now: Date = Date()
    ) {
        guard isQuietLeaseActive(arguments: arguments) else { return }
        let livePID = liveProcessIdentifier()
        lock.lock()
        if startedAt != nil, processID == livePID, processID != 0 {
            lock.unlock()
            return
        }
        let reboundFromOtherPID = startedAt != nil && processID != livePID
        let inheritedStartedAt = startedAt?.timeIntervalSince1970
        runID = UUID().uuidString.lowercased()
        processID = livePID
        buildIdentity = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        startedAt = now
        monotonicOrigin = ProcessInfo.processInfo.systemUptime
        stopReason = reboundFromOtherPID ? "recorder_rebound_live_pid" : ""
        recordDuration = recordDurationSeconds(arguments: arguments)
        // Launch flags must not spend enable permits on connect. Production
        // recovery would otherwise consume them on connect. Arm only via the
        // explicit arm*() helpers at the scheduled trial time.
        singleEnableArmed = false
        singleEnableConsumed = false
        officialGen4Armed = false
        officialGen4Consumed = false
        officialGen4Step = 0
        allDayRecoveryArmed = false
        allDayRecoveryConsumed = false
        allDayRecoveryStep = 0
        releaseHistoricalArmed = false
        releaseHistoricalConsumed = false
        releaseHistoricalStep = 0
        softwareResetRequestedFlag = isSoftwareResetRequested(arguments: arguments)
        softwareResetArmed = false
        softwareResetConsumed = false
        softwareResetEpoch = 0
        unexpectedWriteCount = 0
        blockedWriteCount = 0
        allowedWriteCount = 0
        compact33Count = 0
        native34Count = 0
        equalQuality34Count = 0
        liveCompactDeviceTimestamps = []
        compactCorruptCount = 0
        nativeR10Count = 0
        nativeR11Count = 0
        withheldHistoryCount = 0
        incompleteTailCount = 0
        crcFailCount = 0
        recorderWriteFailures = 0
        durationElapsedLogged = false
        heartRateRxTotalCount = 0
        heartRateRxSinceSummary = 0
        lastHeartRateSummaryMono = 0
        lastHeartRateSummaryBPM = nil
        setupFailureRecorded = false
        cachedRawBytes = 0
        cachedRawSHA = ""
        cachedRawAt = 0
        let closingHandle = handle
        handle = nil
        lock.unlock()
        flushRecorderWrites()
        try? closingHandle?.closeFile()
        openRecorderIfNeeded()
        persistCurrentRunPointer()
        var extra: [String: Any] = [
            "record_duration_s": recordDuration,
            "run_id": lock.withLock { runID },
            "pid": Int(lock.withLock { processID }),
            "live_pid": Int(livePID),
            "build": lock.withLock { buildIdentity },
            "monotonic_origin": lock.withLock { monotonicOrigin },
            "rebound": reboundFromOtherPID,
        ]
        if let inheritedStartedAt {
            extra["inherited_started_at_ignored"] = inheritedStartedAt
        }
        record(
            kind: reboundFromOtherPID ? "lease_rebound" : "lease_armed",
            reason: reboundFromOtherPID
                ? "live_pid_owns_ble_session"
                : (singleEnableArmed ? "quiet_plus_single_6a" : "quiet_only"),
            extra: extra
        )
        persistSummary()
        UserDefaults.standard.set(true, forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmed)
        UserDefaults.standard.set(
            now.timeIntervalSince1970,
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmedAt
        )
        UserDefaults.standard.set(
            lock.withLock { runID },
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseRunID
        )
        UserDefaults.standard.set(
            Int(livePID),
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeasePID
        )
    }

    static func noteNewConnectionEpoch(_ epoch: UInt64) {
        lock.lock()
        connectionEpoch = epoch
        stream5NotifyWritesThisEpoch = 0
        // One link-up notify per new CB connect if CCCD is off and the
        // leftover-2B / timeout cooldown has expired. Do not keep the
        // stream-5 consume bit across epochs. Extra 03/04/07 stay consumed
        // for the process. Restoration and mid-link repair stay blocked.
        stream5NotifyWriteConsumed = false
        stream5EnabledThisEpoch = false
        leftover2BThisEpoch = false
        initialProprietarySubscribeOpen = true
        lock.unlock()
        record(kind: "connection_epoch", reason: "new_link", extra: ["epoch": epoch])
    }

    static func noteStream5DrivenConnectionTimeout(
        domain: String,
        code: Int,
        now: TimeInterval? = nil
    ) {
        guard domain == CBErrorDomain,
              code == CBError.connectionTimeout.rawValue else { return }
        let stamp = now ?? monotonicNow()
        let armed: Bool = lock.withLock {
            guard stream5EnabledThisEpoch || leftover2BThisEpoch else { return false }
            stream5CooldownUntilMono = stamp + stream5CooldownSeconds
            return true
        }
        guard armed else { return }
        record(
            kind: "stream5_cooldown_armed",
            reason: "stream5_connection_timeout",
            extra: [
                "until_mono": lock.withLock { stream5CooldownUntilMono },
                "cooldown_s": stream5CooldownSeconds,
            ]
        )
    }

    private static func monotonicNow() -> TimeInterval {
        monotonicNowOverride ?? ProcessInfo.processInfo.systemUptime
    }

    static func markInitialStream5Established(alreadyNotifying: Bool) {
        lock.lock()
        initialStream5Established = true
        initialProprietarySubscribeOpen = false
        lock.unlock()
        record(
            kind: "initial_notify",
            reason: alreadyNotifying ? "restored_notifying" : "discovery_subscribe",
            characteristic: AtriaBLEManager.UUIDs.strapStream5.uuidString
        )
    }

    static func recordSetupFailureIfStream5Missing(
        hasStream5: Bool,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        guard isQuietLeaseActive(arguments: arguments) else { return }
        let shouldRecord: Bool = lock.withLock {
            guard !hasStream5,
                  !setupFailureRecorded,
                  !initialStream5Established else { return false }
            setupFailureRecorded = true
            initialProprietarySubscribeOpen = false
            return true
        }
        guard shouldRecord else { return }
        record(kind: "setup_failure", reason: "stream5_missing_no_enable_against_unknown_pipe")
        persistSummary()
    }

    static func closeInitialSubscribeWindow() {
        lock.withLock { initialProprietarySubscribeOpen = false }
    }

    static func singleEnableAlreadyConsumed() -> Bool {
        lock.withLock { singleEnableConsumed }
    }

    static func armSingleEnable() {
        lock.withLock { singleEnableArmed = true }
        record(kind: "single_enable_armed", reason: "explicit_6a01_permit")
    }

    /// Arms the documented `03/01 → 6A/01 → 14/00` sequence once.
    /// A second call does not reset a consumed or in-progress sequence.
    @discardableResult
    static func armOfficialGen4Compact() -> Bool {
        let didArm: Bool = lock.withLock {
            if officialGen4Consumed { return false }
            if officialGen4Armed { return true }
            officialGen4Armed = true
            officialGen4Step = 0
            return true
        }
        if didArm, lock.withLock({ officialGen4Step == 0 && officialGen4Armed && !officialGen4Consumed }) {
            record(kind: "official_gen4_armed", reason: "explicit_0301_6a01_1400_permit")
        }
        return didArm
    }

    static func stopR10AlreadyConsumed() -> Bool {
        lock.withLock { stopR10Consumed }
    }

    @discardableResult
    static func armStopR10Then6A() -> Bool {
        let didArm: Bool = lock.withLock {
            if stopR10Consumed { return false }
            if stopR10Armed { return true }
            stopR10Armed = true
            stopR10Step = 0
            return true
        }
        if didArm {
            record(kind: "stop_r10_armed", reason: "explicit_3f00_then_6a01_permit")
        }
        return didArm
    }

    @discardableResult
    static func armHelloThen6A() -> Bool {
        let didArm: Bool = lock.withLock {
            if helloThen6AConsumed { return false }
            if helloThen6AArmed { return true }
            helloThen6AArmed = true
            helloThen6AStep = 0
            return true
        }
        if didArm {
            record(kind: "hello_then_6a_armed", reason: "explicit_2300_then_6a01_permit")
        }
        return didArm
    }

    @discardableResult
    static func armRev1IMU() -> Bool {
        let didArm: Bool = lock.withLock {
            if rev1IMUConsumed { return false }
            if rev1IMUArmed { return true }
            rev1IMUArmed = true
            return true
        }
        if didArm {
            record(kind: "rev1_imu_armed", reason: "explicit_6a_0101_permit")
        }
        return didArm
    }

    @discardableResult
    static func armReleaseHistoricalThen6A() -> Bool {
        let didArm: Bool = lock.withLock {
            if releaseHistoricalConsumed { return false }
            if releaseHistoricalArmed { return true }
            releaseHistoricalArmed = true
            releaseHistoricalStep = 0
            return true
        }
        if didArm {
            record(kind: "release_hist_armed", reason: "explicit_6900_then_6a01_permit")
        }
        return didArm
    }

    static func armAllDayAbortThen6A() {
        lock.withLock {
            allDayRecoveryArmed = true
            allDayRecoveryConsumed = false
            allDayRecoveryStep = 0
        }
        record(kind: "allday_recovery_armed", reason: "explicit_1400_then_6a01_permit")
    }

    static func armSoftwareReset() {
        lock.withLock { softwareResetArmed = true }
        record(kind: "software_reset_armed", reason: "explicit_1d00_permit")
    }

    /// True only after 0x1D went out on a prior epoch. 6A must not fire on
    /// the unrebooted link.
    static func shouldScheduleSingleEnableAfterSoftwareReset() -> Bool {
        lock.withLock {
            softwareResetRequestedFlag
                && softwareResetConsumed
                && softwareResetEpoch != 0
                && connectionEpoch != softwareResetEpoch
                && !singleEnableConsumed
        }
    }

    static func softwareResetStillOnSameEpoch() -> Bool {
        lock.withLock {
            softwareResetConsumed
                && softwareResetEpoch != 0
                && connectionEpoch == softwareResetEpoch
                && !singleEnableConsumed
        }
    }

    static func writeDecision(
        opcode: UInt8?,
        payload: [UInt8],
        reason: String,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        consumeSingleEnable: Bool = true
    ) -> WriteDecision {
        guard isQuietLeaseActive(arguments: arguments) else {
            return WriteDecision(allow: true, reason: "lease_inactive")
        }
        if opcode == softwareResetOpcode, payload == softwareResetPayload {
            let allow: Bool = lock.withLock {
                guard softwareResetArmed, !softwareResetConsumed else { return false }
                if consumeSingleEnable {
                    softwareResetConsumed = true
                    softwareResetArmed = false
                    softwareResetEpoch = connectionEpoch
                }
                return true
            }
            if allow {
                return WriteDecision(allow: true, reason: "explicit_software_reset")
            }
        }
        if opcode == AtriaBLEManager.Cmd.toggleIMUMode, payload == [0x01] {
            let allow: Bool = lock.withLock {
                guard singleEnableArmed, !singleEnableConsumed else { return false }
                if consumeSingleEnable {
                    singleEnableConsumed = true
                    singleEnableArmed = false
                }
                return true
            }
            if allow {
                return WriteDecision(allow: true, reason: "explicit_single_6a01")
            }
        }
        if opcode == AtriaBLEManager.Cmd.toggleIMUMode, payload == [0x01, 0x01] {
            let allow: Bool = lock.withLock {
                guard rev1IMUArmed, !rev1IMUConsumed else { return false }
                if consumeSingleEnable {
                    rev1IMUConsumed = true
                    rev1IMUArmed = false
                }
                return true
            }
            if allow {
                return WriteDecision(allow: true, reason: "explicit_6a_rev1")
            }
        }
        if let stopDecision = stopR10WriteDecision(
            opcode: opcode,
            payload: payload,
            consume: consumeSingleEnable
        ) {
            return stopDecision
        }
        if let helloDecision = helloThen6AWriteDecision(
            opcode: opcode,
            payload: payload,
            consume: consumeSingleEnable
        ) {
            return helloDecision
        }
        if let officialDecision = officialGen4WriteDecision(
            opcode: opcode,
            payload: payload,
            consume: consumeSingleEnable
        ) {
            return officialDecision
        }
        if let releaseDecision = releaseHistoricalWriteDecision(
            opcode: opcode,
            payload: payload,
            consume: consumeSingleEnable
        ) {
            return releaseDecision
        }
        if let recoveryDecision = allDayRecoveryWriteDecision(
            opcode: opcode,
            payload: payload,
            consume: consumeSingleEnable
        ) {
            return recoveryDecision
        }
        return WriteDecision(
            allow: false,
            reason: "quiet_lease_blocks_proprietary_tx:\(reason):\(opcode.map { String(format: "%02x", $0) } ?? "none")"
        )
    }

    private static func helloThen6AWriteDecision(
        opcode: UInt8?,
        payload: [UInt8],
        consume: Bool
    ) -> WriteDecision? {
        guard let opcode else { return nil }
        let allow: Bool = lock.withLock {
            guard helloThen6AArmed, !helloThen6AConsumed else { return false }
            switch helloThen6AStep {
            case 0:
                guard opcode == 0x23, payload == [0x00] else { return false }
                if consume { helloThen6AStep = 1 }
                return true
            case 1:
                guard opcode == AtriaBLEManager.Cmd.toggleIMUMode,
                      payload == [0x01] else { return false }
                if consume {
                    helloThen6AConsumed = true
                    helloThen6AArmed = false
                }
                return true
            default:
                return false
            }
        }
        guard allow else { return nil }
        let suffix = opcode == 0x23 ? "2300" : "6a01"
        return WriteDecision(allow: true, reason: "explicit_hello_then_6a_\(suffix)")
    }

    private static func stopR10WriteDecision(
        opcode: UInt8?,
        payload: [UInt8],
        consume: Bool
    ) -> WriteDecision? {
        guard let opcode else { return nil }
        let allow: Bool = lock.withLock {
            guard stopR10Armed, !stopR10Consumed else { return false }
            switch stopR10Step {
            case 0:
                guard opcode == AtriaBLEManager.Cmd.sendR10R11Realtime,
                      payload == [0x00] else { return false }
                if consume { stopR10Step = 1 }
                return true
            case 1:
                guard opcode == AtriaBLEManager.Cmd.toggleIMUMode,
                      payload == [0x01] else { return false }
                if consume {
                    stopR10Consumed = true
                    stopR10Armed = false
                }
                return true
            default:
                return false
            }
        }
        guard allow else { return nil }
        let suffix = opcode == AtriaBLEManager.Cmd.sendR10R11Realtime ? "3f00" : "6a01"
        return WriteDecision(allow: true, reason: "explicit_stop_r10_\(suffix)")
    }

    private static func officialGen4WriteDecision(
        opcode: UInt8?,
        payload: [UInt8],
        consume: Bool
    ) -> WriteDecision? {
        guard let opcode else { return nil }
        let bodies = AtriaBLEManager.Cmd.officialGen4CompactMotionBodies
        let allow: Bool = lock.withLock {
            guard officialGen4Armed, !officialGen4Consumed,
                  officialGen4Step < bodies.count else { return false }
            let expected = bodies[officialGen4Step]
            guard expected.count >= 2,
                  opcode == expected[0],
                  payload == Array(expected.dropFirst()) else { return false }
            if consume {
                officialGen4Step += 1
                if officialGen4Step >= bodies.count {
                    officialGen4Consumed = true
                    officialGen4Armed = false
                }
            }
            return true
        }
        guard allow else { return nil }
        return WriteDecision(
            allow: true,
            reason: String(format: "explicit_official_gen4_%02x%02x", opcode, payload.first ?? 0)
        )
    }

    private static func releaseHistoricalWriteDecision(
        opcode: UInt8?,
        payload: [UInt8],
        consume: Bool
    ) -> WriteDecision? {
        guard let opcode else { return nil }
        let allow: Bool = lock.withLock {
            guard releaseHistoricalArmed, !releaseHistoricalConsumed else { return false }
            switch releaseHistoricalStep {
            case 0:
                guard opcode == AtriaBLEManager.Cmd.toggleIMUModeHistorical,
                      payload == [0x00] else { return false }
                if consume { releaseHistoricalStep = 1 }
                return true
            case 1:
                guard opcode == AtriaBLEManager.Cmd.toggleIMUMode,
                      payload == [0x01] else { return false }
                if consume {
                    releaseHistoricalConsumed = true
                    releaseHistoricalArmed = false
                }
                return true
            default:
                return false
            }
        }
        guard allow else { return nil }
        let suffix = opcode == AtriaBLEManager.Cmd.toggleIMUModeHistorical ? "6900" : "6a01"
        return WriteDecision(allow: true, reason: "explicit_release_hist_\(suffix)")
    }

    private static func allDayRecoveryWriteDecision(
        opcode: UInt8?,
        payload: [UInt8],
        consume: Bool
    ) -> WriteDecision? {
        guard let opcode else { return nil }
        let allow: Bool = lock.withLock {
            guard allDayRecoveryArmed, !allDayRecoveryConsumed else { return false }
            switch allDayRecoveryStep {
            case 0:
                guard opcode == AtriaBLEManager.Cmd.abortHistoricalTransmits,
                      payload == [0x00] else { return false }
                if consume { allDayRecoveryStep = 1 }
                return true
            case 1:
                guard opcode == AtriaBLEManager.Cmd.toggleIMUMode,
                      payload == [0x01] else { return false }
                if consume {
                    allDayRecoveryConsumed = true
                    allDayRecoveryArmed = false
                }
                return true
            default:
                return false
            }
        }
        guard allow else { return nil }
        let suffix = opcode == AtriaBLEManager.Cmd.abortHistoricalTransmits ? "1400" : "6a01"
        return WriteDecision(allow: true, reason: "explicit_allday_recovery_\(suffix)")
    }

    static func isExplicitDiagnosticWriteReason(_ reason: String) -> Bool {
        reason == "explicit_single_6a01"
            || reason == "explicit_software_reset"
            || reason.hasPrefix("explicit_official_gen4_")
            || reason.hasPrefix("explicit_allday_recovery_")
            || reason.hasPrefix("explicit_release_hist_")
            || reason.hasPrefix("explicit_hello_then_6a_")
            || reason.hasPrefix("explicit_stop_r10_")
            || reason == "explicit_6a_rev1"
    }

    static func notifyDecision(
        uuid: CBUUID,
        enable: Bool,
        phase: NotifyPhase,
        alreadyNotifying: Bool = false,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> NotifyDecision {
        guard isQuietLeaseActive(arguments: arguments) else {
            return NotifyDecision(allow: true, reason: "lease_inactive")
        }
        if uuid == AtriaBLEManager.UUIDs.heartRateMeasure {
            return NotifyDecision(allow: true, reason: "preserve_2a37")
        }
        if uuid == AtriaBLEManager.UUIDs.batteryLevel
            || uuid == AtriaBLEManager.UUIDs.batteryLevelStatus {
            return NotifyDecision(allow: true, reason: "battery_standard")
        }
        if uuid == AtriaBLEManager.UUIDs.strapStream5 {
            if alreadyNotifying {
                lock.withLock { stream5NotifyWriteConsumed = true }
                return NotifyDecision(allow: false, reason: "skip_already_notifying")
            }
            if !enable {
                return NotifyDecision(
                    allow: false,
                    reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):off"
                )
            }
            if phase == .restoration {
                return NotifyDecision(allow: false, reason: "quiet_lease_initial_or_restored")
            }
            if phase == .midLinkRepair {
                return NotifyDecision(
                    allow: false,
                    reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):on"
                )
            }
            enum Stream5LinkUp {
                case enable
                case cooldownSkip(remaining: TimeInterval)
                case refuse
            }
            let linkUp: Stream5LinkUp = lock.withLock {
                guard !stream5NotifyWriteConsumed,
                      stream5NotifyWritesThisEpoch == 0,
                      (phase == .initialDiscovery
                        || (phase == .unspecified && initialProprietarySubscribeOpen)) else {
                    return .refuse
                }
                let now = monotonicNow()
                let remaining = stream5CooldownUntilMono - now
                if remaining > 0 {
                    stream5NotifyWriteConsumed = true
                    initialProprietarySubscribeOpen = false
                    stream5CooldownSkipCount += 1
                    return .cooldownSkip(remaining: remaining)
                }
                stream5NotifyWriteConsumed = true
                stream5NotifyWritesThisEpoch += 1
                stream5EnabledThisEpoch = true
                initialProprietarySubscribeOpen = false
                return .enable
            }
            switch linkUp {
            case .enable:
                return NotifyDecision(allow: true, reason: "link_up_notify_once")
            case .cooldownSkip(let remaining):
                record(
                    kind: "notify_blocked",
                    reason: stream5CooldownSkipReason,
                    characteristic: uuid.uuidString,
                    extra: [
                        "remaining_s": remaining,
                        "cooldown_s": stream5CooldownSeconds,
                    ]
                )
                return NotifyDecision(allow: false, reason: stream5CooldownSkipReason)
            case .refuse:
                break
            }
        }
        if extraNotifyUUIDs.contains(uuid) {
            guard isExtraNotifyLinkUpActive(arguments: arguments) else {
                return NotifyDecision(
                    allow: false,
                    reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):\(enable ? "on" : "off")"
                )
            }
            if alreadyNotifying {
                return NotifyDecision(allow: false, reason: "skip_already_notifying")
            }
            if !enable {
                return NotifyDecision(
                    allow: false,
                    reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):off"
                )
            }
            if phase != .initialDiscovery {
                return NotifyDecision(
                    allow: false,
                    reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):on"
                )
            }
            let allowOnce: Bool = lock.withLock {
                guard !extraNotifyWriteConsumed.contains(uuid.uuidString) else { return false }
                extraNotifyWriteConsumed.insert(uuid.uuidString)
                extraNotifyLinkUpWrites += 1
                return true
            }
            if allowOnce {
                return NotifyDecision(allow: true, reason: "extra_notify_link_up_once")
            }
            return NotifyDecision(allow: false, reason: "extra_notify_link_up_consumed")
        }
        return NotifyDecision(
            allow: false,
            reason: "quiet_lease_blocks_mid_link_cccd:\(phase.rawValue):\(enable ? "on" : "off")"
        )
    }

    static func shouldBlockMidLinkNotifyRepair(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        isQuietLeaseActive(arguments: arguments)
    }

    static func commandFromHarvardFrame(_ frame: Data) -> HarvardCommand? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 8, bytes[0] == 0xAA else { return nil }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard declaredLength >= 7, bytes.count >= 4 + 3 else { return nil }
        let payload = Array(bytes[4..<min(declaredLength, bytes.count)])
        guard payload.count >= 3, payload[0] == AtriaBLEManager.Packet.command else {
            return nil
        }
        return HarvardCommand(
            sequence: payload[1],
            opcode: payload[2],
            payload: Array(payload.dropFirst(3))
        )
    }

    static func innerPayloadType(fromNotification bytes: Data) -> UInt8? {
        let raw = [UInt8](bytes)
        if raw.count >= 5, raw[0] == 0xAA {
            return raw[4]
        }
        return raw.first
    }

    static func recordRX(
        characteristic: CBUUID,
        bytes: Data,
        connectionEpoch: UInt64,
        wall: Date = Date(),
        monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        if characteristic == AtriaBLEManager.UUIDs.heartRateMeasure {
            recordSampledHeartRateRX(
                bytes: bytes,
                connectionEpoch: connectionEpoch,
                wall: wall,
                monotonic: monotonic
            )
            return
        }
        let type = innerPayloadType(fromNotification: bytes)
        record(
            kind: "rx",
            reason: "notification",
            characteristic: characteristic.uuidString,
            hex: hex(bytes),
            extra: [
                "epoch": connectionEpoch,
                "mono": monotonic,
                "wall": wall.timeIntervalSince1970,
                "len": bytes.count,
                "type": type.map { String(format: "%02x", $0) } ?? "none",
            ]
        )
        if let parsed = parseCommandResponseNotification(bytes) {
            var extra: [String: Any] = [
                "response_seq": Int(parsed.responseSequence),
                "opcode": String(format: "%02x", parsed.opcode),
                "echo_seq": Int(parsed.echoedRequestSequence),
            ]
            if let status = parsed.status {
                extra["status"] = Int(status.byte)
            }
            record(
                kind: "rx_24",
                reason: parsed.status?.rawLabel ?? "missing_status",
                characteristic: characteristic.uuidString,
                hex: hex(bytes),
                extra: extra
            )
        }
    }

    static func recordTX(
        allowed: Bool,
        reason: String,
        frame: Data,
        characteristic: String = AtriaBLEManager.UUIDs.strapTX.uuidString
    ) {
        let command = commandFromHarvardFrame(frame)
        let counting = isQuietLeaseActive() || startedAt != nil
        if counting {
            lock.lock()
            if allowed {
                allowedWriteCount += 1
                // Radio TX outside an explicit diagnostic permit is unexpected
                // under the quiet lease. Blocked attempts are expected.
                if !isExplicitDiagnosticWriteReason(reason) {
                    unexpectedWriteCount += 1
                }
            } else {
                blockedWriteCount += 1
            }
            lock.unlock()
        }
        var extra: [String: Any] = [:]
        if let command {
            extra["opcode"] = String(format: "%02x", command.opcode)
            extra["seq"] = Int(command.sequence)
            extra["payload"] = hex(Data(command.payload))
        }
        record(
            kind: allowed ? "tx" : "tx_blocked",
            reason: reason,
            characteristic: characteristic,
            hex: hex(frame),
            extra: extra
        )
        if counting {
            persistSummary()
        }
    }

    static func recordWriteCallback(
        characteristic: CBUUID,
        error: String?,
        sequence: UInt8?,
        opcode: UInt8?
    ) {
        var extra: [String: Any] = ["error": error ?? ""]
        if let sequence { extra["seq"] = Int(sequence) }
        if let opcode { extra["opcode"] = String(format: "%02x", opcode) }
        record(
            kind: "write_cb",
            reason: error == nil ? "ok" : "error",
            characteristic: characteristic.uuidString,
            extra: extra
        )
    }

    static func recordNotifyState(
        characteristic: CBUUID,
        notifying: Bool,
        error: String?,
        phase: NotifyPhase,
        allowed: Bool
    ) {
        record(
            kind: allowed ? "notify_state" : "notify_blocked",
            reason: phase.rawValue,
            characteristic: characteristic.uuidString,
            extra: [
                "notifying": notifying,
                "error": error ?? "",
            ]
        )
    }

    static func recordOverflow(reason: String) {
        record(kind: "overflow", reason: reason)
        persistSummary()
    }

    static func record(kind: String,
                       reason: String,
                       characteristic: String? = nil,
                       hex: String? = nil,
                       extra: [String: Any] = [:]) {
        guard isQuietLeaseActive() || startedAt != nil else { return }
        let wall = Date()
        rotateRecorderIfDurationElapsed(wall: wall)
        var object: [String: Any] = [
            "kind": kind,
            "reason": reason,
            "wall": wall.timeIntervalSince1970,
            "mono": ProcessInfo.processInfo.systemUptime,
            "epoch": lock.withLock { connectionEpoch },
        ]
        if let characteristic { object["ch"] = characteristic }
        if let hex { object["hex"] = hex }
        for (key, value) in extra {
            object[key] = value
        }
        appendJSONL(object)
    }

    static func snapshot() -> [String: Any] {
        var payload: [String: Any] = lock.withLock {
            let livePID = liveProcessIdentifier()
            let integrity = rawFileIntegrityLocked()
            let loss = (processID != 0 && processID != livePID)
                || recorderWriteFailures > 0
                || (startedAt != nil && handle == nil)
            return [
                "schema": 2,
                "run_id": runID,
                "pid": Int(processID),
                "recorder_pid": Int(processID),
                "live_pid": Int(livePID),
                "recorder_loss": loss,
                "raw_file_bytes": integrity.bytes,
                "raw_file_sha256": integrity.sha256,
                "build": buildIdentity,
                "lease_active": isQuietLeaseActive(),
                "started_at": startedAt?.timeIntervalSince1970 as Any,
                "started_at_utc": startedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "monotonic_origin": monotonicOrigin,
                "stop_reason": stopReason,
                "record_duration_s": recordDuration,
                "connection_epoch": connectionEpoch,
                "initial_stream5_established": initialStream5Established,
                "stream5_notify_write_consumed": stream5NotifyWriteConsumed,
                "stream5_notify_writes_this_epoch": stream5NotifyWritesThisEpoch,
                "extra_notify_link_up": isExtraNotifyLinkUpActive(),
                "extra_notify_writes": extraNotifyLinkUpWrites,
                "extra_notify_consumed": extraNotifyWriteConsumed.sorted(),
                "stream5_cooldown_until_mono": stream5CooldownUntilMono,
                "stream5_cooldown_skip_count": stream5CooldownSkipCount,
                "stream5_enabled_this_epoch": stream5EnabledThisEpoch,
                "setup_failure": setupFailureRecorded,
                "single_enable_armed": singleEnableArmed,
                "single_enable_consumed": singleEnableConsumed,
                "official_gen4_armed": officialGen4Armed,
                "official_gen4_consumed": officialGen4Consumed,
                "official_gen4_step": officialGen4Step,
                "allday_recovery_armed": allDayRecoveryArmed,
                "allday_recovery_consumed": allDayRecoveryConsumed,
                "allday_recovery_step": allDayRecoveryStep,
                "software_reset_requested": softwareResetRequestedFlag,
                "software_reset_armed": softwareResetArmed,
                "software_reset_consumed": softwareResetConsumed,
                "software_reset_epoch": softwareResetEpoch,
                "blocked_writes": blockedWriteCount,
                "allowed_writes": allowedWriteCount,
                "unexpected_writes": unexpectedWriteCount,
                "compact_33": compact33Count,
                "native_33": compact33Count,
                "native_34": native34Count,
                "equal_quality_34": equalQuality34Count,
                "corrupt_count": compactCorruptCount,
                "live_continuity_gate": AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
                    deviceTimestamps: liveCompactDeviceTimestamps,
                    provenance: .live
                ).dictionary,
                "equal_quality_backfill_gate": AtriaWhoop4CompactIMUCoverageGate.evaluateBackfill(
                    equalQuality34Count: equalQuality34Count
                ).dictionary,
                "native_r10": nativeR10Count,
                "native_r11": nativeR11Count,
                "native_2b": nativeR10Count + nativeR11Count,
                "withheld_history": withheldHistoryCount,
                "incomplete_tail": incompleteTailCount,
                "crc_fail": crcFailCount,
                "recorder_error": recorderWriteFailures,
                "recorder_write_failures": recorderWriteFailures,
                "heart_rate_rx_total": heartRateRxTotalCount,
                "heart_rate_summary_interval_s": heartRateSummaryInterval,
                "raw_file": rawFilenameLocked(),
                "summary_file": summaryFilenameLocked(),
            ]
        }
        payload["hist_lastNotify_continuity_gate"] =
            AtriaWhoop4CompactIMUCoverageGate.evaluateContinuity(
                deviceTimestamps: AtriaStrapCalibrationArchive.shared
                    .lastNotifyCompactIMUDeviceTimestamps(),
                provenance: .histLastNotify
            ).dictionary
        return payload
    }

    static func persistSummary() {
        let payload = snapshot()
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        let url = fileURL(lock.withLock { summaryFilenameLocked() })
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lock.withLock { recorderWriteFailures += 1 }
        }
        persistCurrentRunPointer()
    }

    static func resetForTesting() {
        flushRecorderWrites()
        lock.lock()
        runID = ""
        processID = 0
        buildIdentity = ""
        startedAt = nil
        monotonicOrigin = 0
        stopReason = ""
        handle?.closeFile()
        handle = nil
        processIdentifierOverride = nil
        cachedRawBytes = 0
        cachedRawSHA = ""
        cachedRawAt = 0
        connectionEpoch = 0
        initialProprietarySubscribeOpen = false
        initialStream5Established = false
        stream5NotifyWriteConsumed = false
        stream5NotifyWritesThisEpoch = 0
        extraNotifyWriteConsumed = []
        extraNotifyLinkUpWrites = 0
        stream5EnabledThisEpoch = false
        leftover2BThisEpoch = false
        stream5CooldownUntilMono = 0
        stream5CooldownSkipCount = 0
        monotonicNowOverride = nil
        setupFailureRecorded = false
        singleEnableArmed = false
        singleEnableConsumed = false
        officialGen4Armed = false
        officialGen4Consumed = false
        officialGen4Step = 0
        allDayRecoveryArmed = false
        allDayRecoveryConsumed = false
        allDayRecoveryStep = 0
        releaseHistoricalArmed = false
        releaseHistoricalConsumed = false
        releaseHistoricalStep = 0
        softwareResetRequestedFlag = false
        softwareResetArmed = false
        softwareResetConsumed = false
        softwareResetEpoch = 0
        unexpectedWriteCount = 0
        blockedWriteCount = 0
        allowedWriteCount = 0
        compact33Count = 0
        native34Count = 0
        equalQuality34Count = 0
        liveCompactDeviceTimestamps = []
        compactCorruptCount = 0
        nativeR10Count = 0
        nativeR11Count = 0
        withheldHistoryCount = 0
        incompleteTailCount = 0
        crcFailCount = 0
        recorderWriteFailures = 0
        durationElapsedLogged = false
        heartRateRxTotalCount = 0
        heartRateRxSinceSummary = 0
        lastHeartRateSummaryMono = 0
        lastHeartRateSummaryBPM = nil
        lock.unlock()
        UserDefaults.standard.removeObject(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmed
        )
        UserDefaults.standard.removeObject(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseArmedAt
        )
        UserDefaults.standard.removeObject(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseRunID
        )
        UserDefaults.standard.removeObject(
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeasePID
        )
    }

    static func recordAssembledFrame(
        _ frame: Data,
        connectionEpoch: UInt64,
        historyActive: Bool
    ) {
        let classification = classifyAssembledFrame(frame)
        lock.lock()
        var leftoverArmedUntil: TimeInterval?
        switch classification.kind {
        case .compact33:
            compact33Count += 1
            if let packet = AtriaWhoop4CompactIMUDecoder.decode(frame: frame) {
                liveCompactDeviceTimestamps.append(packet.deviceTimestamp)
                if liveCompactDeviceTimestamps.count > 20_000 {
                    liveCompactDeviceTimestamps.removeFirst(
                        liveCompactDeviceTimestamps.count - 20_000
                    )
                }
            } else {
                // Typed 0x33 that cannot yield planar samples — not a
                // checksum-exception trailer (those still decode).
                compactCorruptCount += 1
            }
        case .native34: native34Count += 1
        case .nativeR10, .nativeR11:
            if classification.kind == .nativeR10 {
                nativeR10Count += 1
            } else {
                nativeR11Count += 1
            }
            leftover2BThisEpoch = true
            stream5CooldownUntilMono = monotonicNow() + stream5CooldownSeconds
            leftoverArmedUntil = stream5CooldownUntilMono
        case .crcFail: crcFailCount += 1
        case .unknown: break
        }
        if AtriaWhoop4CompactIMUCoverageGate.equalQualityHistoricalIMUFrame(from: frame) != nil {
            equalQuality34Count += 1
        }
        if historyActive, classification.kind == .nativeR10 {
            withheldHistoryCount += 1
        }
        lock.unlock()
        var extra: [String: Any] = [
            "kind_class": classification.label,
            "epoch": connectionEpoch,
            "history_active": historyActive,
            "frame_sha256": sha256Hex(frame),
            "len": frame.count,
        ]
        if let deviceTimestamp = classification.deviceTimestamp {
            extra["device_ts"] = Int(deviceTimestamp)
        }
        if let sequence = classification.candidateSeq {
            extra["candidate_seq_unverified"] = Int(sequence)
        }
        record(kind: "assembled", reason: classification.label, extra: extra)
        if let until = leftoverArmedUntil {
            record(
                kind: "stream5_cooldown_armed",
                reason: "leftover_2b_assemble",
                extra: [
                    "until_mono": until,
                    "cooldown_s": stream5CooldownSeconds,
                    "kind_class": classification.label,
                ]
            )
        }
    }

    static func noteIncompleteTail(bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        incompleteTailCount += 1
        lock.unlock()
        record(kind: "incomplete_tail", reason: "reassembly_buffer", extra: ["bytes": bytes])
    }

    static func noteWithheldHistory() {
        lock.lock()
        withheldHistoryCount += 1
        lock.unlock()
    }

    private enum AssembledKind {
        case compact33
        case native34
        case nativeR10
        case nativeR11
        case crcFail
        case unknown
    }

    private struct AssembledClassification {
        let kind: AssembledKind
        let label: String
        let deviceTimestamp: UInt32?
        let candidateSeq: UInt16?
    }

    private static func classifyAssembledFrame(_ frame: Data) -> AssembledClassification {
        let bytes = [UInt8](frame)
        guard bytes.count >= 9, bytes[0] == 0xAA else {
            return AssembledClassification(
                kind: .unknown,
                label: "unknown",
                deviceTimestamp: nil,
                candidateSeq: nil
            )
        }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let totalLength = declaredLength + 4
        guard declaredLength >= 5, totalLength <= bytes.count else {
            return AssembledClassification(
                kind: .unknown,
                label: "unknown",
                deviceTimestamp: nil,
                candidateSeq: nil
            )
        }
        let payload = Array(bytes[4..<min(declaredLength, bytes.count)])
        let actualCRC = UInt32(bytes[declaredLength])
            | (UInt32(bytes[declaredLength + 1]) << 8)
            | (UInt32(bytes[declaredLength + 2]) << 16)
            | (UInt32(bytes[declaredLength + 3]) << 24)
        let crcOK = crc32(payload) == actualCRC
        let packet = payload.first
        let recordType = payload.count > 1 ? payload[1] : nil
        if packet == AtriaBLEManager.Packet.imu {
            return AssembledClassification(
                kind: .compact33,
                label: "compact_33",
                deviceTimestamp: nil,
                candidateSeq: nil
            )
        }
        if packet == 0x34 {
            return AssembledClassification(
                kind: .native34,
                label: "native_34",
                deviceTimestamp: nil,
                candidateSeq: nil
            )
        }
        if packet == AtriaBLEManager.Packet.realtimeRaw, recordType == 0x0A {
            if !crcOK {
                return AssembledClassification(
                    kind: .crcFail,
                    label: "crc_fail",
                    deviceTimestamp: nil,
                    candidateSeq: nil
                )
            }
            return AssembledClassification(
                kind: .nativeR10,
                label: "native_r10",
                deviceTimestamp: AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: frame),
                candidateSeq: AtriaR10MotionDecoder.unverifiedCandidateSequence(payload: payload)
            )
        }
        if packet == AtriaBLEManager.Packet.realtimeRaw, recordType == 0x0B {
            return AssembledClassification(
                kind: crcOK ? .nativeR11 : .crcFail,
                label: crcOK ? "native_r11" : "crc_fail",
                deviceTimestamp: nil,
                candidateSeq: nil
            )
        }
        return AssembledClassification(
            kind: .unknown,
            label: "unknown",
            deviceTimestamp: nil,
            candidateSeq: nil
        )
    }

    private static func persistCurrentRunPointer() {
        let payload: [String: Any] = lock.withLock {
            let livePID = liveProcessIdentifier()
            let integrity = rawFileIntegrityLocked()
            let loss = (processID != 0 && processID != livePID)
                || recorderWriteFailures > 0
            return [
                "run_id": runID,
                "pid": Int(processID),
                "recorder_pid": Int(processID),
                "live_pid": Int(livePID),
                "recorder_loss": loss,
                "raw_file_bytes": integrity.bytes,
                "raw_file_sha256": integrity.sha256,
                "build": buildIdentity,
                "raw_file": rawFilenameLocked(),
                "summary_file": summaryFilenameLocked(),
                "started_at": startedAt?.timeIntervalSince1970 as Any,
            ]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: fileURL(currentRunPointerFilename), options: .atomic)
    }

    /// Caller must hold `lock`.
    private static func rawFileIntegrityLocked() -> (bytes: UInt64, sha256: String) {
        let url = fileURL(rawFilenameLocked())
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
            as? NSNumber)?.uint64Value ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        if bytes == cachedRawBytes, now - cachedRawAt < 2, !cachedRawSHA.isEmpty {
            return (bytes, cachedRawSHA)
        }
        cachedRawBytes = bytes
        cachedRawAt = now
        if bytes == 0 {
            cachedRawSHA = ""
            return (0, "")
        }
        if bytes > 512_000 {
            cachedRawSHA = "size:\(bytes)"
            return (bytes, cachedRawSHA)
        }
        let data = (try? Data(contentsOf: url)) ?? Data()
        cachedRawBytes = UInt64(data.count)
        cachedRawSHA = sha256Hex(data)
        return (cachedRawBytes, cachedRawSHA)
    }

    private static func rawFilenameLocked() -> String {
        runID.isEmpty
            ? "atria-imu-diagnostic-raw-v1.jsonl"
            : "atria-imu-diagnostic-raw-v1-\(runID).jsonl"
    }

    private static func summaryFilenameLocked() -> String {
        runID.isEmpty
            ? "atria-imu-diagnostic-summary-v1.json"
            : "atria-imu-diagnostic-summary-v1-\(runID).json"
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseCommandResponseNotification(
        _ bytes: Data
    ) -> AtriaWhoop4CommandResponse.Parsed? {
        let raw = [UInt8](bytes)
        if raw.count >= 5, raw[0] == 0xAA {
            let declaredLength = Int(raw[1]) | (Int(raw[2]) << 8)
            let end = min(declaredLength, raw.count)
            guard end > 4 else { return nil }
            return AtriaWhoop4CommandResponse.parsePayload(Array(raw[4..<end]))
        }
        return AtriaWhoop4CommandResponse.parsePayload(raw)
    }

    /// Must not take `lock`. Callers such as `snapshot` already hold it;
    /// `documentsDirectoryOverride` would deadlock (NSLock is not recursive).
    private static func fileURL(_ name: String) -> URL {
        let directory = documentsOverride
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent(name)
    }

    /// When the segment duration elapses, finalize the current JSONL/summary
    /// and open a fresh run bound to the live PID. Quiet-lease BLE state
    /// (epochs, cooldown, consumed notify bits) stays intact.
    private static func rotateRecorderIfDurationElapsed(wall: Date) {
        let pending: (runID: String, rawFile: String, summaryFile: String, startedAt: Double)? =
            lock.withLock {
                guard let segmentStartedAt = startedAt,
                      wall.timeIntervalSince(segmentStartedAt) > recordDuration else {
                    return nil
                }
                stopReason = "recorder_duration_elapsed"
                return (
                    runID,
                    rawFilenameLocked(),
                    summaryFilenameLocked(),
                    segmentStartedAt.timeIntervalSince1970
                )
            }
        guard let pending else { return }

        persistSummary()
        appendJSONL([
            "kind": "overflow",
            "reason": "recorder_duration_elapsed",
            "wall": wall.timeIntervalSince1970,
            "mono": ProcessInfo.processInfo.systemUptime,
            "run_id": pending.runID,
        ])
        flushRecorderWrites()

        let newRunID: String = lock.withLock {
            guard let segmentStartedAt = startedAt,
                  wall.timeIntervalSince(segmentStartedAt) > recordDuration else {
                return ""
            }
            handle?.closeFile()
            handle = nil
            let nextRunID = UUID().uuidString.lowercased()
            runID = nextRunID
            startedAt = wall
            durationElapsedLogged = false
            stopReason = ""
            unexpectedWriteCount = 0
            blockedWriteCount = 0
            allowedWriteCount = 0
            compact33Count = 0
            native34Count = 0
            equalQuality34Count = 0
            liveCompactDeviceTimestamps = []
            compactCorruptCount = 0
            nativeR10Count = 0
            nativeR11Count = 0
            withheldHistoryCount = 0
            incompleteTailCount = 0
            crcFailCount = 0
            cachedRawBytes = 0
            cachedRawSHA = ""
            cachedRawAt = 0
            return nextRunID
        }
        guard !newRunID.isEmpty else { return }

        openRecorderIfNeeded()
        persistCurrentRunPointer()
        UserDefaults.standard.set(
            newRunID,
            forKey: AtriaBLEManager.RadioDefaults.imuQuietLeaseRunID
        )
        appendJSONL([
            "kind": "recorder_rotated",
            "reason": "recorder_duration_elapsed",
            "wall": wall.timeIntervalSince1970,
            "mono": ProcessInfo.processInfo.systemUptime,
            "prev_run_id": pending.runID,
            "prev_raw_file": pending.rawFile,
            "prev_summary_file": pending.summaryFile,
            "prev_started_at": pending.startedAt,
            "record_duration_s": recordDuration,
            "run_id": newRunID,
            "pid": Int(lock.withLock { processID }),
            "live_pid": Int(liveProcessIdentifier()),
        ])
        persistSummary()
    }

    private static func openRecorderIfNeeded() {
        let url = fileURL(lock.withLock { rawFilenameLocked() })
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    private static func appendJSONL(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            lock.withLock { recorderWriteFailures += 1 }
            return
        }
        data.append(0x0A)
        let payload = data
        let writeBlock = {
            openRecorderIfNeeded()
            lock.lock()
            defer { lock.unlock() }
            do {
                try handle?.write(contentsOf: payload)
            } catch {
                recorderWriteFailures += 1
            }
        }
        if documentsOverride != nil {
            writeBlock()
        } else {
            recorderWriteQueue.async(execute: writeBlock)
        }
    }

    private static func flushRecorderWrites() {
        recorderWriteQueue.sync { }
    }

    private static func recordSampledHeartRateRX(
        bytes: Data,
        connectionEpoch: UInt64,
        wall: Date,
        monotonic: TimeInterval
    ) {
        let bpm = parseHeartRateBPM(from: bytes)
        let shouldSummarize: Bool
        let total: Int
        let sinceLast: Int
        let includeHex: Bool
        lock.lock()
        heartRateRxTotalCount += 1
        heartRateRxSinceSummary += 1
        total = heartRateRxTotalCount
        sinceLast = heartRateRxSinceSummary
        let firstSample = total == 1
        let intervalElapsed = monotonic - lastHeartRateSummaryMono >= heartRateSummaryInterval
        let bpmChanged = bpm != nil && bpm != lastHeartRateSummaryBPM
        shouldSummarize = firstSample || intervalElapsed || bpmChanged
        if shouldSummarize {
            lastHeartRateSummaryMono = monotonic
            heartRateRxSinceSummary = 0
            lastHeartRateSummaryBPM = bpm
        }
        includeHex = firstSample
        lock.unlock()
        guard shouldSummarize else { return }
        var extra: [String: Any] = [
            "epoch": connectionEpoch,
            "mono": monotonic,
            "wall": wall.timeIntervalSince1970,
            "len": bytes.count,
            "hr_total": total,
            "hr_since_last_summary": sinceLast,
            "summary_interval_s": heartRateSummaryInterval,
        ]
        if let bpm { extra["bpm"] = bpm }
        record(
            kind: "hr_summary",
            reason: "sampled_2a37",
            characteristic: AtriaBLEManager.UUIDs.heartRateMeasure.uuidString,
            hex: includeHex ? hex(bytes) : nil,
            extra: extra
        )
    }

    private static func parseHeartRateBPM(from bytes: Data) -> Int? {
        guard !bytes.isEmpty else { return nil }
        let flags = bytes[0]
        if flags & 0x01 == 0 {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        }
        guard bytes.count >= 3 else { return nil }
        return Int(bytes[1]) | (Int(bytes[2]) << 8)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
