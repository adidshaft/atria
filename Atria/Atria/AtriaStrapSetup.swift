import Combine
import CoreBluetooth
import Foundation

/// Deterministic first-run strap setup (2026-09-24 rework; owner: "easier,
/// deterministic, non sluggish, 100% success rate or clear classified error").
///
/// Pure model. `Tracker` turns transport snapshots into one attempt timeline;
/// `evaluate` turns that timeline into a four-row checklist plus at most one
/// classified problem (code, short fix steps, one action). Every wait has a
/// fixed budget, so the screen never sits on an unexplained spinner. Problems
/// are advisory while the transport keeps working: if the strap appears after
/// "not found" was shown, the checklist simply advances.
///
/// Ready = this attempt proved the protected command channel (read-only 22/00
/// write confirmed, which requires the iOS bond). It latches: a later link blip
/// cannot un-verify setup. Heart rate is shown live but is not a gate — an
/// off-wrist strap pauses HR by design (wear gate), and waiting for it was the
/// old "stuck on Waiting for a fresh signal" failure.
enum AtriaStrapSetup {
    enum Radio: Equatable, Sendable {
        case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

        init(_ state: CBManagerState) {
            switch state {
            case .poweredOn: self = .poweredOn
            case .poweredOff: self = .poweredOff
            case .unauthorized: self = .unauthorized
            case .unsupported: self = .unsupported
            case .resetting: self = .resetting
            case .unknown: self = .unknown
            @unknown default: self = .unknown
            }
        }
    }

    enum Link: Equatable, Sendable { case idle, searching, connecting, connected }

    /// CoreBluetooth / ATT failures that change what the user must do. Benign
    /// drops (range loss, app cancel) are not errors; `Tracker` counts drops.
    enum LinkError: Equatable, Sendable {
        case bondRemoved            // CBError 14: strap discarded this iPhone's bond
        case pairingNotCompleted    // CBError 15 / ATT 0x05, 0x0C, 0x0F
        case connectionTimedOut     // CBError 6
        case connectionFailed       // CBError 10, 11
        case tooManyPairedDevices   // CBError 16

        static func classify(domain: String, code: Int) -> LinkError? {
            if domain == CBATTErrorDomain, [0x05, 0x0C, 0x0F].contains(code) {
                return .pairingNotCompleted
            }
            guard domain == CBErrorDomain else { return nil }
            switch code {
            case 14: return .bondRemoved
            case 15: return .pairingNotCompleted
            case 6: return .connectionTimedOut
            case 10, 11: return .connectionFailed
            case 16: return .tooManyPairedDevices
            default: return nil
            }
        }
    }

    enum SecureCheck: Equatable, Sendable {
        case notStarted, running, confirmed, securityRequired, failed, timedOut, interrupted, skipped

        var isFinal: Bool {
            switch self {
            case .notStarted, .running: return false
            default: return true
            }
        }
    }

    /// Published by the BLE manager: facts only it can observe.
    struct TransportSignals: Equatable, Sendable {
        var strapsSeen = 0
        var linkErrorCount = 0
        var lastLinkError: LinkError?
        var secureCheck: SecureCheck = .notStarted
        /// Incremented each time a secure check starts, so a verdict from an
        /// earlier run can never be read as this attempt's result.
        var secureCheckRun = 0
    }

    /// Everything the setup screen reads from the transport at one instant.
    struct Snapshot: Equatable, Sendable {
        var radio: Radio
        var link: Link
        var signals = TransportSignals()
        var heartRate = 0
        var contact = false
        var strapBattery: Int?
        var strapCharging = false
    }

    struct Attempt: Equatable, Sendable {
        var startedAt: Date
        var radioWaitSince: Date?
        var searchingSince: Date?
        var connectingSince: Date?
        var connectedSince: Date?
        var secureRunningSince: Date?
        var drops = 0
        var errors: [LinkError] = []
        var strapsSeenAtStart = 0
        var linkErrorCountAtStart = 0
        var secureRunAtStart = 0
        var verified = false
        var last: Snapshot?

        var strapSeen: Bool { (last?.signals.strapsSeen ?? 0) > strapsSeenAtStart }
    }

    struct Tracker: Equatable, Sendable {
        private(set) var attempt: Attempt

        init(now: Date, snapshot: Snapshot) {
            attempt = Attempt(startedAt: now)
            restart(now: now, snapshot: snapshot)
        }

