import Foundation

/// Wrist-motion quiescence: separating sleep from *sedentary* wake.
///
/// PURE CORE, DELIBERATELY UNWIRED. Nothing calls this yet. The rule below is
/// measured on four days of the owner's own drained history and reproduces the
/// confirmed sleeps with zero false positives on confirmed workouts, but four
/// days is not enough evidence to move a detector the owner is satisfied with.
/// Wiring is a separate, deliberate step.
///
/// ## Why not stillness fraction
///
/// The obvious feature — the fraction of minutes with no wrist motion — does
/// **not** separate these two states for this wearer:
///
/// | state                | stillness fraction | mean ticks/min |
/// |----------------------|--------------------|----------------|
/// | awake, sedentary     | 0.76 – 0.83        |  8.2 – 12.3    |
/// | asleep (confirmed)   | 0.91 – 1.00        |  0.05 – 0.80   |
/// | workout (confirmed)  | 0.15               | 66.1           |
///
/// A sedentary baseline of 0.76–0.83 against sleep's 0.91–1.00 leaves no safe
/// threshold: tight rules (≥0.90) fragment a night into 2–3 h pieces, loose
/// ones (≥0.70) chain sedentary wake into 16–17 h "sleeps", and hysteresis
/// between them inherits the loose bound's over-extension.
///
/// **Mean tick rate separates by 10× with no overlap**, and the resulting
/// detector is almost insensitive to its own parameters — recall moved only
/// 78%→79% across window sizes 20–45 min, quiet bounds 1.5–3.0 ticks/min, and
/// join gaps 15–30 min, with FP-on-workout pinned at 0 throughout. That
/// insensitivity is the reason to trust the feature rather than the constants.
///
/// The counter is silent at rest (the counted physical corpus recorded
/// "preceding 60-second rest delta = 0 ticks"), which is what makes quiet
/// *informative* here rather than merely absent.
///
/// ## Missing data is never quiet
///
/// Absence in the compact shards means "not drained", never "not worn" — on
/// 2026-08-23 an 8.26 h span held no motion rows while `sessions.json` showed
/// HR streaming through it (`hrAccepted` 8,525 then 4,248). A rolling window is
/// therefore evaluated only when enough of its minutes are actually covered;
/// uncovered minutes are absent, not still, and can never manufacture a window.
///
/// ## What this does NOT do: it does not assemble nights
///
/// It reports the quiet spans it measured. It does not stitch them into sleeps,
/// and it deliberately performs no merging, because every merge rule tried on
/// the real days chained transitively: bridging windows even 5 wall-clock
/// minutes apart produced an 8.62 h span on 2026-08-23, and 45 minutes produced
/// 13.65 h. Scattered daytime quiescence is common enough that "close together"
/// is not evidence of "the same sleep".
///
/// So a night broken by a long arousal is reported as two adjacent windows, and
/// that is the honest output. Deciding they are one sleep needs HR and the
/// wearer's own confirmation — a different job, for a caller that has both.
enum AtriaSleepMotionQuiescence {

    /// One minute of drained wrist motion.
    struct Minute: Equatable {
        /// Start of the minute, floored to a minute boundary by the caller.
        let start: Date
        /// Strap counter advance credited to this minute.
        let ticks: Int
        /// Seconds of this minute actually spanned by stored rows.
        let coveredSeconds: TimeInterval

        init(start: Date, ticks: Int, coveredSeconds: TimeInterval) {
            self.start = start
            self.ticks = ticks
            self.coveredSeconds = coveredSeconds
        }
    }

    /// A contiguous span the wrist stayed quiet enough to be sleep.
    struct Window: Equatable {
        let interval: DateInterval
        /// Mean strap ticks per covered minute across the whole window.
        let meanTicksPerMinute: Double
        /// Longest unbroken run of quiet minutes inside it. Confirmed sleeps
        /// ran 87–193 min here; sedentary wake never exceeded 56.
        let longestQuietRunMinutes: Int
        /// Covered minutes ÷ elapsed minutes. Reported, never used to reject —
        /// the caller decides what coverage it will accept.
        let coverageFraction: Double
    }

