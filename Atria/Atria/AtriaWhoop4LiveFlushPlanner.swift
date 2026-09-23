import Foundation

/// Lossless live + history coordination for WHOOP 4 (Mac-validated 2026-09-23).
///
/// Physical facts this encodes (docs/WHOOP4_PROTOCOL_FINDINGS.md, "Disconnects"):
/// - Live R10/R11 (`3F/01`) is never stored by the strap. While live is on the
///   flash-history read cursor is frozen, so a backlog accumulates.
/// - Flash history (v24 rows, 1 Hz) drains at ~15–19× realtime, oldest first,
///   after `16/00`, ACKing each type-31 sub-2 chunk with `17/01` + token.
/// - `0x19` trim makes the strap discard pages while live is off: never used here.
/// - Polling `0x22` mid-drain stalled the serve: drains stop on row timestamps.
/// - The firmware step counter (R10 u16 @1293) keeps counting while disconnected.
///
/// Policy: periodic catch-up drains while live keep the backlog small; after a
/// reconnect the gap is drained first and gap steps are bridged from the
/// firmware counter; then live resumes. The planner is pure: callers feed events
/// and send the returned commands in order.
struct AtriaWhoop4LiveFlushPlanner: Sendable {
    enum Command: Equatable, Sendable {
        /// `3F/01`, write-without-response.
        case liveOn
        /// `3F/00`.
        case liveOff
        /// `16/00`.
        case historyStart
        /// `17/01` + 8-byte token from a type-31 sub-2 frame.
        case historyAck(token: [UInt8])
        /// `14/00`.
        case historyAbort
    }

    enum DrainReason: String, Equatable, Sendable {
        case periodic
        case reconnect
    }

    enum DrainEnd: String, Equatable, Sendable {
        case caughtUp
        case historyComplete
        /// No history row for `drainStallTimeout` (seen after a burst of rapid
        /// disconnects, 2026-09-23 21:43). Live resumes; a retry drain follows.
        case stalled
        case timeout
    }

    enum Event: Equatable, Sendable {
        case drainStarted(reason: DrainReason, targetDeviceSecond: UInt32)
        case drainFinished(reason: DrainReason, end: DrainEnd, rows: Int,
                           firstRowSecond: UInt32?, lastRowSecond: UInt32?)
        case gapBridged(fromDeviceSecond: UInt32, toDeviceSecond: UInt32,
                        firmwareSteps: Int, framesNotReceived: Int)
    }

    enum State: Equatable, Sendable {
        case disconnected
        case awaitingFirstFrame
        case live
        case draining
    }

    struct Accounting: Equatable, Sendable {
        /// R10 frames skipped by the counter while live was on (real transit loss).
        var missingFrames = 0
        /// R10 frames not sent because live was deliberately paused for a drain
        /// (covered by 1 Hz history rows, not a loss).
        var drainPausedFrames = 0
        var historyRows = 0
        var drains = 0
        var drainTimeouts = 0
        var bridgedFirmwareSteps = 0
    }

    static let periodicDrainInterval: TimeInterval = 300
    static let maximumDrainDuration: TimeInterval = 600
    static let drainStallTimeout: TimeInterval = 20
    static let stallRetryDelay: TimeInterval = 60
    /// Reconnect without live frames (e.g. the strap rebooted and lost the 3F latch).
    static let awaitingFrameLiveRetry: TimeInterval = 5