        /// Retry: a new attempt, same transport. Counters are relative so old
        /// errors and adverts never leak into the new attempt's verdict.
        mutating func restart(now: Date, snapshot: Snapshot) {
            let wasVerified = attempt.verified
            attempt = Attempt(startedAt: now,
                              strapsSeenAtStart: snapshot.signals.strapsSeen,
                              linkErrorCountAtStart: snapshot.signals.linkErrorCount,
                              secureRunAtStart: snapshot.signals.secureCheckRun)
            attempt.verified = wasVerified
            observe(snapshot, now: now)
        }

        /// The snapshot as this attempt sees it: a failed secure verdict from
        /// a run that started before the attempt reads as not started. A
        /// standing confirmation always counts (it is only ever set for the
        /// current connection; a new connection resets it).
        func effective(_ raw: Snapshot) -> Snapshot {
            var s = raw
            if s.signals.secureCheck.isFinal,
               !Self.verifies(s.signals.secureCheck),
               s.signals.secureCheckRun <= attempt.secureRunAtStart {
                s.signals.secureCheck = .notStarted
            }
            return s
        }

        mutating func observe(_ raw: Snapshot, now: Date) {
            let s = effective(raw)
            let previous = attempt.last
            if s.radio == .poweredOn {
                attempt.radioWaitSince = nil
            } else {
                if attempt.radioWaitSince == nil { attempt.radioWaitSince = now }
                attempt.searchingSince = nil
                attempt.connectingSince = nil
            }
            if s.radio == .poweredOn {
                switch s.link {
                case .idle, .searching:
                    if attempt.searchingSince == nil { attempt.searchingSince = now }
                    attempt.connectingSince = nil
                    attempt.connectedSince = nil
                case .connecting:
                    if attempt.connectingSince == nil { attempt.connectingSince = now }
                    attempt.connectedSince = nil
                    // A failed connect falls back to searching with a fresh
                    // find budget, not one already spent while connecting.
                    attempt.searchingSince = nil
                case .connected:
                    if attempt.connectedSince == nil { attempt.connectedSince = now }
                    attempt.connectingSince = nil
                    attempt.searchingSince = nil
                }
            }
            // A radio reset or the transport rebuilding its Bluetooth manager
            // is not an unstable link (2026-09-24 iPhone run: AT-203 fired
            // on the app's own central rebuild while the user was re-pairing).
            if previous?.link == .connected, s.link != .connected, !attempt.verified,
               s.radio == .poweredOn, previous?.radio == .poweredOn {
                attempt.drops += 1
                // Searching restarts its budget after a drop.
                attempt.searchingSince = s.link == .connecting ? nil : now
                attempt.secureRunningSince = nil
            }
            let newErrors = s.signals.linkErrorCount - max(attempt.linkErrorCountAtStart,
                                                           previous?.signals.linkErrorCount ?? attempt.linkErrorCountAtStart)
            if newErrors > 0, let error = s.signals.lastLinkError {
                attempt.errors.append(error)
            }
            if s.signals.secureCheck == .running {
                if attempt.secureRunningSince == nil { attempt.secureRunningSince = now }
            } else {
                attempt.secureRunningSince = nil
            }
            if s.link == .connected, Self.verifies(s.signals.secureCheck) {
                attempt.verified = true
            }
            attempt.last = s
        }

        static func verifies(_ check: SecureCheck) -> Bool {
            check == .confirmed || check == .skipped
        }
    }

    // MARK: Verdict

    enum Step: Int, CaseIterable, Sendable {
        case bluetooth, find, pair, heartRate

        var title: String {
            switch self {
            case .bluetooth: return "Bluetooth"
            case .find: return "Find strap"
            case .pair: return "Secure pairing"
            case .heartRate: return "Heart rate"
            }
        }
    }

    enum StepState: Equatable, Sendable { case waiting, working, done, problem }

    /// `wait`: nothing to tap; the problem clears on its own (e.g. Bluetooth
    /// turned back on).
    enum Action: Equatable, Sendable { case wait, retry, openSettings }

    /// Stable codes so support, logs and the owner can talk about one failure.
    enum Problem: String, CaseIterable, Sendable {
        case bluetoothOff = "AT-101"
        case bluetoothDenied = "AT-102"
        case bluetoothUnsupported = "AT-103"
        case bluetoothUnavailable = "AT-104"
        case strapNotFound = "AT-201"
        case connectTimedOut = "AT-202"
        case linkUnstable = "AT-203"
        case tooManyPairedDevices = "AT-204"
        case pairedElsewhere = "AT-301"
        case pairingNotCompleted = "AT-302"
        case verifyTimedOut = "AT-303"
        case verifyFailed = "AT-304"

