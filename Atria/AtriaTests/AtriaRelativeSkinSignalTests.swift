import XCTest
@testable import Atria

final class AtriaRelativeSkinSignalTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func authority(key: String = "strapA",
                          layout: String = "v24",
                          payload: Int = 44,
                          offset: Int = 68,
                          algo: String = AtriaRelativeSkinSignal.algorithmVersion)
        -> AtriaRelativeSkinSignalAuthority {
        .init(pseudonymousStrapKey: key, layoutVersion: layout,
              payloadLength: payload, rawOffset: offset, algorithmVersion: algo)
    }

    private func night(id: String,
                       dayOffset: Int,
                       raw: Double,
                       authority: AtriaRelativeSkinSignalAuthority? = nil,
                       rows: Int = 200,
                       minutes: Int = 120,
                       coverage: Double = 0.9,
                       motion: Bool = false) -> AtriaRelativeSkinNightSummary {
        let start = baseDate.addingTimeInterval(Double(dayOffset) * 86_400)
        return .init(cycleDay: start,
                     confirmedSleepID: id,
                     sleepStart: start,
                     sleepEnd: start.addingTimeInterval(7 * 3_600),
                     authority: authority ?? self.authority(),
                     nightlyRawMedian: raw,
                     qualifiedRowCount: rows,
                     coveredMinuteCount: minutes,
                     coverageFraction: coverage,
                     motionQualified: motion,
                     calculatedAt: start.addingTimeInterval(8 * 3_600))
    }

    // 1. Current night never in its own baseline.
    func testCurrentNightExcludedFromOwnBaseline() {
        let current = night(id: "cur", dayOffset: 8, raw: 500)
        // Provide the current night ALSO inside priorNights plus 7 genuine priors.
        var priors = [current]
        for i in 0..<7 { priors.append(night(id: "p\(i)", dayOffset: i, raw: 400)) }
        let summary = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertEqual(summary.baselineNightCount, 7, "the current night must not count in its baseline")
        XCTAssertEqual(summary.baselineRawMedian, 400)
        XCTAssertEqual(summary.rawDelta, 100)
    }

    // 2. 0-6 prior nights -> buildingBaseline; 7 -> first numeric delta.
    func testBuildingBaselineUntilSevenPriorNights() {
        let current = night(id: "cur", dayOffset: 10, raw: 500)
        for count in 0...6 {
            let priors = (0..<count).map { night(id: "p\($0)", dayOffset: $0, raw: 400) }
            let s = AtriaRelativeSkinSignal.resolve(
                currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
            XCTAssertEqual(s.blocker, .buildingBaseline, "\(count) priors must build baseline")
            XCTAssertNil(s.rawDelta)
            XCTAssertEqual(s.baselineNightCount, count)
        }
        let priors7 = (0..<7).map { night(id: "p\($0)", dayOffset: $0, raw: 400) }
        let s7 = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors7, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertNil(s7.blocker)
        XCTAssertEqual(s7.rawDelta, 100)
    }

    // 3. Baseline and delta use medians exactly.
    func testBaselineAndDeltaUseMediansExactly() {
        let current = night(id: "cur", dayOffset: 20, raw: 512)
        let rawValues: [Double] = [400, 410, 420, 430, 440, 450, 1_000] // median = 430
        let priors = rawValues.enumerated().map { night(id: "p\($0.offset)", dayOffset: $0.offset, raw: $0.element) }
        let s = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertEqual(s.baselineRawMedian, 430, "median ignores the 1000 outlier")
        XCTAssertEqual(s.rawDelta, 82)
    }

    // 4. Per-minute median prevents a burst from dominating the night.
    func testPerMinuteMedianPreventsBurstDomination() {
        // One minute has 100 samples of 900; three other minutes are 400/410/420.
        let minuteMedians = [900.0, 400.0, 410.0, 420.0]
        XCTAssertEqual(AtriaRelativeSkinSignal.nightlyRawMedian(minuteMedians: minuteMedians), 415)
    }

    // 5. Minimum rows, minutes, coverage each fail independently.
    func testNightQualificationGatesFailIndependently() {
        XCTAssertEqual(AtriaRelativeSkinSignal.nightQualifies(rowCount: 99, coveredMinutes: 120, coverageFraction: 0.9),
                       .insufficientRows)
        XCTAssertEqual(AtriaRelativeSkinSignal.nightQualifies(rowCount: 200, coveredMinutes: 59, coverageFraction: 0.9),
                       .insufficientCoveredMinutes)
        XCTAssertEqual(AtriaRelativeSkinSignal.nightQualifies(rowCount: 200, coveredMinutes: 120, coverageFraction: 0.49),
                       .insufficientCoverage)
        XCTAssertNil(AtriaRelativeSkinSignal.nightQualifies(rowCount: 100, coveredMinutes: 60, coverageFraction: 0.5))
    }

    // 6. Mixed strap/layout/payload/offset/algorithm fails closed.
    func testMixedAuthorityDoesNotCountTowardBaseline() {
        let current = night(id: "cur", dayOffset: 30, raw: 500, authority: authority(key: "strapA"))
        // 7 priors, but each under a DIFFERENT authority than the current night.
        let priors = (0..<7).map {
            night(id: "p\($0)", dayOffset: $0, raw: 400, authority: authority(key: "strapB"))
        }
        let s = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertEqual(s.baselineNightCount, 0, "different strap authority must not seed the baseline")
        XCTAssertEqual(s.blocker, .buildingBaseline)
        XCTAssertNil(s.rawDelta)
    }

    func testEachAuthorityFieldMismatchExcludesPriorNight() {
        let base = authority()
        let current = night(id: "cur", dayOffset: 40, raw: 500, authority: base)
        let mismatches = [
            authority(key: "other"),
            authority(layout: "v12"),
            authority(payload: 40),
            authority(offset: 66),
            authority(algo: "relskin.v2"),
        ]
        for mism in mismatches {
            let priors = (0..<7).map { night(id: "p\($0)", dayOffset: $0, raw: 400, authority: mism) }
            let s = AtriaRelativeSkinSignal.resolve(
                currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
            XCTAssertEqual(s.baselineNightCount, 0)
            XCTAssertEqual(s.blocker, .buildingBaseline)
        }
    }

    // 8. Baseline retains at most 30 nights.
    func testBaselineRetainsAtMostThirtyNights() {
        let current = night(id: "cur", dayOffset: 100, raw: 500)
        // 40 priors, most recent 30 all 400, older 10 are 1 (would drag the median).
        var priors: [AtriaRelativeSkinNightSummary] = []
        for i in 0..<30 { priors.append(night(id: "recent\(i)", dayOffset: 60 + i, raw: 400)) }
        for i in 0..<10 { priors.append(night(id: "old\(i)", dayOffset: i, raw: 1)) }
        let s = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertEqual(s.baselineNightCount, 30)
        XCTAssertEqual(s.baselineRawMedian, 400, "only the most-recent 30 nights seed the baseline")
    }

    // 9. Zero MAD still produces a finite normalized index.
    func testZeroMADProducesFiniteNormalizedIndex() {
        let current = night(id: "cur", dayOffset: 50, raw: 407)
        let priors = (0..<7).map { night(id: "p\($0)", dayOffset: $0, raw: 400) } // all identical -> MAD 0
        let s = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertEqual(s.rawDelta, 7)
        let index = try? XCTUnwrap(s.normalizedIndex)
        XCTAssertNotNil(index)
        XCTAssertTrue(s.normalizedIndex?.isFinite ?? false)
        // scale floors at 1 -> index == rawDelta.
        XCTAssertEqual(s.normalizedIndex, 7)
    }

    // 13. A prior value is never borrowed when the current cycle has no evidence.
    func testNoCurrentNightBorrowsNothing() {
        let s = AtriaRelativeSkinSignal.resolve(
            currentNight: nil,
            priorNights: (0..<10).map { night(id: "p\($0)", dayOffset: $0, raw: 400) },
            blockerIfNoCurrent: .noCurrentConfirmedMainSleep)
        XCTAssertEqual(s.blocker, .noCurrentConfirmedMainSleep)
        XCTAssertNil(s.rawDelta)
        XCTAssertNil(s.currentNight)
        XCTAssertNil(s.baselineRawMedian)
    }

    // Directional zones are personal-signal zones (only after motion-qualified).
    func testDirectionalZoneThresholds() {
        XCTAssertEqual(AtriaRelativeSkinSignal.directionalZone(normalizedIndex: -1.5), .lowerThanUsual)
        XCTAssertEqual(AtriaRelativeSkinSignal.directionalZone(normalizedIndex: -0.2), .withinUsualRange)
        XCTAssertEqual(AtriaRelativeSkinSignal.directionalZone(normalizedIndex: 1.5), .higherThanUsual)
        XCTAssertNil(AtriaRelativeSkinSignal.directionalZone(normalizedIndex: nil))
        XCTAssertNil(AtriaRelativeSkinSignal.directionalZone(normalizedIndex: .infinity))
    }

    // MARK: - Pure per-night extraction

    private func samples(start: Date,
                         minutes: Int,
                         perMinute: Int,
                         raw: Int,
                         strap: String? = "AA:BB") -> [AtriaRelativeSkinSignal.RawSkinSample] {
        var out: [AtriaRelativeSkinSignal.RawSkinSample] = []
        for m in 0..<minutes {
            for s in 0..<perMinute {
                let t = start.addingTimeInterval(Double(m) * 60 + Double(s))
                out.append(.init(t: t, raw: raw, strapIdentifier: strap))
            }
        }
        return out
    }

    // A qualifying window returns a night whose median is the per-minute median.
    func testNightSummaryQualifiesAndMediansPerMinute() {
        let start = baseDate
        // 120 minutes, 2 samples/min = 240 worn rows, full coverage.
        var s = samples(start: start, minutes: 120, perMinute: 2, raw: 900)
        // Inject one dense burst minute of 60 samples at 2000 — must NOT dominate.
        s += samples(start: start.addingTimeInterval(30 * 60), minutes: 1, perMinute: 60, raw: 2000)
        let result = AtriaRelativeSkinSignal.nightSummary(
            samples: s,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(120 * 60),
            confirmedSleepID: "n1",
            cycleDay: start,
            authority: authority(),
            motionQualified: false,
            calculatedAt: start.addingTimeInterval(9 * 3_600))
        guard case let .success(night) = result else {
            return XCTFail("expected a qualifying night, got \(result)")
        }
        // One minute's median is 2000; 119 minutes' median is 900 -> night median 900.
        XCTAssertEqual(night.nightlyRawMedian, 900, "the burst minute cannot dominate the night")
        XCTAssertEqual(night.coveredMinuteCount, 120)
        XCTAssertEqual(night.coverageFraction, 1, accuracy: 0.0001)
        XCTAssertTrue(night.qualifiedRowCount >= 240)
    }

    // Out-of-worn-range raw is excluded from rows, coverage, and the median.
    func testNightSummaryExcludesOutOfWornRangeRaw() {
        let start = baseDate
        // 90 good minutes of 800, plus 90 minutes of off-body 100 (below 550).
        var s = samples(start: start, minutes: 90, perMinute: 2, raw: 800)
        s += samples(start: start.addingTimeInterval(90 * 60), minutes: 90, perMinute: 2, raw: 100)
        let result = AtriaRelativeSkinSignal.nightSummary(
            samples: s,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(180 * 60),
            confirmedSleepID: "n2",
            cycleDay: start,
            authority: authority(),
            motionQualified: false,
            calculatedAt: start.addingTimeInterval(9 * 3_600))
        guard case let .success(night) = result else {
            return XCTFail("expected a qualifying night, got \(result)")
        }
        XCTAssertEqual(night.nightlyRawMedian, 800)
        XCTAssertEqual(night.coveredMinuteCount, 90, "off-body minutes are not covered")
        // 90 covered of 180 expected -> 0.5 coverage (exactly the floor).
        XCTAssertEqual(night.coverageFraction, 0.5, accuracy: 0.0001)
    }

    // Too few worn rows -> insufficientRows blocker (no night).
    func testNightSummaryInsufficientRowsFailsClosed() {
        let start = baseDate
        // 70 minutes x 1 sample = 70 rows (< 100), 70 covered minutes (> 60).
        let s = samples(start: start, minutes: 70, perMinute: 1, raw: 900)
        let result = AtriaRelativeSkinSignal.nightSummary(
            samples: s,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(70 * 60),
            confirmedSleepID: "n3",
            cycleDay: start,
            authority: authority(),
            motionQualified: false,
            calculatedAt: start)
        XCTAssertEqual(result, .failure(.insufficientRows))
    }

    // The pseudonymous strap key is stable, one-way, and separates straps.
    func testPseudonymousStrapKeyStableDistinctAndPrivate() {
        let a1 = AtriaRelativeSkinSignal.pseudonymousStrapKey(from: "AA:BB:CC")
        let a2 = AtriaRelativeSkinSignal.pseudonymousStrapKey(from: "  aa:bb:cc ")
        let b = AtriaRelativeSkinSignal.pseudonymousStrapKey(from: "DD:EE:FF")
        XCTAssertEqual(a1, a2, "normalization makes the key stable across case/whitespace")
        XCTAssertNotEqual(a1, b, "different straps get different keys")
        XCTAssertFalse(a1.contains("AA"), "the raw serial never appears in the key")
        XCTAssertFalse(a1.lowercased().contains("aa:bb"), "the raw serial never appears in the key")
        XCTAssertEqual(AtriaRelativeSkinSignal.pseudonymousStrapKey(from: nil), "unknown")
        XCTAssertEqual(AtriaRelativeSkinSignal.pseudonymousStrapKey(from: "   "), "unknown")
    }

    // End-to-end: extract 8 qualifying nights, resolve the 8th vs the prior 7.
    func testExtractionFeedsResolveEndToEnd() {
        var priors: [AtriaRelativeSkinNightSummary] = []
        let auth = authority()
        for day in 0..<7 {
            let start = baseDate.addingTimeInterval(Double(day) * 86_400)
            let s = samples(start: start, minutes: 120, perMinute: 2, raw: 800)
            guard case let .success(n) = AtriaRelativeSkinSignal.nightSummary(
                samples: s, sleepStart: start, sleepEnd: start.addingTimeInterval(120 * 60),
                confirmedSleepID: "p\(day)", cycleDay: start, authority: auth,
                motionQualified: false, calculatedAt: start) else {
                return XCTFail("prior night \(day) should qualify")
            }
            priors.append(n)
        }
        let curStart = baseDate.addingTimeInterval(8 * 86_400)
        let curSamples = samples(start: curStart, minutes: 120, perMinute: 2, raw: 860)
        guard case let .success(current) = AtriaRelativeSkinSignal.nightSummary(
            samples: curSamples, sleepStart: curStart, sleepEnd: curStart.addingTimeInterval(120 * 60),
            confirmedSleepID: "cur", cycleDay: curStart, authority: auth,
            motionQualified: false, calculatedAt: curStart) else {
            return XCTFail("current night should qualify")
        }
        let summary = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        XCTAssertNil(summary.blocker)
        XCTAssertEqual(summary.baselineNightCount, 7)
        XCTAssertEqual(summary.baselineRawMedian, 800)
        XCTAssertEqual(summary.rawDelta, 60)
    }

    // Reloaded bounded summaries preserve exact value/authority/blocker/provenance.
    func testSummaryCodableRoundTripPreservesEverything() throws {
        let current = night(id: "cur", dayOffset: 60, raw: 512, motion: true)
        let priors = (0..<7).map { night(id: "p\($0)", dayOffset: $0, raw: 400) }
        let original = AtriaRelativeSkinSignal.resolve(
            currentNight: current, priorNights: priors, blockerIfNoCurrent: .noCurrentRawEvidence)
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(AtriaRelativeSkinSignalSummary.self, from: data)
        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.rawDelta, 112)
        XCTAssertEqual(restored.currentNight?.authority, current.authority)
        XCTAssertEqual(restored.algorithmVersion, "relskin.v1")
    }
}