    struct Parameters: Equatable {
        /// Width of the rolling mean.
        var rollingWindowMinutes: Int
        /// A rolling mean at or below this is quiet. Sedentary wake sat at
        /// 8.2–12.3; confirmed sleep at 0.05–0.80.
        var quietTicksPerMinute: Double
        /// Tolerance between quiet *anchors*, not between arousals. An arousal
        /// poisons every rolling window containing enough of it, so it costs up
        /// to `rollingWindowMinutes` of anchors on each side; a 6-minute arousal
        /// under a 30-minute window opens a ~34-minute anchor gap and therefore
        /// splits. That is deliberate — see the type's "what this does not do".
        ///
        /// Do not widen this to bridge arousals. Measured on the real days,
        /// raising it walks the longest window 6.53 h → 8.62 h (45) → 11.83 h
        /// (60) → 17.53 h (120), because scattered daytime quiet also produces
        /// anchors and a wider gap chains them into the night.
        var joinGapMinutes: Int
        /// Shorter spans are not reported as sleep by this core.
        var minimumWindowMinutes: Int
        /// Fraction of a rolling window that must be covered before it is
        /// scored at all.
        var minimumRollingCoverageFraction: Double
        /// A minute counts as covered at or above this many seconds of rows.
        var minimumCoveredSecondsPerMinute: TimeInterval
        /// A minute is "quiet" for run-length purposes at or below this.
        var quietMinuteTickCeiling: Int

        /// The configuration measured against the owner's confirmed sleeps and
        /// workouts on 2026-08-22…25. Every neighbouring setting scored within
        /// one point of it.
        static let measured = Parameters(
            rollingWindowMinutes: 30,
            quietTicksPerMinute: 2.0,
            joinGapMinutes: 20,
            minimumWindowMinutes: 90,
            minimumRollingCoverageFraction: 0.8,
            minimumCoveredSecondsPerMinute: 30,
            quietMinuteTickCeiling: 2
        )
    }

