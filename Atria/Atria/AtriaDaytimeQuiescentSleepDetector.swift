import Foundation

/// Review-only detection of a DAYTIME main sleep from motion quiescence,
/// corroborated by depressed heart rate.
///
/// WHY. The owner sleeps in the afternoon. Two consecutive real sleeps
/// (26 Aug 13:00-20:30 at 0.73 ticks/min, 27 Aug 15:00-20:00 at 1.40) produced
/// an EMPTY candidate pool — "No sleep candidates proposed at all" — because a
/// 4-5 h daytime sleep is too long for the 3 h nap lane, outside the overnight
/// lane's hours, and (with capture holes) under the 5 h clock-free HR-only
/// lane. Motion coverage was 100% across both sleeps even where HR capture had
/// a 57-minute hole, so motion carries the case.
///
/// HONESTY DESIGN, per adversarial review (each gate blocks a named
/// fabrication):
///  - candidates come from `AtriaSleepMotionQuiescence.quiescentWindows` with
///    its MEASURED parameters — never a hand-rolled whole-span mean, which
///    would launder undrained gaps into credited sleep;
///  - duration credits OBSERVED QUIET TIME only, never the wall span;
///  - a hard HR-PRESENCE floor (a strap face-up on a table records motion rows
///    with zero ticks and zero accepted HR — off-wrist HR is withheld at
///    decode and nothing else in production surfaces wear state);
///  - a hard HR-DEPRESSION gate against the surrounding awake hours (a still
///    passenger in a car is quiet-wristed at awake HR; the repo already
///    burned once on soft HR gates producing false "Sleep detected" cards);
///  - REVIEW-ONLY: the output is an unconfirmed Night surfaced through the
///    existing pending-review card. It never auto-confirms and never touches
///    recovery, the cycle boundary, or steps until the wearer confirms.
enum AtriaDaytimeQuiescentSleepDetector {

    static let sourceName = "daytime_quiescence_review"
    /// The nap lane owns anything up to three hours; this lane begins
    /// STRICTLY above it.
    static let minimumSpanSeconds: TimeInterval = 3 * 3_600 + 60
    static let maximumSpanSeconds: TimeInterval = 10 * 3_600
    /// Quiescent windows closer than this stitch into one candidate — sized to
    /// the measured 57-minute mid-sleep capture hole.
    static let stitchGapSeconds: TimeInterval = 60 * 60
    /// Observed quiet time must cover at least this fraction of the span.
    static let minimumQuietCoverage = 0.7
    /// Candidate must START in the daytime band (the overnight lanes own the
    /// night); local hours, inclusive.
    static let daytimeStartHours = 10...19
    /// At least this fraction of quiet minutes must carry accepted HR.
    static let minimumHRPresence = 0.25
    /// Low-battery capture-outage tier: when the strap's battery shuts HR off
    /// mid-window (device-measured 2026-08-27: HR present only 19:37–20:11 of
    /// a real 15:28–20:12 sleep, presence 0.12, while motion recorded all 284
    /// minutes), presence below `minimumHRPresence` is still admissible IF the
    /// observed HR spans at least this many minutes AND motion quiet clears
    /// the stricter `lowCaptureMinimumQuietCoverage`. The depression gate
    /// below stays hard either way — a table strap re-worn at the end reads
    /// awake-level in its tail and still dies there, and an awake worn wrist
    /// cannot produce the quiet chain in the first place.
    static let lowCaptureMinimumHRMinutes = 20
    static let lowCaptureMinimumQuietCoverage = 0.9
    /// Surrounding awake mean must exceed the in-window mean by this much.
    static let minimumHRDepressionBPM = 8.0
    /// Fewer surrounding HR minutes than this is "unknown", and unknown
    /// refuses — a sleep bracketed by capture void waits for the drain, which
    /// re-runs detection when rows land.
    static let minimumSurroundHRMinutes = 30
    /// Sustained device use at least this long trims/vetoes; a 2-minute
    /// mid-sleep phone check must not.
    static let sustainedUseMinimumSeconds: TimeInterval = 10 * 60