    private(set) var state: State = .disconnected
    private(set) var accounting = Accounting()
    private var lastFrame: (counter: UInt16, second: UInt32, firmwareSteps: UInt16)?
    private var preGapFrame: (counter: UInt16, second: UInt32, firmwareSteps: UInt16)?
    private var deviceMinusWall: Double?
    private var lastDrainEndedAt: Date?
    private var liveSince: Date?
    private var resumedFromPause = false
    private var awaitingSince: Date?
    private var awaitingRetried = false
    private var drain: (reason: DrainReason, target: UInt32, startedAt: Date, rows: Int,
                        first: UInt32?, last: UInt32?, progressAt: Date)?
    private var retryDrainAt: Date?
    /// Power policy (see `AtriaWhoop4PowerPolicy`); defaults allow everything.
    private(set) var liveAllowed = true
    private(set) var flushMode: AtriaWhoop4PowerPolicy.Flush = .periodic(interval: 300)
    private var liveStreaming = false
    static let asapFlushInterval: TimeInterval = 60

    init() {}

    // MARK: Power

    /// Apply a power decision. Returns commands needed right now (e.g. stop live).
    mutating func applyPower(_ decision: AtriaWhoop4PowerPolicy.Decision) -> [Command] {
        liveAllowed = decision.liveMotionAllowed
        flushMode = decision.flush
        if !liveAllowed, liveStreaming, state == .live {
            liveStreaming = false
            return [.liveOff]
        }
        if liveAllowed, !liveStreaming, state == .live {
            liveStreaming = true
            return [.liveOn]
        }
        return []
    }

    private var flushInterval: TimeInterval? {
        switch flushMode {
        case .asap: return Self.asapFlushInterval
        case let .periodic(interval): return interval
        case .paused: return nil
        }
    }

    // MARK: Link

    /// Notifications are confirmed on a (re)connected link.
    mutating func linkReady(now: Date) -> [Command] {
        state = .awaitingFirstFrame
        drain = nil
        awaitingSince = now
        awaitingRetried = false
        // First connection: start live immediately. Reconnect: the 3F latch may
        // already resume live frames; the gap drain starts on the first frame.
        guard preGapFrame == nil, lastFrame == nil else { return [] }
        if liveAllowed { return startLive(now: now) }
        // Live not allowed: connected but idle; flush decisions come from tick.
        state = .live
        liveSince = now
        return []
    }

    mutating func linkLost() {
        if state != .disconnected, let lastFrame { preGapFrame = lastFrame }
        state = .disconnected
        drain = nil
    }

    // MARK: Inbound data

    /// Feed every decoded R10 record (live stream).
    mutating func r10(counter: UInt16, deviceSecond: UInt32, subsecondTicks: UInt16,
                      firmwareSteps: UInt16, now: Date) -> (commands: [Command], events: [Event]) {
        deviceMinusWall = Double(deviceSecond) + Double(subsecondTicks) / 32_768
            - now.timeIntervalSince1970
        var commands: [Command] = []
        var events: [Event] = []
        if let previous = lastFrame, preGapFrame == nil {
            let delta = Int(counter &- previous.counter)
            if delta > 1, delta < 0x8000 {
                if resumedFromPause {
                    accounting.drainPausedFrames += delta - 1
                } else {
                    accounting.missingFrames += delta - 1
                }
            }
        }
        if state == .live { resumedFromPause = false }
        if state != .draining { liveStreaming = true }
        lastFrame = (counter, deviceSecond, firmwareSteps)

        if state == .awaitingFirstFrame {
            if let gapStart = preGapFrame {
                let steps = AtriaWhoop4R10Record.firmwareStepDelta(
                    from: gapStart.firmwareSteps, to: firmwareSteps)
                accounting.bridgedFirmwareSteps += steps
                events.append(.gapBridged(
                    fromDeviceSecond: gapStart.second, toDeviceSecond: deviceSecond,
                    firmwareSteps: steps,
                    framesNotReceived: max(0, Int(counter &- gapStart.counter) - 1)))
                preGapFrame = nil
                let (c, e) = beginDrain(reason: .reconnect, now: now)
                commands += c
                events += e
            } else {
                state = .live
                liveSince = liveSince ?? now
            }
        }
        return (commands, events)
    }

