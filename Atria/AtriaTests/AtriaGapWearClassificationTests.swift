import XCTest
@testable import Atria

/// The wear verdict for a missing interval must be earned by positive
/// evidence; anything ambiguous fails closed to `.indeterminate` so missing
/// bookkeeping can never abandon (or invent) real data.
final class AtriaGapWearClassificationTests: XCTestCase {
    private typealias C = AtriaGapWearClassification

    private let start = Date(timeIntervalSince1970: 1_756_000_000)

    private func evidence(
        endOffset: TimeInterval? = 3_600,
        accepted: Int? = nil,
        zero: Int? = nil,
        contactAtOpen: Bool? = nil,
        charging: Bool? = nil,
        postDrainOffWrist: TimeInterval? = nil,
        expectedMissing: TimeInterval? = nil,
        cursor: TimeInterval? = nil,
        abandoned: TimeInterval? = nil,
        stalled: Bool = false
    ) -> C.Evidence {
        C.Evidence(windowStart: start,
                   windowEnd: endOffset.map { start.addingTimeInterval($0) },
                   overlappingAcceptedHRSamples: accepted,
                   overlappingZeroContactSamples: zero,
                   hadContactAtOpen: contactAtOpen,
                   chargingProvenDuringWindow: charging,
                   postDrainOffWristSeconds: postDrainOffWrist,
                   expectedMissingSeconds: expectedMissing,
                   drainCursorUnix: cursor,
                   abandonedThroughUnix: abandoned,
                   terminallyStalled: stalled)
    }

    // MARK: Fail-closed rule

    func testNoEvidenceIsIndeterminateNeverConfident() {
        XCTAssertEqual(C.classify(evidence()), .indeterminate)
    }

    func testGatheredButZeroCountersAreStillIndeterminate() {
        // Zero counts are absence of proof, not proof of absence.
        XCTAssertEqual(C.classify(evidence(accepted: 0, zero: 0)),
                       .indeterminate)
    }

    func testOpenWindowWithNoEvidenceIsIndeterminate() {
        XCTAssertEqual(C.classify(evidence(endOffset: nil)), .indeterminate)
    }

    // MARK: Worn-but-undrained

    func testOverlappingAcceptedHRProvesWornUndrained() {
        XCTAssertEqual(C.classify(evidence(accepted: 12)),
                       .wornUndrained(recoverable: true))
    }

    func testAcceptedHROutranksZeroAndChargingCounters() {
        // A long window can hold all three; a real accepted pulse wins.
        XCTAssertEqual(
            C.classify(evidence(accepted: 12, zero: 40, charging: true)),
            .wornUndrained(recoverable: true)
        )
    }

    func testWornWindowBehindCursorIsNotRecoverable() {
        let end = start.addingTimeInterval(3_600).timeIntervalSince1970
        XCTAssertEqual(C.classify(evidence(accepted: 12, cursor: end + 10)),
                       .wornUndrained(recoverable: false))
    }

    // MARK: Charging vs off-wrist precedence

    func testProvenChargingOutranksZeroContact() {
        XCTAssertEqual(C.classify(evidence(zero: 40, charging: true)),
                       .charging)
    }

    func testChargingAloneClassifiesCharging() {
        XCTAssertEqual(C.classify(evidence(charging: true)), .charging)
    }

    func testChargingFalseIsNotOffWristEvidence() {
        XCTAssertEqual(C.classify(evidence(charging: false)), .indeterminate)
    }

    // MARK: Off-wrist proofs

    func testZeroContactSamplesProveOffWrist() {
        XCTAssertEqual(C.classify(evidence(zero: 1)), .offWrist)
    }

    func testProvenNoContactAtOpenIsOffWrist() {
        XCTAssertEqual(C.classify(evidence(contactAtOpen: false)), .offWrist)
    }

    func testPostDrainOffWristMajorityIsOffWrist() {
        XCTAssertEqual(
            C.classify(evidence(postDrainOffWrist: 1_900,
                                expectedMissing: 3_600)),
            .offWrist
        )
    }

    func testPostDrainOffWristMinorityFailsClosed() {
        XCTAssertEqual(
            C.classify(evidence(postDrainOffWrist: 200,
                                expectedMissing: 3_600)),
            .indeterminate
        )
    }

    // MARK: App/radio down

    func testContactAtOpenWithNoSessionRowsIsAppOrRadioDown() {
        XCTAssertEqual(C.classify(evidence(contactAtOpen: true)),
                       .appOrRadioDown(recoverable: true))
    }