    struct Candidate: Equatable {
        let start: Date
        let end: Date
        /// Observed quiet seconds — what `duration` credits. Never wall span.
        let observedQuietSeconds: TimeInterval
        let meanInWindowHR: Double
        let meanSurroundHR: Double
        let restingHR: Int
        let quietCoverage: Double

        var window: DateInterval { DateInterval(start: start, end: end) }

        /// Stable identity: 5-minute-rounded bounds, so re-detection after
        /// each drain dedupes in the pending store AND in the notification
        /// start-debounce instead of thrashing either.
        func evidenceFingerprint(strapIdentifier: String) -> String {
            func r5(_ d: Date) -> Int {
                Int((d.timeIntervalSince1970 / 300).rounded()) * 300
            }
            return "daytime_quiescence|\(r5(start))|\(r5(end))|\(strapIdentifier.uppercased())"
        }
    }

    // MARK: - Minute adapter

    /// Compact-store points → quiescence-core minutes.
    ///
    /// NOT `AtriaUnattributedMotionRuns.minuteTickTotals`: that adapter guards
    /// `delta > 0`, which drops zero-advance pairs — the quiet minutes of the
    /// sleep itself would vanish and read as uncovered, erasing the very thing
    /// being hunted. This one emits zero-tick minutes WITH their covered
    /// seconds.
    static func minutes(
        _ points: [AtriaWhoop4MotionTickCompactStore.Point]
    ) -> [AtriaSleepMotionQuiescence.Minute] {
        var ticks: [Int: Int] = [:]
        var covered: [Int: TimeInterval] = [:]
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        for (before, after) in zip(ordered, ordered.dropFirst()) {
            let duration = after.timestamp - before.timestamp
            guard duration > 0, duration <= 90 else { continue }
            let bucket = Int(before.timestamp / 60)
            covered[bucket, default: 0] += min(duration, 60)
            let delta = after.tick >= before.tick
                ? after.tick - before.tick
                : after.tick + 65_536 - before.tick
            if delta > 0, Double(delta) <= max(12, duration * 12) {
                ticks[bucket, default: 0] += delta
            } else {
                ticks[bucket, default: 0] += 0
            }
        }
        return covered.keys.sorted().map { bucket in
            AtriaSleepMotionQuiescence.Minute(
                start: Date(timeIntervalSince1970: Double(bucket) * 60),
                ticks: ticks[bucket] ?? 0,
                coveredSeconds: min(covered[bucket] ?? 0, 60)
            )
        }
    }

    // MARK: - Detection

