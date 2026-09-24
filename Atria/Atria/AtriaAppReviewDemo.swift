import Foundation

/// A deliberately local, opt-in sample-data mode for App Review and first-run
/// exploration. It is not an account, never contacts a service, and never
/// requires a strap, Bluetooth permission, password, or network.
enum AtriaAppReviewDemo {
    static let activeKey = "atria.appReviewDemo.active.v1"
    static let bannerTitle = "Sample data"
    static let bannerDetail = "Demo data · not from a live strap"
    static let eraseAndReturnTitle = "Erase sample data and return to setup"
    static let exploreButtonTitle = "Explore sample data"
    static let horizonDays = 21
    /// Plausible "last motion" age shown by the Steps card's freshness badge
    /// in demo mode. Never claims literal live BLE motion (which demo mode
    /// never has); reads as a normal recent strap sync.
    static let demoMotionAge: TimeInterval = 4 * 60

    static var isActive: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }

    static func activate() {
        UserDefaults.standard.set(true, forKey: activeKey)
    }

    static func deactivate() {
        UserDefaults.standard.removeObject(forKey: activeKey)
    }

    /// Legacy nickname path is retained only so existing tests can name the
    /// retired trigger. First-run entry is the explicit Explore button.
    static let reviewerNickname = "App Review"
    static func isRequested(nickname: String) -> Bool {
        nickname.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == reviewerNickname.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func stepCount(on day: Date, now: Date = Date(), calendar: Calendar = .current) -> Int? {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: day)
        guard let offset = calendar.dateComponents([.day], from: start, to: today).day,
              offset >= 0, offset < horizonDays else { return nil }
        return 6_420 + (horizonDays - 1 - offset) * 173
    }

    static func activeEnergyKilocalories(on day: Date, now: Date = Date(), calendar: Calendar = .current) -> Double? {
        let today = calendar.startOfDay(for: now)
        let start = calendar.startOfDay(for: day)
        guard let offset = calendar.dateComponents([.day], from: start, to: today).day,
              offset >= 0, offset < horizonDays else { return nil }
        let base = 240.0 + Double((horizonDays - 1 - offset) % 5) * 38.0
        return hasWorkout(offset: -(horizonDays - 1 - offset) ) ? base + 220 : base
    }

    /// Small deterministic, rolling fixture: enough local history for every
    /// supported health surface to render without presenting sample data as live.
    static func sessions(now: Date = Date(), calendar: Calendar = .current) -> [SavedSession] {
        let today = calendar.startOfDay(for: now)
        var result: [SavedSession] = []

        for dayOffset in (-horizonDays)...(-1) {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            let nightStart = calendar.date(byAdding: .minute, value: 22 * 60 + 20, to: day) ?? day
            let nightDuration: TimeInterval = TimeInterval((7 * 60 + 25 + (dayOffset + horizonDays) % 4 * 8) * 60)
            let nightPoints = stride(from: 0.0, through: nightDuration, by: 300.0).enumerated().map { index, t in
                SavedSession.Point(t: t, bpm: 53 + ((index + dayOffset + 20) % 6))
            }
            result.append(SavedSession(
                id: UUID(), start: nightStart, end: nightStart.addingTimeInterval(nightDuration),
                label: bannerTitle, points: nightPoints, hrv: 58 + (dayOffset + horizonDays) % 7,
                respiratoryRate: 14.1, biologicalSex: .unspecified,
                kind: "demo_sleep", eventTimeZoneIdentifier: calendar.timeZone.identifier
            ))

            guard hasWorkout(offset: dayOffset) else { continue }
            let workoutStart = calendar.date(byAdding: .minute, value: 17 * 60 + 40, to: day) ?? day
            let workoutDuration: TimeInterval = 38 * 60
            let workoutPoints = stride(from: 0.0, through: workoutDuration, by: 30.0).enumerated().map { index, t in
                let wave = abs((index % 18) - 9)
                return SavedSession.Point(t: t, bpm: 108 + (9 - wave) * 5)
            }
            result.append(SavedSession(
                id: UUID(), start: workoutStart, end: workoutStart.addingTimeInterval(workoutDuration),
                label: bannerTitle, points: workoutPoints, hrv: nil,
                biologicalSex: .unspecified, kind: "demo_workout",
                eventTimeZoneIdentifier: calendar.timeZone.identifier
            ))
        }

        if let liveSession = liveDaySession(now: now, calendar: calendar) {
            result.append(liveSession)
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Continuous, plausible background heart-rate recording for the open
    /// "today" cycle, from this morning's wake boundary (same formula as
    /// `dailyMetrics(offset: 0)`, so the two never disagree) through `now`.
    /// Without this, live-cycle surfaces (Strain, day HR-wear coverage) have
    /// no evidence for the in-progress day and read as broken ("Day HR
    /// incomplete", strain stuck at 0.0) even though the prior `horizonDays`
    /// of history look fine. A few short elevated bouts stand in for normal
    /// daytime activity — never applied past `now`, since the loop below
    /// simply stops emitting points once it reaches `end`. Never touches
    /// Bluetooth: this is plain local fixture data.
    static func liveDaySession(now: Date = Date(), calendar: Calendar = .current) -> SavedSession? {
        let wake = todayWakeTime(now: now, calendar: calendar)
        guard now > wake else { return nil }
        // Bound to a sane single-day window even if the clock has drifted.
        let end = min(now, wake.addingTimeInterval(20 * 3600))
        guard end > wake else { return nil }

        let activityWindows: [(startMinute: Int, durationMinute: Int, peakBPM: Int)] = [
            (150, 28, 122),
            (330, 30, 128),
            (540, 20, 118)
        ]
        var points: [SavedSession.Point] = []
        var t: TimeInterval = 0
        // Wear-coverage union only bridges consecutive points whose gap is
        // within AtriaAnalytics.Strain.maximumLoadEvidenceGap (15s). The
        // once-per-5-minutes cadence used for past nights (where strain is a
        // precomputed static number, never recomputed from these points) is
        // far too sparse here: the OPEN "today" cycle's Strain and wear
        // coverage are computed live from this exact point union, so 5-minute
        // gaps collapsed observed coverage to a handful of isolated seconds
        // and left the Strain/Steps cards reading "Day HR incomplete" again.
        let step: TimeInterval = 10
        while wake.addingTimeInterval(t) <= end {
            let minute = Int(t / 60)
            // A resting-awake baseline clearly above the night fixture's
            // 53-59 bpm sleep range, with three overlapping periods so it
            // never holds still for long stretches — a flat, sleep-like
            // signal for 20+ minutes is exactly what the daytime-quiescence
            // detector reads as an unconfirmed nap candidate, which is not
            // demo data's job to manufacture.
            let slowDrift = sin(Double(minute) / 47.0) * 7
            let midWobble = sin(Double(minute) / 6.0) * 5
            let microJitter = sin(t / 23.0) * 3
            var bpm = 78 + Int(slowDrift + midWobble + microJitter)
            for window in activityWindows {
                let windowEnd = window.startMinute + window.durationMinute
                guard minute >= window.startMinute, minute <= windowEnd else { continue }
                let progress = Double(minute - window.startMinute) / Double(max(1, window.durationMinute))
                let shape = sin(progress * .pi)
                bpm = 78 + Int(Double(window.peakBPM - 78) * shape)
            }
            points.append(SavedSession.Point(t: t, bpm: max(60, min(150, bpm))))
            t += step
        }
        guard !points.isEmpty else { return nil }

        return SavedSession(
            id: UUID(), start: wake, end: end,
            label: bannerTitle, points: points, hrv: nil,
            respiratoryRate: 15.0, biologicalSex: .unspecified,
            kind: "demo_daytime", eventTimeZoneIdentifier: calendar.timeZone.identifier
        )
    }

    /// End of the fixture's most recent completed night — the wake boundary
    /// "today" starts from. Uses the identical duration formula as
    /// `dailyMetrics(offset: 0)` so the two never disagree about when today
    /// began.
    static func todayWakeTime(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let priorDay = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let nightStart = calendar.date(byAdding: .minute, value: 22 * 60 + 20, to: priorDay) ?? priorDay
        let nightDuration: TimeInterval = TimeInterval((7 * 60 + 25 + horizonDays % 4 * 8) * 60)
        return nightStart.addingTimeInterval(nightDuration)
    }

    static func dailyMetrics(now: Date = Date(), calendar: Calendar = .current) -> [SavedDailyMetric] {
        let today = calendar.startOfDay(for: now)
        return (-(horizonDays - 1)...0).compactMap { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let priorDay = calendar.date(byAdding: .day, value: -1, to: day) ?? day
            let sleepStart = calendar.date(byAdding: .minute, value: 22 * 60 + 20, to: priorDay) ?? priorDay
            let sleepDuration = TimeInterval((7 * 60 + 25 + (offset + horizonDays) % 4 * 8) * 60)
            let recovery = 68 + ((offset + horizonDays) * 3) % 19
            let strain = 7.8 + Double((offset + horizonDays) % 5) * 1.1
            let stages = sleepStages(start: sleepStart, duration: sleepDuration, offset: offset)
            return SavedDailyMetric(
                day: day,
                recoveryPercent: recovery,
                recoveryConfidence: bannerTitle,
                hrv: 58 + (offset + horizonDays) % 7,
                restingHR: 54 + (offset + horizonDays) % 3,
                respiratoryRate: 14.1 + Double((offset + horizonDays) % 3) * 0.1,
                sleepDuration: sleepDuration,
                sleepNeedSeconds: 8 * 60 * 60,
                sleepSpan: sleepDuration + 12 * 60,
                sleepStart: sleepStart,
                sleepEnd: sleepStart.addingTimeInterval(sleepDuration + 12 * 60),
                sleepSource: bannerDetail,
                sleepStageSegments: stages,
                sleepConsistencyPercent: 86 + (offset + horizonDays) % 8,
                strain: strain,
                strainCoverageFraction: 1,
                strainEvidenceQuality: .exact,
                dayTRIMP: 48 + Double((offset + horizonDays) % 6) * 4,
                skinTemperatureDeviationCelsius: nil
            )
        }.sorted { $0.day > $1.day }
    }

    static func confirmedSleeps(now: Date = Date(), calendar: Calendar = .current) -> [UserConfirmedSleep] {
        dailyMetrics(now: now, calendar: calendar).map { metric in
            let start = metric.sleepStart ?? metric.day.addingTimeInterval(-8 * 60 * 60)
            let end = metric.sleepEnd ?? metric.day
            let duration = metric.sleepDuration ?? end.timeIntervalSince(start)
            return UserConfirmedSleep(
                id: "app-review-demo-sleep-\(Int(metric.day.timeIntervalSinceReferenceDate))",
                createdAt: now,
                start: start,
                end: end,
                source: "manual_sleep",
                confidence: "demo_data",
                sessions: 1,
                samples: Int(duration) / 300,
                avgHR: metric.restingHR ?? 55,
                peakHR: (metric.restingHR ?? 55) + 8,
                restingHR: metric.restingHR ?? 55,
                hrv: metric.hrv,
                hrvWindowCount: 8,
                respiratoryRate: metric.respiratoryRate,
                duration: duration,
                span: metric.sleepSpan ?? end.timeIntervalSince(start),
                reason: bannerDetail,
                motionSource: "demo_data",
                motionValidated: false,
                stageSegments: metric.sleepStageSegments,
                eventTimeZoneIdentifier: calendar.timeZone.identifier,
                sleepNeedSeconds: metric.sleepNeedSeconds
            )
        }
    }

    static func confirmedWorkouts(now: Date = Date(), calendar: Calendar = .current) -> [UserConfirmedWorkout] {
        let today = calendar.startOfDay(for: now)
        return (-(horizonDays - 1)...(-1)).compactMap { offset -> UserConfirmedWorkout? in
            guard hasWorkout(offset: offset) else { return nil }
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let start = calendar.date(byAdding: .minute, value: 17 * 60 + 40, to: day) ?? day
            let duration: TimeInterval = 38 * 60
            return UserConfirmedWorkout(
                id: "app-review-demo-workout-\(Int(day.timeIntervalSinceReferenceDate))",
                createdAt: now,
                start: start,
                end: start.addingTimeInterval(duration),
                label: bannerTitle,
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
                reason: bannerDetail,
                activityType: "Cardio",
                strain: 9.4,
                strainCalibrationVersion: 1,
                activeEnergyKilocalories: 286,
                activeEnergyConfidence: bannerTitle,
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
                trimp: metric.dayTRIMP,
                respiratoryRate: metric.respiratoryRate,
                skinTemperatureDeviationCelsius: nil,
                vitals: DailyRollupVitals(
                    rhr: metric.restingHR.map { DailyRollupVitals.Stat(mean: Double($0), sd: 1.2, n: 8) },
                    hrv: metric.hrv.map { DailyRollupVitals.Stat(mean: Double($0), sd: 3.4, n: 8) },
                    resp: metric.respiratoryRate.map { DailyRollupVitals.Stat(mean: $0, sd: 0.2, n: 8) }
                ),
                calendar: calendar
            )
        }
    }

    static func journalEntries(now: Date = Date(), calendar: Calendar = .current) -> [BehaviorJournalEntry] {
        let today = calendar.startOfDay(for: now)
        return (-6...0).compactMap { offset -> BehaviorJournalEntry? in
            let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            var tags: [BehaviorJournalEntry.Tag] = [.sleep, .hydration]
            if offset.isMultiple(of: 2) { tags.append(.training) }
            if offset == -1 { tags.append(.caffeine) }
            if offset == -3 { tags.append(.stress) }
            return BehaviorJournalEntry(
                id: "app-review-demo-journal-\(Int(day.timeIntervalSinceReferenceDate))",
                day: day,
                createdAt: now,
                tags: tags
            )
        }
    }

    struct SurfaceCoverage: Equatable {
        var today: Bool
        var recovery: Bool
        var hrv: Bool
        var restingHR: Bool
        var respiratoryRate: Bool
        var sleep: Bool
        var sleepStages: Bool
        var strain: Bool
        var workouts: Bool
        var steps: Bool
        var calories: Bool
        var journal: Bool
        var weeklyPlan: Bool
        var trends: Bool
        var charts: Bool
        var skinTemperatureAbsent: Bool
        var spo2Absent: Bool

        var isComplete: Bool {
            today && recovery && hrv && restingHR && respiratoryRate && sleep
                && sleepStages && strain && workouts && steps && calories
                && journal && weeklyPlan && trends && charts
                && skinTemperatureAbsent && spo2Absent
        }
    }

    static func surfaceCoverage(now: Date = Date(), calendar: Calendar = .current) -> SurfaceCoverage {
        let metrics = dailyMetrics(now: now, calendar: calendar)
        let sleeps = confirmedSleeps(now: now, calendar: calendar)
        let workouts = confirmedWorkouts(now: now, calendar: calendar)
        let rollups = rollups(now: now, calendar: calendar)
        let sessions = sessions(now: now, calendar: calendar)
        let journal = journalEntries(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return SurfaceCoverage(
            today: metrics.contains { calendar.isDate($0.day, inSameDayAs: today) },
            recovery: metrics.contains { $0.recoveryPercent != nil },
            hrv: metrics.contains { $0.hrv != nil },
            restingHR: metrics.contains { $0.restingHR != nil },
            respiratoryRate: metrics.contains { $0.respiratoryRate != nil },
            sleep: sleeps.count == horizonDays,
            sleepStages: sleeps.contains { ($0.stageSegments ?? []).isEmpty == false },
            strain: metrics.contains { $0.strain != nil },
            workouts: workouts.count >= 6,
            steps: stepCount(on: today, now: now, calendar: calendar) != nil,
            calories: workouts.contains { ($0.activeEnergyKilocalories ?? 0) > 0 },
            journal: journal.count >= 7,
            weeklyPlan: rollups.filter { ($0.strain ?? 0) > 0 }.count >= 7,
            trends: rollups.count >= 14,
            charts: sessions.contains { $0.points.count >= 8 },
            skinTemperatureAbsent: metrics.allSatisfy { $0.skinTemperatureDeviationCelsius == nil }
                && rollups.allSatisfy { $0.skinTemperatureDeviationCelsius == nil },
            spo2Absent: true
        )
    }

    private static func hasWorkout(offset: Int) -> Bool {
        offset.isMultiple(of: 3)
    }

    private static func sleepStages(start: Date, duration: TimeInterval, offset: Int) -> [SleepStageSegment] {
        let plan: [(SleepStageKind, TimeInterval)] = [
            (.awake, 8 * 60),
            (.light, 42 * 60),
            (.deep, 58 * 60),
            (.light, 28 * 60),
            (.rem, 46 * 60),
            (.light, 36 * 60),
            (.deep, 40 * 60),
            (.rem, 38 * 60),
            (.light, 24 * 60)
        ]
        var cursor: TimeInterval = 0
        var segments: [SleepStageSegment] = []
        var index = 0
        while cursor + 60 < duration {
            let item = index < plan.count ? plan[index] : (.light, 20 * 60)
            let remaining = duration - cursor
            let slice = min(item.1, remaining)
            let segmentStart = start.addingTimeInterval(cursor)
            segments.append(SleepStageSegment(
                id: "\(SleepStageSegment.hrEstimateIDPrefix)demo-\(offset)-\(index)",
                start: segmentStart,
                end: segmentStart.addingTimeInterval(slice),
                stage: item.0
            ))
            cursor += slice
            index += 1
        }
        return segments
    }
}