    func testAppOrRadioDownBehindAbandonedWatermarkIsNotRecoverable() {
        let end = start.addingTimeInterval(3_600).timeIntervalSince1970
        XCTAssertEqual(C.classify(evidence(contactAtOpen: true,
                                           abandoned: end + 1)),
                       .appOrRadioDown(recoverable: false))
    }

    // MARK: Recoverability boundary

    func testWindowStraddlingCursorStaysRecoverable() {
        // The unserved tail past the cursor still exists on the strap.
        let mid = start.addingTimeInterval(1_800).timeIntervalSince1970
        XCTAssertNil(C.provenUnrecoverableReason(evidence(cursor: mid)))
        XCTAssertTrue(C.isRecoverable(evidence(cursor: mid)))
    }

    func testWindowEndingExactlyAtCursorHasBeenServed() {
        let end = start.addingTimeInterval(3_600).timeIntervalSince1970
        XCTAssertEqual(C.provenUnrecoverableReason(evidence(cursor: end)),
                       "behind_drain_cursor")
    }

    func testAbandonedWatermarkOutranksCursorInTheReason() {
        let end = start.addingTimeInterval(3_600).timeIntervalSince1970
        XCTAssertEqual(
            C.provenUnrecoverableReason(evidence(cursor: end, abandoned: end)),
            "behind_abandoned_watermark"
        )
    }

    func testOpenWindowIsNeverBehindTheCursor() {
        XCTAssertNil(C.provenUnrecoverableReason(
            evidence(endOffset: nil, cursor: Date().timeIntervalSince1970)
        ))
    }

    func testTerminalStallIsUnrecoverableEvenForOpenWindows() {
        XCTAssertEqual(C.provenUnrecoverableReason(
            evidence(endOffset: nil, stalled: true)
        ), "terminal_stall")
        XCTAssertEqual(C.classify(evidence(stalled: true)),
                       .unrecoverable(reason: "terminal_stall"))
    }

    func testUnknownCursorAndWatermarkStayRecoverable() {
        XCTAssertTrue(C.isRecoverable(evidence()))
    }

    func testZeroCursorSentinelIsUnknownNotEpoch() {
        // A never-written defaults key reads as 0; that must not classify
        // every window as served.
        XCTAssertTrue(C.isRecoverable(evidence(cursor: 0, abandoned: 0)))
    }

    // MARK: Gap-open suppression predicate

    func testZeroRunBracketingTheIntervalProvesOffWrist() {
        let s = start.timeIntervalSince1970
        XCTAssertTrue(C.offWristProvenAcross(
            intervalStartUnix: s,
            intervalEndUnix: s + 7_200,
            zeroContactRunStartUnix: s + 5,
            lastZeroContactUnix: s + 7_150
        ))
    }

    func testZeroOnlyNearTheStartDoesNotSuppress() {
        // The wearer may have re-worn the strap while the link was down;
        // that worn time IS recoverable.
        let s = start.timeIntervalSince1970
        XCTAssertFalse(C.offWristProvenAcross(
            intervalStartUnix: s,
            intervalEndUnix: s + 7_200,
            zeroContactRunStartUnix: s + 5,
            lastZeroContactUnix: s + 600
        ))
    }

    func testZeroOnlyNearTheEndDoesNotSuppress() {
        let s = start.timeIntervalSince1970
        XCTAssertFalse(C.offWristProvenAcross(
            intervalStartUnix: s,
            intervalEndUnix: s + 7_200,
            zeroContactRunStartUnix: s + 5_000,
            lastZeroContactUnix: s + 7_150
        ))
    }

    func testStaleRunFromAnEarlierOutageNeverSuppresses() {
        // Both stamps predate this interval: no zero was observed inside it.
        let s = start.timeIntervalSince1970
        XCTAssertFalse(C.offWristProvenAcross(
            intervalStartUnix: s,
            intervalEndUnix: s + 120,
            zeroContactRunStartUnix: s - 4_000,
            lastZeroContactUnix: s - 3_600
        ))
    }

    func testMissingZeroEvidenceFailsClosed() {
        let s = start.timeIntervalSince1970
        XCTAssertFalse(C.offWristProvenAcross(
            intervalStartUnix: s,
            intervalEndUnix: s + 7_200,
            zeroContactRunStartUnix: nil,
            lastZeroContactUnix: nil
        ))
    }