    /// `hrMinutesByBucket`: epoch-minute → mean accepted-HR bpm.
    /// `excluded`: confirmed sleeps AND workouts — a quiescent window touching
    /// any of them is dropped whole (window-granularity trim), which also
    /// closes the inner-nap hole where the store's 0.70 record-fraction
    /// suppression cannot.
    static func detect(
        points: [AtriaWhoop4MotionTickCompactStore.Point],
        hrMinutesByBucket: [Int: Double],
        excluded: [DateInterval],
        sustainedDeviceUse: [DateInterval],
        now: Date,
        calendar: Calendar = .current
    ) -> Candidate? {
        let allMinutes = minutes(points)
        guard !allMinutes.isEmpty else { return nil }
        let windows = AtriaSleepMotionQuiescence
            .quiescentWindows(minutes: allMinutes)
            .filter { window in
                window.interval.end > now.addingTimeInterval(-26 * 3_600)
                    && !excluded.contains {
                        window.interval.intersects($0)
                            && (window.interval.intersection(with: $0)?.duration ?? 0) > 60
                    }
                    && !sustainedDeviceUse.contains {
                        $0.duration >= sustainedUseMinimumSeconds
                            && window.interval.intersects($0)
                            && (window.interval.intersection(with: $0)?.duration ?? 0)
                                >= sustainedUseMinimumSeconds
                    }
            }
        guard !windows.isEmpty else { return nil }

        // Stitch neighbouring quiet windows across bounded capture holes.
        var chains: [[AtriaSleepMotionQuiescence.Window]] = [[windows[0]]]
        for window in windows.dropFirst() {
            if window.interval.start.timeIntervalSince(
                chains[chains.count - 1].last!.interval.end
            ) <= stitchGapSeconds {
                chains[chains.count - 1].append(window)
            } else {
                chains.append([window])
            }
        }

        var best: Candidate?
        for chain in chains {
            guard let first = chain.first, let last = chain.last else { continue }
            let start = first.interval.start
            let end = last.interval.end
            let span = end.timeIntervalSince(start)
            guard span > minimumSpanSeconds, span <= maximumSpanSeconds else { continue }
            guard daytimeStartHours.contains(
                calendar.component(.hour, from: start)
            ) else { continue }
            let quiet = chain.reduce(0.0) { $0 + $1.interval.duration }
            let coverage = quiet / span
            guard coverage >= minimumQuietCoverage else { continue }

            // HR gates — both HARD.
            let quietBuckets: [Int] = chain.flatMap { window -> [Int] in
                let lo = Int(window.interval.start.timeIntervalSince1970 / 60)
                let hi = Int(window.interval.end.timeIntervalSince1970 / 60)
                return Array(lo..<hi)
            }
            let inWindowHR = quietBuckets.compactMap { hrMinutesByBucket[$0] }
            guard !inWindowHR.isEmpty else { continue }
            let presence = Double(inWindowHR.count) / Double(max(quietBuckets.count, 1))
            if presence < minimumHRPresence {
                // Capture-outage tier: thin HR is admissible only with a
                // meaningful observed span and near-total motion quiet; the
                // hard depression gate below applies unchanged.
                guard inWindowHR.count >= lowCaptureMinimumHRMinutes,
                      coverage >= lowCaptureMinimumQuietCoverage else { continue }
            }

            let surroundBuckets =
                Array(Int(start.timeIntervalSince1970 / 60 - 180)
                      ..< Int(start.timeIntervalSince1970 / 60))
                + Array(Int(end.timeIntervalSince1970 / 60)
                        ..< Int(end.timeIntervalSince1970 / 60 + 180))
            let surroundHR = surroundBuckets
                .filter { !quietBuckets.contains($0) }
                .compactMap { hrMinutesByBucket[$0] }
            guard surroundHR.count >= minimumSurroundHRMinutes else { continue }

            let inMean = inWindowHR.reduce(0, +) / Double(inWindowHR.count)
            let surroundMean = surroundHR.reduce(0, +) / Double(surroundHR.count)
            guard surroundMean - inMean >= minimumHRDepressionBPM else { continue }

            let resting = Int(
                inWindowHR.sorted().prefix(10)
                    .reduce(0, +) / Double(min(inWindowHR.count, 10))
            )
            let candidate = Candidate(start: start,
                                      end: end,
                                      observedQuietSeconds: quiet,
                                      meanInWindowHR: inMean,
                                      meanSurroundHR: surroundMean,
                                      restingHR: resting,
                                      quietCoverage: coverage)
            if best == nil
                || candidate.observedQuietSeconds > best!.observedQuietSeconds {
                best = candidate
            }
        }
        return best
    }

    /// The review-only Night the pending store carries to the card.
    static func night(
        for candidate: Candidate,
        calendar: Calendar = .current,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(
            id: "sleep-review-\(Int(candidate.start.timeIntervalSince1970))-"
                + "\(Int(candidate.end.timeIntervalSince1970))-daytime_quiescence",
            day: calendar.startOfDay(for: candidate.start),
            start: candidate.start,
            end: candidate.end,
            // Observed quiet time, never the wall span.
            duration: candidate.observedQuietSeconds,
            restingHR: candidate.restingHR,
            hrv: nil,
            respiratoryRate: nil,
            sleepEfficiency: nil,
            confidence: "review_needed",
            source: sourceName,
            confirmed: false,
            stageSegments: [],
            eventTimeZoneIdentifier: timeZoneIdentifier
        )
    }
}