        var code: String { rawValue }

        var step: Step {
            switch self {
            case .bluetoothOff, .bluetoothDenied, .bluetoothUnsupported, .bluetoothUnavailable: return .bluetooth
            case .strapNotFound, .connectTimedOut, .linkUnstable, .tooManyPairedDevices: return .find
            case .pairedElsewhere, .pairingNotCompleted, .verifyTimedOut, .verifyFailed: return .pair
            }
        }

        var title: String {
            switch self {
            case .bluetoothOff: return "Bluetooth is off"
            case .bluetoothDenied: return "Atria can't use Bluetooth"
            case .bluetoothUnsupported: return "This device has no Bluetooth LE"
            case .bluetoothUnavailable: return "Bluetooth isn't responding"
            case .strapNotFound: return "Strap not found"
            case .connectTimedOut: return "Strap found, but it won't connect"
            case .linkUnstable: return "Connection keeps dropping"
            case .tooManyPairedDevices: return "iPhone has too many paired devices"
            case .pairedElsewhere: return "The strap forgot this iPhone"
            case .pairingNotCompleted: return "Pairing wasn't accepted"
            case .verifyTimedOut: return "Pairing is taking too long"
            case .verifyFailed: return "The strap didn't answer"
            }
        }

        static let pairingMode = "Tap the top of the strap until the side light pulses blue."

        var steps: [String] {
            switch self {
            case .bluetoothOff:
                return ["Turn on Bluetooth in Control Center. Setup continues on its own."]
            case .bluetoothDenied:
                return ["Open Settings → Atria.", "Turn on Bluetooth, then come back."]
            case .bluetoothUnsupported:
                return ["Use an iPhone with Bluetooth to set up your strap."]
            case .bluetoothUnavailable:
                return ["Turn Bluetooth off and on in Control Center.", "Tap Try again."]
            case .strapNotFound:
                return ["Charge the strap for a few minutes.",
                        Self.pairingMode,
                        "Close the WHOOP app and keep the strap within arm's reach."]
            case .connectTimedOut:
                return [Self.pairingMode, "Tap Try again."]
            case .linkUnstable:
                return ["Keep the strap close to this iPhone.",
                        "Turn off nearby Bluetooth speakers or headphones.",
                        "Tap Try again."]
            case .tooManyPairedDevices:
                return ["Settings → Bluetooth: forget devices you no longer use.", "Tap Try again."]
            case .pairedElsewhere:
                return ["Settings → Bluetooth → ⓘ next to WHOOP → Forget This Device.",
                        Self.pairingMode,
                        "Tap Try again."]
            case .pairingNotCompleted:
                return ["Tap Try again, then tap Pair when iPhone asks.",
                        "No prompt? Forget WHOOP in Settings → Bluetooth and put the strap in pairing mode again."]
            case .verifyTimedOut:
                return [Self.pairingMode, "Tap Try again and accept Pair."]
            case .verifyFailed:
                return ["Keep the strap close and charged.", "Tap Try again."]
            }
        }

        var action: Action {
            switch self {
            case .bluetoothDenied: return .openSettings
            case .bluetoothOff, .bluetoothUnsupported: return .wait
            default: return .retry
            }
        }
    }

    struct Verdict: Equatable, Sendable {
        var steps: [StepState]           // indexed by Step.rawValue
        var headline: String
        var detail: String
        var problem: Problem?
        var isReady: Bool
        var heartRate: Int?
        var batteryWarning: String?

        func state(_ step: Step) -> StepState { steps[step.rawValue] }
    }

    static let radioBudget: TimeInterval = 8
    static let findBudget: TimeInterval = 30
    /// Longer than the transport's 20 s watchdog for a stale state-restored
    /// "connecting" candidate, so that expected hand-off never flashes AT-202.
    static let connectBudget: TimeInterval = 30
    /// The read-only 22/00 write normally confirms in < 1 s. An iOS pairing
    /// prompt holds it until the user answers (encryption times out ~30 s).
    static let pairPromptHint: TimeInterval = 8
    static let verifyBudget: TimeInterval = 75
    /// Re-pairing itself can cost a drop or two (forgetting the device,
    /// iOS tearing down the link after a pairing change), so four.
    static let maxDrops = 4
    static let lowBattery = 15

