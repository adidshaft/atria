import Foundation

/// What the Lock Screen, Dynamic Island and widgets show — the single source
/// of truth for the "Lock Screen & Widgets" settings page (2026-09-24).
///
/// Lives in the app group so the app (which starts and updates the Live
/// Activity) and the widget extension (which draws it) read the same values.
/// This file is kept byte-identical in `Atria/` and `AtriaWidget/`;
/// `AtriaGlanceSettingsTests` fails if the two copies drift.
enum AtriaGlanceSettings {
    static let appGroupID = "group.com.adidshaft.atria"
    static let modeKey = "atria.glance.liveActivityMode.v1"
    static let itemsKey = "atria.glance.liveActivityItems.v1"

    /// When the Live Activity runs.
    enum LiveActivityMode: String, CaseIterable, Identifiable, Sendable {
        /// Live heart rate stays on the Lock Screen and in the Dynamic
        /// Island whenever the strap is connected.
        case always
        /// Only during a workout you start.
        case workouts
        case off

        var id: String { rawValue }

        var title: String {
            switch self {
            case .always: return "Always"
            case .workouts: return "Workouts"
            case .off: return "Off"
            }
        }

        var detail: String {
            switch self {
            case .always: return "Live heart rate stays on your Lock Screen and in the Dynamic Island."
            case .workouts: return "Shows only while a workout is running."
            case .off: return "No Live Activity."
            }
        }

        var allowsIdlePresence: Bool { self == .always }
        var allowsWorkoutActivity: Bool { self != .off }
    }

    /// What appears next to heart rate.
    enum LiveItem: String, CaseIterable, Identifiable, Sendable {
        case zone, steps, battery

        var id: String { rawValue }

        var title: String {
            switch self {
            case .zone: return "Heart-rate zone"
            case .steps: return "Steps"
            case .battery: return "Strap battery"
            }
        }

        var systemImage: String {
            switch self {
            case .zone: return "heart.text.square"
            case .steps: return "figure.walk"
            case .battery: return "battery.75percent"
            }
        }
    }

    static var store: UserDefaults { UserDefaults(suiteName: appGroupID) ?? .standard }

    static func liveActivityMode(in defaults: UserDefaults = store) -> LiveActivityMode {
        defaults.string(forKey: modeKey).flatMap(LiveActivityMode.init(rawValue:)) ?? .always
    }

    static func setLiveActivityMode(_ mode: LiveActivityMode, in defaults: UserDefaults = store) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// Default: everything on. An empty stored list means the user turned
    /// every item off, which is a valid choice (heart rate only).
    static func liveItems(in defaults: UserDefaults = store) -> Set<LiveItem> {
        guard let raw = defaults.string(forKey: itemsKey) else { return Set(LiveItem.allCases) }
        return Set(raw.split(separator: ",").compactMap { LiveItem(rawValue: String($0)) })
    }

    static func setLiveItems(_ items: Set<LiveItem>, in defaults: UserDefaults = store) {
        let ordered = LiveItem.allCases.filter(items.contains).map(\.rawValue)
        defaults.set(ordered.joined(separator: ","), forKey: itemsKey)
    }

    static func shows(_ item: LiveItem, in defaults: UserDefaults = store) -> Bool {
        liveItems(in: defaults).contains(item)
    }
}
