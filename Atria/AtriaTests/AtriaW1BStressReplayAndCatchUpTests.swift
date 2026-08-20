import XCTest
@testable import Atria

/// W1-B (STRENGTHEN_FIVE_PLAN 2026-08-20, stress-gaps fixes 1–5):
/// 1. Journal-union replay ordering — the resident journal joins the
///    newest-first saved-session list at the FRONT; the old end-append flipped
///    the monotonic direction and every journal-unioned replay failed closed
///    to `.empty` (device-proven qualifiedAndReconciled=0 since d10f1fcd).
/// 2. `hrWindowSeconds` headroom (300→360) so a tick landing after a minute
///    boundary no longer prunes the head of the window it is about to score.
/// 3. Bounded oldest-first retroactive catch-up for tick-starved minute
///    boundaries, with per-minute sleep evidence and EMA-order honesty.
/// 4. Honest abort receipts (`replay_aborted_*`, never `kernel_declined` for
///    a kernel that never ran) and the newest-96 `missingMinutes` cap.
///
/// All fixtures anchor at 2027-01-15 (post-2026-08-06 rule) on an exact
/// minute/hour boundary, with per-test isolated UserDefaults suites and no
/// timing waits.
final class AtriaW1BStressReplayAndCatchUpTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    /// 2027-01-15T08:00:00Z — exactly minute- and hour-aligned.
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)
    private let restingMaxHR: (rest: Int, max: Int) = (rest: 60, max: 190)

    override func setUpWithError() throws {
        suiteName = "AtriaW1BStressTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    // MARK: - Fixtures

    private func denseSession(start: Date,
                              duration: TimeInterval,
                              bpm: Int = 70,
                              id: UUID = UUID(),
                              label: String = "W1B fixture") -> SavedSession {
        SavedSession(
            id: id,
            start: start,
            end: start.addingTimeInterval(duration),
            label: label,
            points: stride(from: 0.0, through: duration, by: 1.0).map {
                .init(t: $0, bpm: bpm)
            }
        )
    }

    private var replayPersonalization: AtriaPhysiologicalStressModel.Personalization {
        .init(restingHeartRate: 60,
              maximumHeartRate: 190,
              restingBaselineDayCount: 20,
              hrvBaseline: nil)
    }

    /// Resting-only 20-day baseline so live scoring is not in learning mode.
    private func makeBaseline(dayCount: Int = 20) -> PersonalBaseline {
        var samples: [PersonalBaseline.BaselineSample] = []
        for day in 0..<dayCount {
            let date = anchor.addingTimeInterval(-Double(day + 1) * 24 * 3_600)
            let sign = (day % 2 == 0) ? 1.0 : -1.0
            samples.append(PersonalBaseline.BaselineSample(date: date,
                                                           restingHR: 60 + sign * 4,
                                                           rmssd: nil,
                                                           overnight: true))
        }
        return PersonalBaseline(restingHR: 60, hrvEMA: nil,
                                sessions: dayCount, updated: anchor,
                                samples: samples)
    }

    /// A sleep that passes `isQualifiedHistoricalSleep` (same shape as the
    /// existing qualified-sleep evidence test: 4h, motion-validated).
    private func qualifiedSleep(start: Date, end: Date) -> UserConfirmedSleep {
        UserConfirmedSleep(
            id: UUID().uuidString,
            createdAt: end,
            start: start,
            end: end,
            source: "detected",
            confidence: "high",
            sessions: 1,
            samples: 480,
            avgHR: 56,
            peakHR: 68,
            restingHR: 52,
            hrv: nil,
            hrvWindowCount: nil,
            duration: end.timeIntervalSince(start),
            span: end.timeIntervalSince(start),
            reason: "W1B sleep fixture",
            motionSource: "validated",
            motionValidated: true,
            stageSegments: nil
        )
    }

    @MainActor
    private func makeStore() -> AtriaStressMonitorStore {
        AtriaStressMonitorStore(defaults: defaults,
                                applicationIsActive: { true })
    }

    @MainActor
    private func tick(_ store: AtriaStressMonitorStore,
                      at offset: TimeInterval,
                      bpm: Int = 76,
                      baseline: PersonalBaseline,
                      sleeps: [UserConfirmedSleep] = []) {
        store.update(heartRate: bpm,
                     hasContact: true,
                     recentRRSamples: [],
                     isRecording: false,
                     zoneIndex: 0,
                     hrvSnapshot: nil,
                     baseline: baseline,
                     restingMaxHR: restingMaxHR,
                     hasActiveSleepEvidence: false,
                     confirmedSleeps: sleeps,
                     now: anchor.addingTimeInterval(offset))
    }

    private func decodeSummary() throws
        -> AtriaHistoricalStressReplay.GapReceiptSummary {
        let data = try XCTUnwrap(defaults.data(
            forKey: AtriaHistoricalStressReplay.gapReceiptKey
        ))
        return try JSONDecoder().decode(
            AtriaHistoricalStressReplay.GapReceiptSummary.self,
            from: data
        )
    }

    // MARK: - Fix 1: journal-union ordering

    /// Three newest-first saved sessions plus a newer resident journal: the
    /// front-inserted union must evaluate to facts for the journal-covered
    /// minutes. Before the fix this exact source shape returned `.empty`.
    @MainActor
    func testFrontInsertedJournalUnionScoresJournalMinutes() throws {
        let journal = denseSession(start: anchor.addingTimeInterval(-1_800),
                                   duration: 1_200,
                                   label: "resident journal")
        let saved = [
            denseSession(start: anchor.addingTimeInterval(-4 * 3_600),
                         duration: 1_200),
            denseSession(start: anchor.addingTimeInterval(-5 * 3_600),
                         duration: 1_200),
            denseSession(start: anchor.addingTimeInterval(-6 * 3_600),
                         duration: 1_200),
        ]

        // Saved sessions alone cannot cover the journal span (the live-period
        // hole the union exists to heal).
        let savedOnlySnapshot = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: saved,
            personalization: replayPersonalization,
            now: anchor
        ))
        let savedOnly = AtriaHistoricalStressReplay.evaluate(savedOnlySnapshot)
        XCTAssertTrue(savedOnly.facts.filter { $0.date >= journal.start }.isEmpty)

        let union = AtriaHistoricalStressReplay.journalUnionedSourceSessions(
            savedSessions: saved,
            journal: journal
        )
        XCTAssertEqual(union.sessions.first?.id, journal.id,
                       "the newest session joins the FRONT of the newest-first list")
        XCTAssertEqual(union.sessions.count, saved.count + 1)
        let expectedSpanStart = journal.start.timeIntervalSince1970
        let expectedSpanEnd = journal.end.timeIntervalSince1970
        XCTAssertEqual(union.activeJournalSpan,
                       expectedSpanStart...expectedSpanEnd)

        let snapshot = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: union.sessions,
            personalization: replayPersonalization,
            now: anchor
        ))
        let result = AtriaHistoricalStressReplay.evaluate(snapshot)
        XCTAssertNil(AtriaHistoricalStressReplay.replayAbortReason(
            result: result,
            sourceSessions: union.sessions
        ))
        let journalFacts = result.facts.filter {
            $0.date > journal.start && $0.date <= journal.end
        }
        XCTAssertGreaterThanOrEqual(
            journalFacts.count, 10,
            "journal-covered minutes must score once the union preserves order"
        )
    }

    /// Pins the defect shape and the ordering contract: a journal appended at
    /// the END of a newest-first list flips the monotonic direction and the
    /// replay fails closed to `.empty` — `evaluate` must never sort it into
    /// plausibility (overlap-provenance guard).
    @MainActor
    func testJournalAppendedAtEndFailsClosedToEmpty() throws {
        let journal = denseSession(start: anchor.addingTimeInterval(-1_800),
                                   duration: 1_200)
        var appended = [
            denseSession(start: anchor.addingTimeInterval(-4 * 3_600),
                         duration: 1_200),
            denseSession(start: anchor.addingTimeInterval(-5 * 3_600),
                         duration: 1_200),
            denseSession(start: anchor.addingTimeInterval(-6 * 3_600),
                         duration: 1_200),
        ]
        appended.append(journal) // the pre-fix union shape

        let snapshot = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: appended,
            personalization: replayPersonalization,
            now: anchor
        ))
        let result = AtriaHistoricalStressReplay.evaluate(snapshot)
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(
            AtriaHistoricalStressReplay.replayAbortReason(
                result: result,
                sourceSessions: appended
            ),
            "replay_aborted_session_order"
        )
    }

    /// `.empty` is destruction-free: a failed replay owns no managed ranges
    /// and no sleep authority, so it can never delete or relabel facts.
    @MainActor
    func testEmptyResultCarriesNoDestructiveAuthority() throws {
        XCTAssertTrue(AtriaHistoricalStressReplay.Result.empty.managedRanges.isEmpty)
        XCTAssertNil(AtriaHistoricalStressReplay.Result.empty.sleepContextAuthority)
        XCTAssertTrue(AtriaHistoricalStressReplay.Result.empty.facts.isEmpty)

        // The same holds for a live ordering abort, not just the static value.
        let journal = denseSession(start: anchor.addingTimeInterval(-1_800),
                                   duration: 1_200)
        let mixed = [
            denseSession(start: anchor.addingTimeInterval(-4 * 3_600),
                         duration: 1_200),
            denseSession(start: anchor.addingTimeInterval(-5 * 3_600),
                         duration: 1_200),
            journal,
        ]
        let snapshot = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: mixed,
            personalization: replayPersonalization,
            now: anchor
        ))
        let aborted = AtriaHistoricalStressReplay.evaluate(snapshot)
        XCTAssertTrue(aborted.managedRanges.isEmpty,
                      "an ordering abort must never become a managed-range publication")
        XCTAssertNil(aborted.sleepContextAuthority)
    }

    /// The fail-closed drop: a journal unexpectedly older than the head of
    /// the newest-first list is dropped for the run (identical to today's
    /// no-journal replay), never appended into a mixed order.
    func testJournalOlderThanHeadIsDroppedFailClosed() {
        let saved = [denseSession(start: anchor.addingTimeInterval(-3_600),
                                  duration: 1_200)]
        let stale = denseSession(start: anchor.addingTimeInterval(-2 * 3_600),
                                 duration: 1_200)
        let union = AtriaHistoricalStressReplay.journalUnionedSourceSessions(
            savedSessions: saved,
            journal: stale
        )
        XCTAssertEqual(union.sessions.map(\.id), saved.map(\.id))
        XCTAssertNil(union.activeJournalSpan,
                     "a dropped journal contributes no active-journal span")
    }

    /// The id dedupe still runs before insertion: a fresher capture of the
    /// same resident journal replaces the stale row at the front.
    func testJournalDedupeReplacesPriorRowOfSameSession() {
        let journalID = UUID()
        let stale = denseSession(start: anchor.addingTimeInterval(-1_800),
                                 duration: 900,
                                 id: journalID,
                                 label: "stale journal row")
        let saved = [
            stale,
            denseSession(start: anchor.addingTimeInterval(-4 * 3_600),
                         duration: 1_200),
        ]
        let fresh = denseSession(start: anchor.addingTimeInterval(-1_800),
                                 duration: 1_200,
                                 id: journalID,
                                 label: "fresh journal row")
        let union = AtriaHistoricalStressReplay.journalUnionedSourceSessions(
            savedSessions: saved,
            journal: fresh
        )
        XCTAssertEqual(union.sessions.count, 2)
        XCTAssertEqual(union.sessions.first?.id, journalID)
        XCTAssertEqual(union.sessions.first?.end, fresh.end,
                       "the fresher capture replaces the stale row")
    }

    // MARK: - Fix 4: honest abort receipts + newest-96 cap

    /// Receipts finalized from an ordering-aborted replay must contain no
    /// `kernel_declined`: the kernel never ran, so would-be kernel minutes
    /// carry the abort classification instead.
    func testOrderingAbortedReplayReceiptsContainNoKernelDeclined() throws {
        let dense = denseSession(start: anchor.addingTimeInterval(-3_600),
                                 duration: 3_600)
        let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
            sessions: [dense],
            producedFacts: [],
            activeJournalSpan: nil,
            now: anchor,
            windowHours: 2
        )
        AtriaHistoricalStressReplay.finalizeGapReceipts(
            draft: draft,
            mergedStoreMinutes: [],
            now: anchor,
            replayAbortReason: "replay_aborted_session_order",
            defaults: defaults
        )
        let summary = try decodeSummary()
        XCTAssertEqual(summary.kernelDeclined, 0,
                       "the kernel never ran; nothing may claim it declined")
        XCTAssertFalse(summary.missingMinutes.contains {
            $0.hasSuffix("|kernel_declined")
        })
        XCTAssertEqual(summary.replayAbortReason, "replay_aborted_session_order")
        XCTAssertGreaterThan(summary.replayAborted ?? 0, 0,
                             "would-be kernel minutes are named for the abort")
        XCTAssertTrue(summary.missingMinutes.contains {
            $0.hasSuffix("|replay_aborted_session_order")
        })
        XCTAssertEqual(summary.qualifiedAndReconciled, 0)
    }

    /// A completed replay's receipts are unchanged by the abort plumbing: no
    /// abort marker, and kernel-adjudicated minutes still classify as
    /// `kernel_declined` when the kernel genuinely declined them.
    func testCompletedReplayReceiptsCarryNoAbortMarker() throws {
        let dense = denseSession(start: anchor.addingTimeInterval(-3_600),
                                 duration: 3_600)
        let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
            sessions: [dense],
            producedFacts: [],
            activeJournalSpan: nil,
            now: anchor,
            windowHours: 2
        )
        AtriaHistoricalStressReplay.finalizeGapReceipts(
            draft: draft,
            mergedStoreMinutes: [],
            now: anchor,
            defaults: defaults
        )
        let summary = try decodeSummary()
        XCTAssertNil(summary.replayAbortReason)
        XCTAssertNil(summary.replayAborted)
        XCTAssertGreaterThan(summary.kernelDeclined, 0)
    }

    /// The documented "newest last, capped" contract: when the window holds
    /// more missing minutes than the cap, the NEWEST 96 entries survive. The
    /// old append-until-cap kept the oldest 96 and dropped exactly the
    /// near-past minutes the receipts exist to explain.
    func testMissingMinutesCapRetainsNewestEntries() throws {
        // Empty source over the default 12h window: 720 not-yet-durable
        // minutes, far above the 96-entry cap.
        let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
            sessions: [],
            producedFacts: [],
            activeJournalSpan: nil,
            now: anchor
        )
        AtriaHistoricalStressReplay.finalizeGapReceipts(
            draft: draft,
            mergedStoreMinutes: [],
            now: anchor,
            defaults: defaults
        )
        let summary = try decodeSummary()
        // The classifier's own convention: the first two window minutes fall
        // through to the sample-scan shortfall classes (newestHR + cadence
        // guard), so assert against the draft rather than a hardcoded total.
        XCTAssertEqual(draft.classesByMinute.count, 720,
                       "every minute in the window is classified")
        let expectedNotYetDurable = draft.classesByMinute.values
            .filter { $0 == "source_not_yet_durable" }.count
        XCTAssertEqual(summary.sourceNotYetDurable, expectedNotYetDurable,
                       "counters mirror the draft's own classification")
        XCTAssertEqual(summary.missingMinutes.count,
                       AtriaHistoricalStressReplay.gapReceiptMinuteCap)
        let keys = summary.missingMinutes.compactMap {
            Int($0.split(separator: "|")[0])
        }
        XCTAssertEqual(keys.count,
                       AtriaHistoricalStressReplay.gapReceiptMinuteCap)
        XCTAssertEqual(keys, keys.sorted(), "newest last")
        XCTAssertEqual(keys.last, Int(anchor.timeIntervalSince1970) - 60,
                       "the newest missing minute is retained")
        XCTAssertEqual(
            keys.first,
            Int(anchor.timeIntervalSince1970)
                - AtriaHistoricalStressReplay.gapReceiptMinuteCap * 60,
            "the cap trims the OLDEST entries, not the newest"
        )
    }

    // MARK: - Fixes 2 + 3: live buffer headroom and retroactive catch-up

    /// A 20s tick stall beginning <10s before a minute boundary: the first
    /// post-stall tick evaluates the boundary minute, and the 360s buffer
    /// keeps the window head [B-300, B-288] that a bare 300s prune (the
    /// pre-fix behavior) discarded before scoring.
    @MainActor
    func testTwentySecondStallBeforeBoundaryStillScoresBoundaryMinute() throws {
        let baseline = makeBaseline()
        let store = makeStore()
        for second in 0...652 { // 1Hz; last tick 8s before the 660 boundary
            tick(store, at: TimeInterval(second), baseline: baseline)
        }
        // 20s tick stall spans the boundary; the next tick lands at 672.
        tick(store, at: 672, baseline: baseline)

        let boundary = anchor.addingTimeInterval(660)
        XCTAssertTrue(store.history.contains { $0.t == boundary },
                      "the boundary minute scores from the retained window head")
        XCTAssertEqual(store.state.kind, .scored)
        XCTAssertEqual(store.lastMeasuredAt, boundary)

        // Pre-fix baseline, pinned at kernel level: the same evidence pruned
        // to a bare 300s at the post-stall tick (t >= 672-300) loses the
        // window head and the kernel declines minute B on the span gate.
        var tickTimes = (0...652).map(TimeInterval.init)
        tickTimes.append(672)
        func samples(keepingAgesUpTo retention: TimeInterval)
            -> [AtriaPhysiologicalStressModel.HeartRateSample] {
            tickTimes
                .filter { 672 - $0 <= retention }
                .map {
                    .init(date: anchor.addingTimeInterval($0),
                          bpm: 76,
                          qualified: true)
                }
        }
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(
            .init(end: boundary,
                  heartRates: samples(keepingAgesUpTo: 300),
                  rrIntervals: [],
                  personalization: replayPersonalization,
                  motionContext: .unavailable,
                  sleepContext: .unavailable)
        ), "the pre-fix 300s prune left <290s of span and the minute declined")
        XCTAssertNotNil(AtriaPhysiologicalStressModel.evaluate(
            .init(end: boundary,
                  heartRates: samples(keepingAgesUpTo: 360),
                  rrIntervals: [],
                  personalization: replayPersonalization,
                  motionContext: .unavailable,
                  sleepContext: .unavailable)
        ), "with one cadence of headroom the identical evidence scores")
    }

    /// A 70s tick outage spanning a full wall minute, stall beginning <10s
    /// before the boundary: the leading skipped minute is fully
    /// evidence-backed and scores retroactively at the resume tick; minutes
    /// whose windows contain the outage stay declined by the 60s gap rule,
    /// and the chart keeps breaking there.
    @MainActor
    func testSeventySecondOutageScoresLeadingSkippedMinuteOnly() throws {
        let baseline = makeBaseline()
        let store = makeStore()
        for second in 0...652 { // 1Hz; last tick 8s before the 660 boundary
            tick(store, at: TimeInterval(second), baseline: baseline)
        }
        // 70s outage spanning the 660 boundary; resume at 722.
        tick(store, at: 722, baseline: baseline)

        let leading = anchor.addingTimeInterval(660)
        let following = anchor.addingTimeInterval(720)
        XCTAssertTrue(store.history.contains { $0.t == leading },
                      "the leading skipped minute scores retroactively")
        XCTAssertFalse(store.history.contains { $0.t == following },
                       "a window containing the 70s outage stays declined")
        XCTAssertEqual(store.state.kind, .warmingUp,
                       "a >60s tick stall honestly restarts live warm-up")
        let retroactive = try XCTUnwrap(
            store.history.first { $0.t == leading }
        )
        XCTAssertEqual(retroactive.factSource, .live)
        XCTAssertEqual(retroactive.minuteFact?.date, leading)
        XCTAssertEqual(retroactive.minuteFact?.motionContext,
                       .unavailable,
                       "motion at a starved minute fails closed to unavailable")

        // Kernel-level pin of the 60s gap rule for the following minute: its
        // window [660, 720] tail is inside the outage.
        var tickTimes = (0...652).map(TimeInterval.init)
        tickTimes.append(722)
        let windowSamples = tickTimes
            .filter { 722 - $0 <= 360 }
            .map {
                AtriaPhysiologicalStressModel.HeartRateSample(
                    date: anchor.addingTimeInterval($0),
                    bpm: 76,
                    qualified: true
                )
            }
        XCTAssertNil(AtriaPhysiologicalStressModel.evaluate(
            .init(end: following,
                  heartRates: windowSamples,
                  rrIntervals: [],
                  personalization: replayPersonalization,
                  motionContext: .unavailable,
                  sleepContext: .unavailable)
        ), "the 70s hole exceeds maximumRawHeartRateGap and the minute declines")

        // Ticks inside the restarted warm-up mint nothing further: the
        // skipped-minute ledger advances without fabricating warm-up facts.
        for second in 723...780 {
            tick(store, at: TimeInterval(second), baseline: baseline)
        }
        XCTAssertEqual(store.history.last?.t, leading,
                       "no fact appears for minutes inside the restarted warm-up")
    }

    /// Sleep evidence for a caught-up minute is computed at the skipped
    /// minute itself, never copied from the current tick: a qualified sleep
    /// covering the skipped boundary (but already over at the resume tick)
    /// marks the retroactive fact `.asleep`, while the live minutes scored
    /// from the caller's `hasActiveSleepEvidence: false` stay `.unavailable`.
    @MainActor
    func testCatchUpComputesSleepEvidenceAtTheSkippedMinute() throws {
        let baseline = makeBaseline()
        let store = makeStore()
        let sleepEnd = anchor.addingTimeInterval(690)
        let sleep = qualifiedSleep(start: sleepEnd.addingTimeInterval(-4 * 3_600),
                                   end: sleepEnd)
        for second in 0...652 {
            tick(store, at: TimeInterval(second), baseline: baseline,
                 sleeps: [sleep])
        }
        tick(store, at: 722, baseline: baseline, sleeps: [sleep])

        let leading = anchor.addingTimeInterval(660)
        let retroactiveFact = try XCTUnwrap(
            store.history.first { $0.t == leading }?.minuteFact
        )
        XCTAssertEqual(retroactiveFact.sleepContext, .asleep,
                       "evidence is evaluated at the skipped minute itself")

        let liveFact = try XCTUnwrap(
            store.history.first { $0.t == anchor.addingTimeInterval(600) }?
                .minuteFact
        )
        XCTAssertEqual(liveFact.sleepContext, .unavailable,
                       "the live path still honors only the caller-computed flag")
    }
}
