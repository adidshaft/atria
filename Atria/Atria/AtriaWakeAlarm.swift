import Foundation
import SwiftUI

#if canImport(AlarmKit)
import AlarmKit
#endif

struct AtriaWakeAlarmPlan: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable {
        case exactTime
        case smartWindow
        case sleepNeedMet

        var title: String {
            switch self {
            case .exactTime: return "Exact time"
            case .smartWindow: return "Smart window"
            case .sleepNeedMet: return "Sleep-need met"
            }
        }
    }

    var mode: Mode
    var wakeByHour: Int
    var wakeByMinute: Int

    static let defaultPlan = AtriaWakeAlarmPlan(mode: .smartWindow,
                                                wakeByHour: 7,
                                                wakeByMinute: 30)

    var wakeByMinutes: Int {
        min(max(wakeByHour, 0), 23) * 60 + min(max(wakeByMinute, 0), 59)
    }

    func hardAlarmDate(after date: Date = Date(), calendar: Calendar = .current) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let candidate = normalized.addingTimeInterval(TimeInterval(wakeByMinutes * 60))
        if candidate > date {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(86_400)
    }

    var displayTime: String {
        let hour24 = wakeByMinutes / 60
        let minute = wakeByMinutes % 60
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d %@", hour12, minute, hour24 >= 12 ? "PM" : "AM")
    }
}

struct AtriaWakeAlarmWindowSample: Equatable {
    let t: Date
    let bpm: Int
    let stage: SleepStageKind
}

enum AtriaWakeAlarmDecision: Equatable {
    case wait(reason: String)
    case fireNow(reason: String)
    case hardAlarm(reason: String)
}

enum AtriaWakeAlarmPlanner {
    static let smartWindowDuration: TimeInterval = 30 * 60
    static let stageLookback: TimeInterval = 10 * 60

    static func smartWindowStart(for hardAlarm: Date) -> Date {
        hardAlarm.addingTimeInterval(-smartWindowDuration)
    }

    static func decision(plan: AtriaWakeAlarmPlan,
                         now: Date,
                         hardAlarm: Date,
                         sleptHours: Double,
                         neededHours: Double,
                         samples: [AtriaWakeAlarmWindowSample]) -> AtriaWakeAlarmDecision {
        guard now < hardAlarm else {
            return .hardAlarm(reason: "wake_by_reached")
        }
        switch plan.mode {
        case .exactTime:
            return .wait(reason: "exact_time_waiting")
        case .sleepNeedMet:
            if sleptHours >= neededHours {
                return .fireNow(reason: "sleep_need_met")
            }
            return .wait(reason: "sleep_need_not_met")
        case .smartWindow:
            guard now >= smartWindowStart(for: hardAlarm) else {
                return .wait(reason: "before_smart_window")
            }
            let recent = samples
                .filter { $0.t >= now.addingTimeInterval(-stageLookback) && $0.t <= now }
                .sorted { $0.t < $1.t }
            guard recent.count >= 2 else {
                return .wait(reason: "insufficient_recent_samples")
            }
            let lightOrAwake = recent.contains { $0.stage == .light || $0.stage == .awake }
            let slope = Double(recent.last?.bpm ?? 0) - Double(recent.first?.bpm ?? 0)
            if lightOrAwake && slope >= 0 {
                return .fireNow(reason: "light_stage_hr_slope_nonnegative")
            }
            return .wait(reason: "not_light_or_hr_falling")
        }
    }
}

struct AtriaWakeAlarmStore {
    static let enabledKey = "atria.wakeAlarm.enabled"
    static let modeKey = "atria.wakeAlarm.mode"
    static let wakeByMinutesKey = "atria.wakeAlarm.wakeByMinutes"
    static let lastScheduledIDKey = "atria.wakeAlarm.lastScheduledID"

    static func load(defaults: UserDefaults = .standard) -> AtriaWakeAlarmPlan {
        let mode = AtriaWakeAlarmPlan.Mode(rawValue: defaults.string(forKey: modeKey) ?? "")
            ?? AtriaWakeAlarmPlan.defaultPlan.mode
        let minutes = defaults.object(forKey: wakeByMinutesKey) as? Int
            ?? AtriaWakeAlarmPlan.defaultPlan.wakeByMinutes
        return AtriaWakeAlarmPlan(mode: mode,
                                  wakeByHour: minutes / 60,
                                  wakeByMinute: minutes % 60)
    }

    static func save(_ plan: AtriaWakeAlarmPlan, defaults: UserDefaults = .standard) {
        defaults.set(plan.mode.rawValue, forKey: modeKey)
        defaults.set(plan.wakeByMinutes, forKey: wakeByMinutesKey)
    }
}

#if canImport(AlarmKit)
@available(iOS 26.0, *)
struct AtriaWakeAlarmMetadata: AlarmMetadata {
    let mode: String
    let wakeByMinutes: Int
}
#endif

enum AtriaWakeAlarmScheduler {
    enum ScheduleResult: Equatable {
        case scheduled(id: UUID, fireDate: Date)
        case unavailable(reason: String)
        case denied
    }

    static func scheduleHardAlarm(plan: AtriaWakeAlarmPlan,
                                  now: Date = Date(),
                                  defaults: UserDefaults = .standard) async -> ScheduleResult {
        let fireDate = plan.hardAlarmDate(after: now)
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *) else {
            return .unavailable(reason: "alarmkit_unavailable")
        }
        do {
            let authorization = try await AlarmManager.shared.requestAuthorization()
            guard authorization == .authorized else { return .denied }
            if let existing = defaults.string(forKey: AtriaWakeAlarmStore.lastScheduledIDKey),
               let existingID = UUID(uuidString: existing) {
                try? AlarmManager.shared.cancel(id: existingID)
            }
            let id = UUID()
            let alert = AlarmPresentation.Alert(title: "Atria wake alarm")
            let presentation = AlarmPresentation(alert: alert)
            let attributes = AlarmAttributes(presentation: presentation,
                                             metadata: AtriaWakeAlarmMetadata(mode: plan.mode.rawValue,
                                                                              wakeByMinutes: plan.wakeByMinutes),
                                             tintColor: Color.cyan)
            let configuration = AlarmManager.AlarmConfiguration.alarm(schedule: .fixed(fireDate),
                                                                      attributes: attributes)
            _ = try await AlarmManager.shared.schedule(id: id, configuration: configuration)
            defaults.set(id.uuidString, forKey: AtriaWakeAlarmStore.lastScheduledIDKey)
            return .scheduled(id: id, fireDate: fireDate)
        } catch {
            AtriaDebugLog("ATRIADBG wake_alarm_schedule status=failed error=%@",
                          String(describing: error))
            return .unavailable(reason: "schedule_failed")
        }
        #else
        return .unavailable(reason: "alarmkit_missing")
        #endif
    }

    static func cancelLast(defaults: UserDefaults = .standard) {
        #if canImport(AlarmKit)
        guard #available(iOS 26.0, *),
              let existing = defaults.string(forKey: AtriaWakeAlarmStore.lastScheduledIDKey),
              let existingID = UUID(uuidString: existing) else {
            return
        }
        try? AlarmManager.shared.cancel(id: existingID)
        defaults.removeObject(forKey: AtriaWakeAlarmStore.lastScheduledIDKey)
        #endif
    }
}
