import Foundation

/// Honest wear/charge attribution for a connected strap whose live pulse is
/// absent — derived entirely from facts the app already holds, no transport
/// changes.
///
/// Device-measured motivation (2026-08-28, 00:41–02:17): the strap sat on its
/// charger (battery 20%→79%) while the pill flapped "No signal"→blue "Live".
/// The mechanics: a WHOOP streaming HR==0 frames still counts as raw packet
/// activity (`recordRawHRNotification` stamps before the hr>0 check), so
/// `strapStreamState` stays `.live` with no pulse; when the stream pauses
/// >120 s it flips to `.silentUnknown` ("No signal"). Both readings alarmed
/// the wearer over a strap that was simply off the wrist, charging.
///
/// The evidence rules (each claim is grounded, ambiguity keeps the old copy):
/// - A raw stream flowing while the last ACCEPTED pulse is minutes stale means
///   the strap itself is reporting no pulse — its optical sensor sees no skin.
///   That is off-wrist by the strap's own account (a worn strap being
///   pack-charged still sees skin and keeps its pulse). The same HR==0
///   semantic backs the historical decoder's `.offWrist` withholding.
/// - Proven charging (the bounded 2A19 rise proof or a 2A1B read — never the
///   fail-closed `levelOnly`) upgrades the label to "Charging".
/// - A silent stream (`.silentUnknown`) alone proves nothing about wear;
///   only proven charging may re-attribute it.
/// - A fresh accepted pulse always wins: no attribution is ever computed over
///   live heart rate.
enum AtriaStrapWearAttribution: Equatable {
    /// No claim — presentation keeps the existing honest copy.
    case none
    /// The stream is flowing but reports no pulse: off wrist by the strap's
    /// own sensor.
    case offWrist
    /// Off-wrist or silent AND charging is proven: the strap is on power.
    case charging

    /// Hysteresis floor: the accepted pulse must be at least this stale while
    /// raw packets keep flowing before "off wrist" may be claimed. Brief
    /// fit-adjustment zero runs (seconds to a couple of minutes) never claim.
    static let minimumPulselessStreamSeconds: TimeInterval = 4 * 60

    /// `chargingProven` must come from a freshness-resolved charging fact
    /// (`BatteryChargeProjection.isCharging`), never raw `levelOnly` receipts.
    static func classify(streamState: AtriaBLEManager.StrapStreamState,
                         hasFreshPulse: Bool,
                         lastAcceptedPulseAt: Date?,
                         chargingProven: Bool,
                         batteryRecentlyDropping: Bool,
                         now: Date = Date()) -> AtriaStrapWearAttribution {
        // Live pulse is the strongest truth; a dropping battery contradicts
        // any charging story.
        guard !hasFreshPulse else { return .none }
        let charging = chargingProven && !batteryRecentlyDropping

        switch streamState {
        case .live:
            // Raw packets flowing. Off-wrist needs a sustained pulseless run
            // measured from a real accepted sample — a session that never
            // accepted anything stays unclaimed (fail closed).
            guard let lastAcceptedPulseAt,
                  now.timeIntervalSince(lastAcceptedPulseAt)
                    >= minimumPulselessStreamSeconds else {
                return .none
            }
            return charging ? .charging : .offWrist
        case .silentUnknown:
            // A stopped stream carries no wear evidence of its own.
            return charging ? .charging : .none
        case .warming, .unknown, .lowBatteryShutoff, .lowBatteryReducedDetail:
            // Low-battery states already carry their own honest attribution;
            // warming/unknown have nothing to re-attribute.
            return .none
        }
    }
}
