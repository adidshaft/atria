import Foundation
import UserNotifications

/// Honest classification of how Atria's notifications actually reach the
/// wearer. Every scheduling path requests PROVISIONAL authorization, which
/// iOS delivers quietly — straight to Notification Center with no banner, no
/// lock-screen wake, no sound. Nothing in the app ever surfaced that posture,
/// so months of delivered notifications looked like "they never show up"
/// (owner report 2026-08-28: "I see many when I open the notification bar,
/// but they never pop up"). This model names the state; the Settings card
/// shows it always, and the one-time Today card offers the one-tap upgrade.
enum AtriaNotificationProminence: String {
    /// iOS has never asked; the first scheduled notification will be quiet.
    case notDetermined
    /// Provisional: delivered silently to Notification Center only.
    case quiet
    /// Full authorization: banners, lock screen, sound.
    case full
    /// The wearer said no in iOS Settings; nothing is delivered at all.
    case denied

    static func classify(_ status: UNAuthorizationStatus) -> AtriaNotificationProminence {
        switch status {
        case .provisional: return .quiet
        case .authorized, .ephemeral: return .full
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func current() async -> AtriaNotificationProminence {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return classify(settings.authorizationStatus)
    }

    /// Short, honest line for the Settings card.
    var settingsStatusText: String {
        switch self {
        case .notDetermined:
            return "Not asked yet — the first notification arrives quietly."
        case .quiet:
            return "Delivered quietly — notifications go to Notification "
                + "Center without popping up."
        case .full:
            return "Alerts on — new detections pop up like normal notifications."
        case .denied:
            return "Off in iOS Settings — Atria can't show any notifications."
        }
    }

    /// Whether the state can be fixed by Atria's own full-authorization
    /// request (vs needing the iOS Settings app).
    var canRequestUpgradeInApp: Bool {
        self == .quiet || self == .notDetermined
    }
}

/// Eligibility for the one-shot Today-screen "enable alerts" card — pure so
/// the rule is testable without UNUserNotificationCenter.
enum AtriaNotificationProminenceUpgradeCard {
    static let dismissedKey = "atria.notificationProminence.upgradeCard.dismissed.v1"

    /// Show only when there is something real to fix: deliveries are quiet AND
    /// at least one notification has actually been delivered quietly (before
    /// that, the posture costs the wearer nothing). Never shown over a denial
    /// (that was a choice; the Settings row stays honest about it), never
    /// after dismissal, never when the master toggle is off.
    static func shouldShow(prominence: AtriaNotificationProminence,
                           hasDeliveredQuietly: Bool,
                           dismissed: Bool,
                           masterToggleOn: Bool) -> Bool {
        guard masterToggleOn, !dismissed else { return false }
        switch prominence {
        case .quiet: return hasDeliveredQuietly
        case .notDetermined, .full, .denied: return false
        }
    }

    /// Evidence that quiet deliveries actually happened: the event-key dedup
    /// ledger records every successfully-added event notification, and the
    /// attempt store records the scheduled morning kinds.
    static func hasQuietDeliveryEvidence(defaults: UserDefaults = .standard) -> Bool {
        if let keys = defaults.stringArray(forKey: "atria.notification.eventKeys.v1"),
           !keys.isEmpty {
            return true
        }
        for kind in ["morning_checkin", "morning_summary"] {
            if AtriaNotificationAttemptStore.latest(kind: kind, defaults: defaults)?
                .outcome == .scheduled {
                return true
            }
        }
        return false
    }

    static func isDismissed(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: dismissedKey)
    }

    static func dismiss(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: dismissedKey)
    }
}
