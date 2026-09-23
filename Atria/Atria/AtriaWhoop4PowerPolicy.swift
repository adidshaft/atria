import Foundation

/// Battery/thermal policy for the WHOOP 4 live stream and history flush.
///
/// Physical grounding:
/// - Live R10/R11 (`3F/01`) is the heavy radio mode (~4 KB/s). A 13 % strap
///   delivered R10 but dropped the link after ~12 s (see
///   `AtriaBLEManager.shouldArmHighFrequencyMotion`), so live motion keeps the
///   app's existing 25 % warning threshold.
/// - Deferring a flush is lossless: history waits in strap flash and drains at
///   ~15–19× realtime later. Skipping flushes on a low strap or phone only
///   delays data; it never loses it.
/// - Standard heart rate (2A37) is cheap and always stays on.
/// Thresholds use hysteresis (a higher resume level) so the policy does not
/// flap around a boundary.
struct AtriaWhoop4PowerPolicy: Equatable, Sendable {
    enum Thermal: Int, Comparable, Sendable {
        case nominal, fair, serious, critical
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Inputs: Equatable, Sendable {
        /// Strap battery percent; `nil` = unknown (never treated as low).
        var strapBattery: Int?
        var strapCharging: Bool
        var phoneBattery: Int?
        var phoneCharging: Bool
        var phoneLowPowerMode: Bool
        var phoneThermal: Thermal

        init(strapBattery: Int? = nil, strapCharging: Bool = false,
             phoneBattery: Int? = nil, phoneCharging: Bool = false,
             phoneLowPowerMode: Bool = false, phoneThermal: Thermal = .nominal) {
            self.strapBattery = strapBattery
            self.strapCharging = strapCharging
            self.phoneBattery = phoneBattery
            self.phoneCharging = phoneCharging
            self.phoneLowPowerMode = phoneLowPowerMode
            self.phoneThermal = phoneThermal
        }
    }

    enum Flush: Equatable, Sendable {
        /// Drain continuously until caught up (something is charging).
        case asap
        /// Periodic drains at `interval`, plus a drain after every reconnect.
        case periodic(interval: TimeInterval)
        /// No drains; history waits safely in strap flash.
        case paused
    }

    struct Decision: Equatable, Sendable {
        var liveMotionAllowed: Bool
        var flush: Flush
        var reason: String
    }

    static let liveStrapMinimum = 25
    static let liveStrapResume = 30
    static let flushStrapMinimum = 20
    static let flushStrapResume = 25
    static let strapShutoff = 5
    static let phoneMinimum = 20
    static let phoneResume = 25
    static let normalFlushInterval: TimeInterval = 300
    static let conservingFlushInterval: TimeInterval = 1_800

    /// Previous decision drives hysteresis.
    private(set) var lastDecision: Decision?

    init() {}

    mutating func decide(_ input: Inputs) -> Decision {
        let previous = lastDecision
        let decision = Self.evaluate(input, previous: previous)
        lastDecision = decision
        return decision
    }

    static func evaluate(_ input: Inputs, previous: Decision?) -> Decision {
        let strapLowForLive = isBelow(input.strapBattery, minimum: liveStrapMinimum, resume: liveStrapResume,
                                      wasBlocked: previous.map { !$0.liveMotionAllowed } ?? false)
        let strapLowForFlush = isBelow(input.strapBattery, minimum: flushStrapMinimum, resume: flushStrapResume,
                                       wasBlocked: previous?.flush == .paused)
        let phoneWasConserving = previous.map { !$0.liveMotionAllowed } ?? false
        let phoneLow = isBelow(input.phoneBattery, minimum: phoneMinimum, resume: phoneResume,
                               wasBlocked: phoneWasConserving)
        let phoneConserving = !input.phoneCharging
            && (phoneLow || input.phoneLowPowerMode || input.phoneThermal >= .serious)

        if let strap = input.strapBattery, strap <= strapShutoff, !input.strapCharging {
            return Decision(liveMotionAllowed: false, flush: .paused, reason: "strap_critical")
        }
        if input.phoneThermal == .critical {
            return Decision(liveMotionAllowed: false, flush: .paused, reason: "phone_thermal_critical")
        }
        if input.strapCharging || input.phoneCharging {
            let liveOK = (input.strapCharging || !strapLowForLive) && !phoneConserving
            return Decision(liveMotionAllowed: liveOK, flush: .asap, reason: "charging")
        }
        if strapLowForFlush {
            return Decision(liveMotionAllowed: false, flush: .paused, reason: "strap_low_flush_deferred")
        }
        if phoneConserving {
            return Decision(liveMotionAllowed: false, flush: .periodic(interval: conservingFlushInterval),
                            reason: "phone_conserving")
        }
        if strapLowForLive {
            return Decision(liveMotionAllowed: false, flush: .periodic(interval: normalFlushInterval),
                            reason: "strap_low_live_off")
        }
        return Decision(liveMotionAllowed: true, flush: .periodic(interval: normalFlushInterval), reason: "normal")
    }

    /// Below `minimum` blocks; once blocked, stays blocked until `resume`.
    private static func isBelow(_ level: Int?, minimum: Int, resume: Int, wasBlocked: Bool) -> Bool {
        guard let level else { return false }
        return wasBlocked ? level < resume : level < minimum
    }
}