    static func evaluate(_ attempt: Attempt, now: Date) -> Verdict {
        let s = attempt.last ?? Snapshot(radio: .unknown, link: .idle)
        func elapsed(_ since: Date?) -> TimeInterval { since.map { now.timeIntervalSince($0) } ?? 0 }
        let hr = s.heartRate > 0 ? s.heartRate : nil
        let battery: String? = {
            guard let level = s.strapBattery, (0..<lowBattery).contains(level), !s.strapCharging else { return nil }
            return "Strap battery \(level)%. Charge it before tonight."
        }()

        func verdict(_ states: [StepState], _ headline: String, _ detail: String,
                     problem: Problem? = nil, ready: Bool = false) -> Verdict {
            Verdict(steps: states, headline: problem?.title ?? headline, detail: detail,
                    problem: problem, isReady: ready, heartRate: hr, batteryWarning: battery)
        }
        func failing(_ p: Problem) -> Verdict {
            var states: [StepState] = Step.allCases.map { $0.rawValue < p.step.rawValue ? .done : .waiting }
            states[p.step.rawValue] = .problem
            return verdict(states, p.title, "", problem: p)
        }

        if attempt.verified {
            return verdict([.done, .done, .done, hr == nil ? .working : .done],
                           "Strap connected",
                           hr == nil ? "Put it on your wrist to see your heart rate." : "Heart rate is live.",
                           ready: true)
        }

        switch s.radio {
        case .unauthorized: return failing(.bluetoothDenied)
        case .unsupported: return failing(.bluetoothUnsupported)
        case .poweredOff: return failing(.bluetoothOff)
        case .unknown, .resetting:
            if elapsed(attempt.radioWaitSince) >= radioBudget { return failing(.bluetoothUnavailable) }
            return verdict([.working, .waiting, .waiting, .waiting], "Starting Bluetooth…", "")
        case .poweredOn:
            break
        }

        // Classified link errors outrank timers: they name the exact fix.
        if attempt.errors.contains(.bondRemoved) { return failing(.pairedElsewhere) }
        if attempt.errors.contains(.tooManyPairedDevices) { return failing(.tooManyPairedDevices) }
        if s.signals.secureCheck == .securityRequired || attempt.errors.contains(.pairingNotCompleted) {
            return failing(.pairingNotCompleted)
        }
        if attempt.drops >= maxDrops { return failing(.linkUnstable) }

        switch s.link {
        case .connected:
            switch s.signals.secureCheck {
            case .failed: return failing(.verifyFailed)
            case .timedOut: return failing(.verifyTimedOut)
            default: break
            }
            let waited = max(elapsed(attempt.secureRunningSince), elapsed(attempt.connectedSince))
            if waited >= verifyBudget { return failing(.verifyTimedOut) }
            let promptLikely = elapsed(attempt.secureRunningSince) >= pairPromptHint
            return verdict([.done, .done, .working, hr == nil ? .waiting : .done],
                           promptLikely ? "Tap Pair on your iPhone" : "Securing the connection…",
                           promptLikely ? "iPhone asks once. It keeps your strap's data private." : "")
        case .connecting:
            if elapsed(attempt.connectingSince) >= connectBudget { return failing(.connectTimedOut) }
            return verdict([.done, .done, .waiting, .waiting], "Connecting…", "")
        case .idle, .searching:
            if attempt.connectingSince == nil, elapsed(attempt.searchingSince) >= findBudget {
                var v = failing(.strapNotFound)
                v.detail = "Still looking. It connects as soon as it's found."
                return v
            }
            return verdict([.done, .working, .waiting, .waiting],
                           attempt.drops > 0 ? "Reconnecting…" : "Looking for your strap…",
                           Problem.pairingMode)
        }
    }
}

/// Drives the transport and publishes the verdict for the setup page. Owns no
/// protocol logic: it only asks the BLE manager for a scan, the one read-only
/// secure check, and a retry, on fixed rules.
@MainActor
final class AtriaStrapSetupCoordinator: ObservableObject {
    @Published private(set) var verdict: AtriaStrapSetup.Verdict

    private let ble: AtriaBLEManager
    private var tracker: AtriaStrapSetup.Tracker
    private var tick: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var lastScanKickAt: Date?
    private var interruptedRetries = 0
    private var readyAnnounced = false
    var onReady: (() -> Void)?

    static let scanKickInterval: TimeInterval = 8
    static let maxInterruptedRetries = 2

    init(ble: AtriaBLEManager, now: Date = Date()) {
        self.ble = ble
        let snapshot = Self.snapshot(ble)
        tracker = AtriaStrapSetup.Tracker(now: now, snapshot: snapshot)
        verdict = AtriaStrapSetup.evaluate(tracker.attempt, now: now)
    }

