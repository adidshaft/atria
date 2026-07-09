import XCTest
@testable import Atria

/// Deterministic coverage for the 2026-07-08 "Stop the bleeding" perf fixes
/// (docs/PERF_HANDOFF_2026-07-08.md). These exercise the shipped logic at
/// realistic volumes WITHOUT a live strap session — the crash/jank only
/// manifest during continuous streaming, which unit tests can stand in for by
/// driving the pure functions directly.
// `@MainActor` because the functions under test live on `@MainActor` types
// (AtriaBLEManager / the SwiftUI Health screen); the logic itself is pure.
@MainActor
final class AtriaPerfFixesTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Fix #1 — retention-roll trigger (bounds the live session)

    /// Below the retention span the live session is left intact.
    func testRetentionRoll_belowSpanCap_doesNotRoll() {
        // 1s under the 3h (10800s) cap, with plenty of samples.
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_799,
                                                             sampleCount: 100_000,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
    }

    /// At exactly the cap (with enough samples) the session rolls.
    func testRetentionRoll_atSpanCap_rolls() {
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_800,
                                                            sampleCount: 100_000,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
    }

    /// Span past the cap but too few samples must NOT roll (avoids finalizing a
    /// sliver — mirrors the autoSaveMinSamples guard in the live path).
    func testRetentionRoll_spanOKButTooFewSamples_doesNotRoll() {
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 20_000,
                                                             sampleCount: 9,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
        // Exactly at the sample floor + at the cap => rolls (boundary).
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 10_800,
                                                            sampleCount: 10,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
    }

    /// The real over-the-cap session pulled off the device (20,291 samples over
    /// ~5.6h continuous "All-day wear") is exactly what the fix now segments;
    /// a typical short segmented session (~9.5min) is left alone.
    func testRetentionRoll_realDeviceSessionShapes() {
        // 20,291 samples, ~5.6h continuous  -> rolls at 3h.
        XCTAssertTrue(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 20_160,
                                                            sampleCount: 20_291,
                                                            minSamples: 10,
                                                            retentionSpan: 10_800))
        // Median device session (~570 samples, ~9.5min) -> never rolls.
        XCTAssertFalse(AtriaBLEManager.shouldRollLiveSession(spanSeconds: 570,
                                                             sampleCount: 570,
                                                             minSamples: 10,
                                                             retentionSpan: 10_800))
    }

    // MARK: - Fix #2 — stress-strip downsample + gap honesty

    private func stressHistory(count: Int,
                               start: Date,
                               cadence: TimeInterval = 30,
                               activation: (Int) -> Double) -> [AtriaStressMonitorStore.StressHistoryPoint] {
        (0..<count).map { i in
            AtriaStressMonitorStore.StressHistoryPoint(t: start.addingTimeInterval(Double(i) * cadence),
                                                       activation: activation(i),
                                                       level: .low)
        }
    }

    /// A dense two-segment day (12h @30s, split by a 10-minute gap) must (a)
    /// downsample well below the raw count, (b) keep the two runs as SEPARATE
    /// segments, and (c) never bridge the real blank — the honesty contract.
    func testReduceStressStrip_preservesGapAndDownsamples() {
        let seg0 = stressHistory(count: 720, start: t0) { i in 0.2 + 0.3 * Double(i % 5) / 5.0 }
        // 10-minute gap after seg0's last sample (> the 5-minute split threshold).
        let gapStart = t0.addingTimeInterval(Double(719) * 30 + 10 * 60)
        let seg1 = stressHistory(count: 720, start: gapStart) { i in 0.5 + 0.2 * Double(i % 4) / 4.0 }
        let history = seg0 + seg1

        let reduced = AtriaHealthScreen.reduceStressStrip(history)

        XCTAssertFalse(reduced.isEmpty)
        // Downsampled far below the ~1440 raw points, within the ~110 budget
        // (+ small per-segment slack).
        XCTAssertLessThan(reduced.count, history.count)
        XCTAssertLessThanOrEqual(reduced.count, 130)
        XCTAssertGreaterThan(reduced.count, 20)

        // Two distinct segments survive.
        XCTAssertEqual(Set(reduced.map(\.segment)), [0, 1])

        // The >5min blank is preserved: nothing is emitted inside the gap, and
        // segment 1 starts strictly after segment 0 ends by more than 5 minutes.
        let seg0Times = reduced.filter { $0.segment == 0 }.map(\.t)
        let seg1Times = reduced.filter { $0.segment == 1 }.map(\.t)
        let seg0Max = seg0Times.max()!
        let seg1Min = seg1Times.min()!
        XCTAssertGreaterThan(seg1Min.timeIntervalSince(seg0Max), 5 * 60,
                             "the real strap-off gap must stay blank, never interpolated")

        // Nothing synthesized out of the 0...3 chart domain, and time is
        // strictly increasing within each segment.
        for point in reduced {
            XCTAssert(point.value >= 0 && point.value <= 3)
        }
        XCTAssert(zip(seg0Times, seg0Times.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssert(zip(seg1Times, seg1Times.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// Each bucket's value is the REAL mean of its samples' activation (x3),
    /// nothing invented: a constant-activation run yields exactly that constant.
    func testReduceStressStrip_bucketValueIsHonestMean() {
        let history = stressHistory(count: 400, start: t0) { _ in 0.5 }
        let reduced = AtriaHealthScreen.reduceStressStrip(history)
        XCTAssertFalse(reduced.isEmpty)
        XCTAssertLessThan(reduced.count, history.count) // 400 > 150 => bucketed
        for point in reduced {
            XCTAssertEqual(point.value, 1.5, accuracy: 1e-9) // mean(0.5)*3
            XCTAssertEqual(point.segment, 0)
        }
    }

    /// Under the density threshold the raw points are already legible, so they
    /// pass through 1:1 (still segmented) — full fidelity for short sessions.
    func testReduceStressStrip_smallInputPassesThroughFullFidelity() {
        let history = stressHistory(count: 100, start: t0) { i in Double(i % 3) / 3.0 }
        let reduced = AtriaHealthScreen.reduceStressStrip(history)
        XCTAssertEqual(reduced.count, 100)
        XCTAssertEqual(Set(reduced.map(\.segment)), [0])
        for (i, point) in reduced.enumerated() {
            XCTAssertEqual(point.value, Double(i % 3) / 3.0 * 3, accuracy: 1e-9)
        }
    }

    /// Empty / single-point history yields nothing (matches the >1 guard).
    func testReduceStressStrip_degenerateInputs() {
        XCTAssertTrue(AtriaHealthScreen.reduceStressStrip([]).isEmpty)
        XCTAssertTrue(AtriaHealthScreen.reduceStressStrip(stressHistory(count: 1, start: t0) { _ in 0.5 }).isEmpty)
    }

    // MARK: - Fix #3 — latestRollup memo

    /// Same revision => the O(n) scan runs exactly once and the cached value is
    /// returned; a revision bump recomputes.
    func testLatestRollupCache_computesOncePerRevision() {
        let cache = AtriaHealthScreen.LatestRollupCache()
        var computeCount = 0
        let first = DailyRollupStoreEntry(day: t0, recovery: 60)

        let r1 = cache.latest(revision: 1) { computeCount += 1; return first }
        XCTAssertEqual(computeCount, 1)
        XCTAssertEqual(r1, first)

        // Same revision: must NOT recompute, even if the closure would return
        // something different — it returns the cached value.
        let r2 = cache.latest(revision: 1) {
            computeCount += 1
            return DailyRollupStoreEntry(day: t0.addingTimeInterval(86_400), recovery: 99)
        }
        XCTAssertEqual(computeCount, 1, "same revision must not rescan")
        XCTAssertEqual(r2, first)

        // Bumped revision: recompute.
        let third = DailyRollupStoreEntry(day: t0.addingTimeInterval(2 * 86_400), recovery: 42)
        let r3 = cache.latest(revision: 2) { computeCount += 1; return third }
        XCTAssertEqual(computeCount, 2)
        XCTAssertEqual(r3, third)
    }

    /// A nil result is cached too (an empty rollup history shouldn't rescan on
    /// every read).
    func testLatestRollupCache_cachesNilResult() {
        let cache = AtriaHealthScreen.LatestRollupCache()
        var computeCount = 0
        _ = cache.latest(revision: 7) { computeCount += 1; return nil }
        let again = cache.latest(revision: 7) { computeCount += 1; return nil }
        XCTAssertEqual(computeCount, 1)
        XCTAssertNil(again)
    }
}
