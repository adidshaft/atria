import Foundation

/// A deliberately local, opt-in sample data mode for App Review. It is not an
/// account, never contacts a service, and is only reachable during first-run
/// setup by entering the reserved reviewer nickname.
enum AtriaAppReviewDemo {
    static let reviewerNickname = "App Review"
    static let activeKey = "atria.appReviewDemo.active.v1"

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }

    static func isRequested(nickname: String) -> Bool {
        normalized(nickname) == normalized(reviewerNickname)
    }

    static func activate() {
        UserDefaults.standard.set(true, forKey: activeKey)
    }

    static func deactivate() {
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// Small deterministic, rolling fixture: enough local history for every
    /// major health surface to render without presenting sample data as live.
    static func sessions(now: Date = Date(), calendar: Calendar = .current) -> [SavedSession] {
        let today = calendar.startOfDay(for: now)
        var result: [SavedSession] = []

        // The newest sleep ends this morning. Never manufacture a future
        // session: that would make Home look like it has not settled yet.
        for dayOffset in (-14)...(-1) {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let nightStart = calendar.date(byAdding: .minute, value: 22 * 60 + 20, to: day) ?? day
            let nightDuration: TimeInterval = TimeInterval((7 * 60 + 25 + (dayOffset + 13) % 4 * 8) * 60)
            let nightPoints = stride(from: 0.0, through: nightDuration, by: 300.0).enumerated().map { index, t in
                SavedSession.Point(t: t, bpm: 53 + ((index + dayOffset + 20) % 6))
            }
            result.append(SavedSession(
                id: UUID(), start: nightStart, end: nightStart.addingTimeInterval(nightDuration),
                label: "App Review demo sleep", points: nightPoints, hrv: nil,
                respiratoryRate: 14.1, biologicalSex: .unspecified,
                kind: "demo_sleep", eventTimeZoneIdentifier: TimeZone.current.identifier
            ))

            guard dayOffset.isMultiple(of: 3) else { continue }
            let workoutStart = calendar.date(byAdding: .minute, value: 17 * 60 + 40, to: day) ?? day
            let workoutDuration: TimeInterval = 38 * 60
            let workoutPoints = stride(from: 0.0, through: workoutDuration, by: 30.0).enumerated().map { index, t in
                let wave = abs((index % 18) - 9)
                return SavedSession.Point(t: t, bpm: 108 + (9 - wave) * 5)
            }
            result.append(SavedSession(
                id: UUID(), start: workoutStart, end: workoutStart.addingTimeInterval(workoutDuration),
                label: "App Review demo workout", points: workoutPoints, hrv: nil,
                biologicalSex: .unspecified, kind: "demo_workout",
                eventTimeZoneIdentifier: TimeZone.current.identifier
            ))
        }
        return result.sorted { $0.start < $1.start }
    }

    static func dailyMetrics(now: Date = Date(), calendar: Calendar = .current) -> [SavedDailyMetric] {
        let today = calendar.startOfDay(for: now)
        return (-13...0).compactMap { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let priorDay = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            let sleepStart = calendar.date(byAdding: .minute, value: 22 * 60 + 20, to: priorDay) ?? priorDay
            let sleepDuration = TimeInterval((7 * 60 + 25 + (offset + 13) % 4 * 8) * 60)
            let recovery = 68 + ((offset + 13) * 3) % 19
            let strain = 7.8 + Double((offset + 13) % 5) * 1.1
            return SavedDailyMetric(
                day: day,
                recoveryPercent: recovery,
                recoveryConfidence: "Demo data",
                hrv: 58 + (offset + 13) % 7,
                restingHR: 54 + (offset + 13) % 3,
                respiratoryRate: 14.1 + Double((offset + 13) % 3) * 0.1,
                sleepDuration: sleepDuration,
                sleepNeedSeconds: 8 * 60 * 60,
                sleepSpan: sleepDuration + 12 * 60,
                sleepStart: sleepStart,
                sleepEnd: sleepStart.addingTimeInterval(sleepDuration + 12 * 60),
                sleepSource: "Demo local data",
                sleepStageSegments: [],
                sleepConsistencyPercent: 86 + (offset + 13) % 8,
                strain: strain,
                strainCoverageFraction: 1,
                strainEvidenceQuality: .exact,
                skinTemperatureDeviationCelsius: -0.1 + Double((offset + 13) % 4) * 0.1
            )
        }.sorted { $0.day > $1.day }
    }

    static func confirmedSleeps(now: Date = Date(), calendar: Calendar = .current) -> [UserConfirmedSleep] {
        dailyMetrics(now: now, calendar: calendar).map { metric in
            let start = metric.sleepStart ?? metric.day.addingTimeInterval(-8 * 60 * 60)
            let end = metric.sleepEnd ?? metric.day
            return UserConfirmedSleep(
                id: "app-review-demo-sleep-\(Int(metric.day.timeIntervalSinceReferenceDate))",
                createdAt: now,
                start: start,
                end: end,
                source: "manual_sleep",
                confidence: "demo_data",
                sessions: 1,
                samples: Int(metric.sleepDuration ?? 0) / 300,
                avgHR: metric.restingHR ?? 55,
                peakHR: (metric.restingHR ?? 55) + 8,
                restingHR: metric.restingHR ?? 55,
                hrv: metric.hrv,
                hrvWindowCount: 8,
                respiratoryRate: metric.respiratoryRate,
                duration: metric.sleepDuration ?? end.timeIntervalSince(start),
                span: metric.sleepSpan ?? end.timeIntervalSince(start),
                reason: "App Review local demo data",
                motionSource: "demo_data",
                motionValidated: false,
                stageSegments: [],
                eventTimeZoneIdentifier: calendar.timeZone.identifier,
                sleepNeedSeconds: metric.sleepNeedSeconds
            )
        }
    }

    static func confirmedWorkouts(now: Date = Date(), calendar: Calendar = .current) -> [UserConfirmedWorkout] {
        let today = calendar.startOfDay(for: now)
        return (-12...(-1)).compactMap { offset -> UserConfirmedWorkout? in
            guard offset.isMultiple(of: 3) else { return nil }
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let start = calendar.date(byAdding: .minute, value: 17 * 60 + 40, to: day) ?? day
            let duration: TimeInterval = 38 * 60
            return UserConfirmedWorkout(
                id: "app-review-demo-workout-\(Int(day.timeIntervalSinceReferenceDate))",
                createdAt: now,
                start: start,
                end: start.addingTimeInterval(duration),
                label: "Demo workout",
                source: "app_review_demo",
                confidence: "demo_data",
                sessions: 1,
                samples: Int(duration / 30),
                avgHR: 132,
                peakHR: 153,
                p95HR: 148,
                p99HR: 152,
                thresholdHR: 142,
                streamCoveragePercent: 100,
                observedDuration: duration,
                reason: "App Review local demo data",
                activityType: "Cardio",
                strain: 9.4,
                strainCalibrationVersion: 1,
                activeEnergyKilocalories: 286,
                activeEnergyConfidence: "Demo data",
                eventTimeZoneIdentifier: calendar.timeZone.identifier
            )
        }
    }

    static func rollups(now: Date = Date(), calendar: Calendar = .current) -> [DailyRollupStoreEntry] {
        dailyMetrics(now: now, calendar: calendar).map { metric in
            DailyRollupStoreEntry(
                day: metric.day,
                recovery: metric.recoveryPercent,
                lnRMSSD: metric.hrv.map { log(Double($0)) },
                rhr: metric.restingHR,
                sleepSeconds: metric.sleepDuration,
                sleepNeedSeconds: metric.sleepNeedSeconds,
                sleepPerformance: metric.sleepDuration.map { Int(($0 / (8 * 60 * 60) * 100).rounded()) },
                bedtimeMinutes: 22 * 60 + 20,
                strain: metric.strain,
                strainCoverageFraction: metric.strainCoverageFraction,
                strainEvidenceQuality: metric.strainEvidenceQuality,
                respiratoryRate: metric.respiratoryRate,
                skinTemperatureDeviationCelsius: metric.skinTemperatureDeviationCelsius,
                calendar: calendar
            )
        }
    }
}