    func testEdgeSlackIsBoundedAgainstPhantomWindows() {
        // Wide enough for contact-stability delay, tiny against the
        // multi-hour phantom windows it exists to stop.
        XCTAssertGreaterThanOrEqual(C.offWristEdgeProofSlack, 60)
        XCTAssertLessThanOrEqual(C.offWristEdgeProofSlack, 300)
    }

    // MARK: Off-wrist exclusion tally

    private func isolatedDefaults() throws -> UserDefaults {
        let name = "AtriaGapWearClassificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testTallySumsRecordedSpans() throws {
        let defaults = try isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_756_100_000)
        let s = now.timeIntervalSince1970
        XCTAssertTrue(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s - 7_200, endUnix: s - 3_600,
            now: now, defaults: defaults))
        XCTAssertTrue(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s - 1_800, endUnix: s - 600,
            now: now, defaults: defaults))
        XCTAssertEqual(C.OffWristExclusion.excludedSeconds(now: now,
                                                           defaults: defaults),
                       4_800, accuracy: 0.5)
    }

    func testTallyCountsOverlapOnce() throws {
        let defaults = try isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_756_100_000)
        let s = now.timeIntervalSince1970
        XCTAssertTrue(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s - 3_600, endUnix: s - 1_200,
            now: now, defaults: defaults))
        XCTAssertTrue(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s - 2_400, endUnix: s - 600,
            now: now, defaults: defaults))
        XCTAssertEqual(C.OffWristExclusion.excludedSeconds(now: now,
                                                           defaults: defaults),
                       3_000, accuracy: 0.5)
    }

    func testTallyDropsSpansPastRetention() throws {
        let defaults = try isolatedDefaults()
        let recorded = Date(timeIntervalSince1970: 1_756_100_000)
        let s = recorded.timeIntervalSince1970
        XCTAssertTrue(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s - 3_600, endUnix: s - 600,
            now: recorded, defaults: defaults))
        let later = recorded.addingTimeInterval(
            C.OffWristExclusion.retention + 3_700
        )
        XCTAssertEqual(C.OffWristExclusion.excludedSeconds(now: later,
                                                           defaults: defaults),
                       0)
    }

    func testTallyRejectsMalformedSpans() throws {
        let defaults = try isolatedDefaults()
        let now = Date(timeIntervalSince1970: 1_756_100_000)
        let s = now.timeIntervalSince1970
        XCTAssertFalse(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s, endUnix: s, now: now, defaults: defaults))
        XCTAssertFalse(C.OffWristExclusion.recordExcludedSpan(
            startUnix: s, endUnix: s - 60, now: now, defaults: defaults))
        XCTAssertFalse(C.OffWristExclusion.recordExcludedSpan(
            startUnix: .nan, endUnix: s, now: now, defaults: defaults))
        XCTAssertEqual(C.OffWristExclusion.excludedSeconds(now: now,
                                                           defaults: defaults),
                       0)
    }

    // MARK: Presentation split

    private func ledgerWindow(startOffset: TimeInterval,
                              endOffset: TimeInterval?) -> AtriaHistoricalGapLedger.Window {
        .init(start: start.addingTimeInterval(startOffset),
              end: endOffset.map { start.addingTimeInterval($0) },
              reason: "test")
    }

    func testClassifiedBacklogSplitsServedWindowsFromLiveOnes() {
        let now = start.addingTimeInterval(20_000)
        let cursor = start.addingTimeInterval(8_000).timeIntervalSince1970
        let split = AtriaHomeRecoverySyncPresentation.classifiedGapBacklog(
            windows: [
                ledgerWindow(startOffset: 0, endOffset: 3_600),       // served
                ledgerWindow(startOffset: 10_000, endOffset: 13_600)  // pending
            ],
            now: now,
            drainCursorUnix: cursor,
            abandonedThroughUnix: 0,
            terminallyStalled: false
        )
        XCTAssertEqual(split.provenUnrecoverable, 3_600, accuracy: 0.5)
        XCTAssertEqual(split.recoverable, 3_600, accuracy: 0.5)
    }

    func testClassifiedBacklogKeepsIndeterminateWindowsRecoverable() {
        // No cursor, no watermark, no stall: nothing is proven dead, so the
        // whole backlog stays visible as fillable.
        let split = AtriaHomeRecoverySyncPresentation.classifiedGapBacklog(
            windows: [ledgerWindow(startOffset: 0, endOffset: 3_600)],
            now: start.addingTimeInterval(20_000),
            drainCursorUnix: 0,
            abandonedThroughUnix: 0,
            terminallyStalled: false
        )
        XCTAssertEqual(split.recoverable, 3_600, accuracy: 0.5)
        XCTAssertEqual(split.provenUnrecoverable, 0)
    }

    func testSummaryTextsNameBothKindsOfTime() {
        let summary = AtriaHomeRecoverySyncPresentation.GapBacklogSummary(
            recoverableSeconds: 4_320,
            provenUnrecoverableSeconds: 0,
            offWristExcludedSeconds: 11_160
        )
        XCTAssertEqual(summary.recoverableText, "1.2h of gaps")
        XCTAssertEqual(summary.offWristExcludedText, "3.1h off wrist excluded")
    }

    func testSummaryTextsStaySilentUnderAMinute() {
        let summary = AtriaHomeRecoverySyncPresentation.GapBacklogSummary(
            recoverableSeconds: 30,
            provenUnrecoverableSeconds: 0,
            offWristExcludedSeconds: 45
        )
        XCTAssertNil(summary.recoverableText)
        XCTAssertNil(summary.offWristExcludedText)
    }

    // MARK: Banner affordance

    func testBannerHidesSyncWhenEveryWindowIsProvablyDead() {
        let copy = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 900,
            protectsLiveStream: false,
            secondsSinceLastFlush: 60,
            backgroundLeaseActive: true,
            backlogPending: true,
            ledgerRecoverableSeconds: 0,
            ledgerProvenUnrecoverableSeconds: 3_600
        )
        XCTAssertFalse(copy.offersRecovery)
        XCTAssertEqual(copy.title, "Earlier gap can't be refilled")
    }

    func testBannerKeepsSyncWhileAnyRecoverableTimeRemains() {
        let copy = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 900,
            protectsLiveStream: false,
            secondsSinceLastFlush: 60,
            backgroundLeaseActive: true,
            backlogPending: true,
            ledgerRecoverableSeconds: 3_600,
            ledgerProvenUnrecoverableSeconds: 7_200
        )
        XCTAssertTrue(copy.offersRecovery)
    }

    func testBannerWithoutClassificationIsUnchanged() {
        // Callers that gathered no verdicts pass nil and keep today's copy.
        let copy = AtriaMissedDataBannerPresentation.copy(
            strapPendingRecords: 900,
            protectsLiveStream: false,
            secondsSinceLastFlush: 60,
            backgroundLeaseActive: true,
            backlogPending: true
        )
        XCTAssertTrue(copy.offersRecovery)
    }

    // MARK: BLE gap-open sites (source structure)

    private func bleManagerSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria")
        return try String(
            contentsOf: appDirectory.appendingPathComponent("AtriaBLEManager.swift"),
            encoding: .utf8
        )
    }

    func testAcceptedHRGapOpenIsOffWristSuppressed() throws {
        let source = try bleManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func recordAcceptedHRSample(rate: Int, at sampleTime: Date) {"
        ))
        let end = try XCTUnwrap(source.range(
            of: "fileprivate func record(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("AtriaGapWearClassification.offWristProvenAcross("),
            "the silent-link gap-open must consult the zero-contact run"
        )
        XCTAssertTrue(
            body.contains("!hadOpenMissingWindow, !offWristProven,"),
            "a proven off-wrist interval must not mint a recoverable window"
        )
        XCTAssertTrue(
            body.contains("off_wrist_no_recoverable_gap"),
            "the suppression must reuse the disconnect path's skip token"
        )
    }

    func testIngressOverflowGapOpenIsOffWristSuppressed() throws {
        let source = try bleManagerSource()
        let start = try XCTUnwrap(source.range(
            of: "private func recordHeartRateIngressOverflow("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func handleParsedRealtimePacket(",
            range: start.upperBound..<source.endIndex
        ))
        let body = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(
            body.contains("AtriaGapWearClassification.offWristProvenAcross(")
        )
        XCTAssertTrue(
            body.contains("continuityRelevant && !offWristProven"),
            "a pulseless flooding stream must not mint a recoverable window"
        )
    }

    func testZeroContactRunIsStampedBeforeContactFlagClears() throws {
        let source = try bleManagerSource()
        let stamp = try XCTUnwrap(source.range(
            of: "lastZeroContactAt = sampleTime"
        ))
        let clear = try XCTUnwrap(source.range(
            of: "assignIfChanged(\\.hasContact, false)",
            range: stamp.upperBound..<source.endIndex
        ))
        XCTAssertLessThan(
            source.distance(from: stamp.upperBound, to: clear.lowerBound),
            120,
            "entry-time contact decides a fresh run; the stamp must precede the clear"
        )
    }
}