    /// Quiescent spans, oldest first, never overlapping.
    ///
    /// Deterministic and side-effect free: same minutes in, same windows out.
    static func quiescentWindows(
        minutes: [Minute],
        parameters: Parameters = .measured
    ) -> [Window] {
        guard parameters.rollingWindowMinutes > 0,
              parameters.minimumWindowMinutes > 0 else { return [] }

        // Index the covered minutes by their minute bucket. Uncovered minutes
        // are dropped here and can never re-enter as stillness.
        var ticksByBucket: [Int: Int] = [:]
        for minute in minutes
        where minute.coveredSeconds >= parameters.minimumCoveredSecondsPerMinute {
            let bucket = Int((minute.start.timeIntervalSince1970 / 60).rounded(.down))
            // Last write wins only if the caller passed duplicates; sum instead
            // so a split minute is not silently halved.
            ticksByBucket[bucket, default: 0] += max(0, minute.ticks)
        }
        guard !ticksByBucket.isEmpty else { return [] }

        let ordered = ticksByBucket.keys.sorted()
        let span = parameters.rollingWindowMinutes
        let required = max(1, Int(Double(span) * parameters.minimumRollingCoverageFraction))

        // Anchors: the start bucket of every rolling window that is both
        // sufficiently covered and quiet.
        var anchors: [Int] = []
        for bucket in ordered {
            var present = 0
            var total = 0
            for offset in 0..<span {
                guard let ticks = ticksByBucket[bucket + offset] else { continue }
                present += 1
                total += ticks
            }
            guard present >= required else { continue }
            let mean = Double(total) / Double(present)
            if mean <= parameters.quietTicksPerMinute { anchors.append(bucket) }
        }
        guard !anchors.isEmpty else { return [] }

        // Join anchors separated by no more than the arousal tolerance.
        var runs: [(first: Int, last: Int)] = []
        var first = anchors[0]
        var previous = anchors[0]
        for anchor in anchors.dropFirst() {
            if anchor - previous > parameters.joinGapMinutes {
                runs.append((first, previous))
                first = anchor
            }
            previous = anchor
        }
        runs.append((first, previous))

        // Extents, clamped to real data.
        //
        // The rule *looked* as far as `run.last + span`, but an anchor is
        // admitted with only `required` of `span` buckets present, so that
        // reach can end in minutes that hold no rows at all — exactly the shape
        // at the trailing edge of a drain. Reporting to the reach would present
        // never-drained time as quiescent, and worse, that invented tail could
        // be the only reason a window cleared `minimumWindowMinutes` (84
        // covered minutes reported a 90-minute window; 83 reported nothing).
        // The interval therefore ends at the last minute that actually holds
        // rows. `run.first` is always covered — anchors are drawn from covered
        // buckets — so only the tail needed clamping.
        // ORDER MATTERS. The overlap clamp below assigns an end from the NEXT
        // run's first anchor, which is not guaranteed to be a covered bucket —
        // so it must run BEFORE the tail clamp, never after. Running it second
        // silently re-extended a window past the last drained minute and undid
        // this fix entirely: 80 quiet minutes, a 29-minute active stretch whose
        // last two minutes held no rows, then quiet, produced a 91-minute
        // window backed by only 89 drained minutes — one that existed solely
        // because of the two undrained ones.
        var extents: [(start: Int, end: Int)] = runs.map { ($0.first, $0.last + span) }

        // Splitting on the anchor gap while extending each end by `span` let
        // consecutive extents collide whenever that gap fell in
        // `(joinGapMinutes, span]` — an ordinary short arousal — so the same
        // minutes were reported inside two windows and double-counted by
        // `overlapFraction`. Hand the shared minutes to the later window, which
        // is the one whose anchors actually reach them.
        for index in extents.indices.dropLast() {
            extents[index].end = min(extents[index].end, extents[index + 1].start)
        }

        // Now clamp to real data, LAST, so nothing can re-extend past it.
        //
        // The rule *looked* as far as `run.last + span`, but an anchor is
        // admitted with only `required` of `span` buckets present, so that
        // reach can end in minutes that hold no rows at all — exactly the shape
        // at the trailing edge of a drain. Reporting to the reach would present
        // never-drained time as quiescent, and worse, that invented tail could
        // be the only reason a window cleared `minimumWindowMinutes` (84
        // covered minutes reported a 90-minute window; 83 reported nothing).
        // `run.first` is always covered — anchors are drawn from covered
        // buckets — so only the tail needs clamping.
        extents = extents.compactMap { extent in
            var bucket = extent.end - 1
            while bucket >= extent.start {
                if ticksByBucket[bucket] != nil { return (extent.start, bucket + 1) }
                bucket -= 1
            }
            return nil
        }

        return extents.compactMap { extent -> Window? in
            let startBucket = extent.start
            let endBucket = extent.end
            let elapsed = endBucket - startBucket
            guard elapsed >= parameters.minimumWindowMinutes else { return nil }

            var covered = 0
            var total = 0
            var longestRun = 0
            var currentRun = 0
            for bucket in startBucket..<endBucket {
                guard let ticks = ticksByBucket[bucket] else {
                    currentRun = 0
                    continue
                }
                covered += 1
                total += ticks
                if ticks <= parameters.quietMinuteTickCeiling {
                    currentRun += 1
                    longestRun = max(longestRun, currentRun)
                } else {
                    currentRun = 0
                }
            }
            guard covered > 0 else { return nil }

            return Window(
                interval: DateInterval(
                    start: Date(timeIntervalSince1970: Double(startBucket) * 60),
                    end: Date(timeIntervalSince1970: Double(endBucket) * 60)
                ),
                meanTicksPerMinute: Double(total) / Double(covered),
                longestQuietRunMinutes: longestRun,
                coverageFraction: Double(covered) / Double(elapsed)
            )
        }
    }

    /// What the wrist says about a cycle the record calls "no sleep".
    ///
    /// `AtriaPhysiologicalCycle` rolls a new day 24 h after the last one began
    /// when no sleep arrives to rotate it, which keeps an all-nighter bounded
    /// and is correct. What it cannot do is tell WHY there is no sleep: a
    /// genuine night awake and a night the detector missed produce the same
    /// `.noSleepFallback`, the same withheld recovery, and the same "No sleep
    /// recorded in this cycle".
    ///
    /// Motion separates them. On 2026-08-24 the record said no sleep across
    /// 05:32→06:02 next day while the wrist was quiet for 6.53 h at 0.37
    /// ticks/min — a contradiction the app had no way to notice.
    enum NoSleepAssessment: Equatable {
        /// The wrist was active across the span. The record and the evidence
        /// agree: this really was a night awake.
        case supported
        /// A long unexplained quiet block sits inside the cycle. The record
        /// says no sleep; the wrist disagrees.
        case contradicted(longest: Window)
        /// Too little drained motion inside the cycle to say either way.
        /// Explicitly NOT `supported` — absent evidence is not evidence.
        case unverifiable
    }

    /// Fraction of `cycle` that must hold rows before motion may speak at all.
    static let minimumAssessmentCoverage = 0.5