    /// Feed every non-live frame received on the data stream while draining.
    /// `payload` is the validated inner payload (payload[0] = packet type).
    mutating func historyFrame(payload: [UInt8], now: Date) -> (commands: [Command], events: [Event]) {
        guard state == .draining, var d = drain, !payload.isEmpty else { return ([], []) }
        switch payload[0] {
        case 0x2F where payload.count >= 11:
            let second = UInt32(payload[7]) | (UInt32(payload[8]) << 8)
                | (UInt32(payload[9]) << 16) | (UInt32(payload[10]) << 24)
            d.rows += 1
            d.progressAt = now
            d.first = d.first ?? second
            d.last = second
            drain = d
            accounting.historyRows += 1
            if second >= d.target { return endDrain(.caughtUp, now: now) }
        case 0x31 where payload.count >= 21:
            if payload[2] == 2 { return ([.historyAck(token: Array(payload[13..<21]))], []) }
            if payload[2] == 3 { return endDrain(.historyComplete, now: now) }
        default:
            break
        }
        return ([], [])
    }

    // MARK: Time

    /// Call about once per second.
    mutating func tick(now: Date) -> (commands: [Command], events: [Event]) {
        switch state {
        case .draining:
            if let d = drain, now.timeIntervalSince(d.progressAt) > Self.drainStallTimeout {
                retryDrainAt = now.addingTimeInterval(Self.stallRetryDelay)
                return endDrain(.stalled, now: now)
            }
            if let d = drain, now.timeIntervalSince(d.startedAt) > Self.maximumDrainDuration {
                return endDrain(.timeout, now: now)
            }
        case .live:
            guard let interval = flushInterval else { return ([], []) }
            if let retry = retryDrainAt, now >= retry {
                retryDrainAt = nil
                return beginDrain(reason: .periodic, now: now)
            }
            let reference = lastDrainEndedAt ?? liveSince ?? now
            if now.timeIntervalSince(reference) >= interval {
                return beginDrain(reason: .periodic, now: now)
            }
        case .awaitingFirstFrame:
            if !liveAllowed {
                // Live stays off: no latched frames expected. Drain the gap now
                // (if flushing is allowed) using the last known device clock.
                state = .live
                liveSince = liveSince ?? now
                preGapFrame = nil
                if flushInterval != nil { return beginDrain(reason: .reconnect, now: now) }
                return ([], [])
            }
            if !awaitingRetried, let since = awaitingSince,
               now.timeIntervalSince(since) >= Self.awaitingFrameLiveRetry {
                awaitingRetried = true
                liveStreaming = true
                return ([.liveOn], [])
            }
        case .disconnected:
            break
        }
        return ([], [])
    }

    // MARK: Internals

    private mutating func startLive(now: Date) -> [Command] {
        liveSince = liveSince ?? now
        liveStreaming = true
        return [.liveOn]
    }

    private mutating func beginDrain(reason: DrainReason, now: Date) -> ([Command], [Event]) {
        guard let offset = deviceMinusWall else { return ([], []) }
        let target = UInt32(max(0, (now.timeIntervalSince1970 + offset).rounded(.down) - 1))
        state = .draining
        liveStreaming = false
        drain = (reason, target, now, 0, nil, nil, now)
        accounting.drains += 1
        return ([.liveOff, .historyStart], [.drainStarted(reason: reason, targetDeviceSecond: target)])
    }

    private mutating func endDrain(_ end: DrainEnd, now: Date) -> ([Command], [Event]) {
        guard let d = drain else { return ([], []) }
        if end == .timeout || end == .stalled { accounting.drainTimeouts += 1 }
        drain = nil
        state = .live
        lastDrainEndedAt = now
        resumedFromPause = true
        liveStreaming = liveAllowed
        return (liveAllowed ? [.historyAbort, .liveOn] : [.historyAbort],
                [.drainFinished(reason: d.reason, end: end, rows: d.rows,
                                firstRowSecond: d.first, lastRowSecond: d.last)])
    }
}