    func start() {
        guard tick == nil else { return }
        ble.startScan(reason: "onboarding_setup")
        lastScanKickAt = Date()
        // React to transport changes immediately; the 1 s tick only advances
        // time budgets. HR is sampled by the tick, never per sample.
        Publishers.Merge4(
            ble.$status.map { _ in () },
            ble.$strapSetupSignals.map { _ in () },
            ble.$bluetoothPermissionDenied.map { _ in () },
            ble.$isBluetoothReady.map { _ in () }
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in self?.step() }
        .store(in: &cancellables)
        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.step()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        tick?.cancel()
        tick = nil
        cancellables.removeAll()
    }

    func retry() {
        let now = Date()
        interruptedRetries = 0
        tracker.restart(now: now, snapshot: Self.snapshot(ble))
        if ble.status == .connected {
            ble.retryOnboardingSecureCheck()
        } else {
            ble.startScan(reason: "onboarding_setup_retry")
            lastScanKickAt = now
        }
        step(now: now)
    }

    private func step(now: Date = Date()) {
        let raw = Self.snapshot(ble)
        tracker.observe(raw, now: now)
        if drive(raw: raw, effective: tracker.effective(raw), now: now) {
            // An automatic retry just started: judge the new state, so the
            // failure it replaces never flashes on screen.
            tracker.observe(Self.snapshot(ble), now: now)
        }
        let next = AtriaStrapSetup.evaluate(tracker.attempt, now: now)
        if next != verdict { verdict = next }
        if next.isReady, !readyAnnounced {
            readyAnnounced = true
            AtriaDebugLog("ATRIADBG strap_setup status=ready drops=%d", tracker.attempt.drops)
            onReady?()
        }
        if let problem = next.problem, problem != lastLoggedProblem {
            AtriaDebugLog("ATRIADBG strap_setup status=problem code=%@", problem.code)
        }
        lastLoggedProblem = next.problem
    }

    private var lastLoggedProblem: AtriaStrapSetup.Problem?

    /// Returns true when it started an automatic secure-check retry.
    @discardableResult
    private func drive(raw: AtriaStrapSetup.Snapshot, effective s: AtriaStrapSetup.Snapshot, now: Date) -> Bool {
        guard !tracker.attempt.verified, s.radio == .poweredOn else { return false }
        switch s.link {
        case .idle:
            if lastScanKickAt.map({ now.timeIntervalSince($0) >= Self.scanKickInterval }) ?? true {
                lastScanKickAt = now
                ble.startScan(reason: "onboarding_setup_keepalive")
            }
        case .connected:
            if AtriaIMUDiagnosticTransport.isQuietLeaseActive() {
                ble.markOnboardingSecureCheckSkipped()
            } else if s.signals.secureCheck == .notStarted {
                // A stale verdict from before this attempt needs a fresh run;
                // otherwise this is the connection's one first check.
                if raw.signals.secureCheck.isFinal {
                    ble.retryOnboardingSecureCheck()
                    return true
                } else {
                    ble.requestOnboardingPairingPreflightIfNeeded()
                }
            } else if [.interrupted, .failed].contains(s.signals.secureCheck),
                      interruptedRetries < Self.maxInterruptedRetries {
                // .failed here means the command channel was not ready (TX
                // not yet rediscovered after a Bluetooth rebuild): retry
                // quietly before showing AT-304 (2026-09-24 iPhone run).
                interruptedRetries += 1
                ble.retryOnboardingSecureCheck()
                return true
            }
        case .searching, .connecting:
            break
        }
        return false
    }

    static func snapshot(_ ble: AtriaBLEManager) -> AtriaStrapSetup.Snapshot {
        let link: AtriaStrapSetup.Link
        switch ble.status {
        case .connected: link = .connected
        case .connecting: link = .connecting
        case .scanning: link = .searching
        case .disconnected, .poweredOff: link = .idle
        }
        var radio = ble.strapSetupRadio
        if ble.bluetoothPermissionDenied { radio = .unauthorized }
        return AtriaStrapSetup.Snapshot(
            radio: radio,
            link: link,
            signals: ble.strapSetupSignals,
            heartRate: ble.currentConnectionHasFreshHeartRate ? ble.heartRate : 0,
            contact: ble.hasContact,
            strapBattery: ble.batteryLevel >= 0 ? ble.batteryLevel : nil,
            strapCharging: ble.batteryIsCharging
        )
    }
}