    static func assessNoSleepCycle(
        _ cycle: DateInterval,
        minutes: [Minute],
        confirmedSleeps: [DateInterval] = [],
        parameters: Parameters = .measured
    ) -> NoSleepAssessment {
        guard cycle.duration > 0 else { return .unverifiable }

        let inside = minutes.filter {
            cycle.contains($0.start)
                && $0.coveredSeconds >= parameters.minimumCoveredSecondsPerMinute
        }
        let elapsedMinutes = cycle.duration / 60
        guard elapsedMinutes > 0,
              Double(inside.count) / elapsedMinutes >= minimumAssessmentCoverage else {
            // A cycle that was barely drained cannot testify. Saying
            // "supported" here would turn missing history into a confirmed
            // all-nighter, which is the exact failure this is meant to catch.
            return .unverifiable
        }

        let unexplained = unexplainedWindows(
            quiescentWindows(minutes: inside, parameters: parameters),
            explainedBy: confirmedSleeps
        )
        guard let longest = unexplained.max(by: {
            $0.interval.duration < $1.interval.duration
        }) else {
            return .supported
        }
        return .contradicted(longest: longest)
    }

    /// Seconds of `interval` covered by `others`, counting shared time once.
    private static func unionOverlapSeconds(
        of interval: DateInterval,
        with others: [DateInterval]
    ) -> TimeInterval {
        let pieces = others
            .compactMap { interval.intersection(with: $0) }
            .filter { $0.duration > 0 }
            .sorted { $0.start < $1.start }
        guard !pieces.isEmpty else { return 0 }

        var total: TimeInterval = 0
        var currentStart = pieces[0].start
        var currentEnd = pieces[0].end
        for piece in pieces.dropFirst() {
            if piece.start > currentEnd {
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = piece.start
                currentEnd = piece.end
            } else if piece.end > currentEnd {
                currentEnd = piece.end
            }
        }
        return total + currentEnd.timeIntervalSince(currentStart)
    }

    /// Quiescent windows the confirmed record does not already account for.
    ///
    /// This is the question that decides whether motion has anything to SAY —
    /// not whether it should overrule anything. A window the wearer has already
    /// confirmed as sleep is not news; a long quiet window with no confirmed
    /// sleep across it is.
    ///
    /// On the owner's 2026-08-22…25 data this returns 4 of the 7 windows. The
    /// three it suppresses are the ones a confirmed sleep already covers (78%,
    /// 57% and 100% explained). The four it surfaces include the 6.53 h block
    /// on 08-24 12:18→18:50
    /// whose absence left the physiological cycle reporting a 24.5 h day with
    /// `boundaryKind == .noSleepFallback` — "no sleep happened" — across a span
    /// containing six and a half hours of it.
    ///
    /// Deliberately conservative: `minimumExplainedFraction` is the share of the
    /// WINDOW that must already be covered before it counts as accounted for, so
    /// a brief confirmed nap overlapping the edge of a long quiet block does not
    /// suppress the block.
    static func unexplainedWindows(
        _ windows: [Window],
        explainedBy confirmed: [DateInterval],
        minimumExplainedFraction: Double = 0.5
    ) -> [Window] {
        guard !confirmed.isEmpty else { return windows }
        return windows.filter { window in
            guard window.interval.duration > 0 else { return false }
            let covered = unionOverlapSeconds(of: window.interval, with: confirmed)
            return covered / window.interval.duration < minimumExplainedFraction
        }
    }

    /// How strongly a quiescent window corroborates a candidate sleep span.
    ///
    /// Overlap alone is not enough: a long sedentary evening can overlap a
    /// candidate without being sleep. This asks that the *candidate's* own
    /// minutes were quiet, which is the claim being corroborated.
    static func overlapFraction(
        of candidate: DateInterval,
        coveredBy windows: [Window]
    ) -> Double {
        guard candidate.duration > 0 else { return 0 }

        // Union first. Summing per-window intersections double-counts any
        // region two windows share, and clamping the result to 1 hides the
        // excess as a saturated "fully corroborated" instead of exposing it.
        // `quiescentWindows` no longer emits overlapping windows, but this is
        // a public helper that accepts any array — including windows from two
        // separate reads — so it cannot assume disjoint input.
        let overlapped = unionOverlapSeconds(of: candidate,
                                             with: windows.map(\.interval))
        return min(1, overlapped / candidate.duration)
    }
}
