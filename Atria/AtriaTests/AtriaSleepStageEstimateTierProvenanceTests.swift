import XCTest
@testable import Atria

/// P2 of the 2026-08-20 sleep-stage RR track (design 1.2), Sessions side.
///
/// `allHREstimateProvenance` is the single choke point every estimate fence
/// keys on. This suite pins that the strong-RR tier extends through it
/// automatically — duration-credit fence, backfill hygiene, and the Night
/// downgrade gate — and that mixed sets always fail toward stricter
/// handling: estimate+motion mixes lose estimate provenance entirely, and
/// rr90+plain mixes fall to the standard (more hedged) confidence tier.
/// The tier itself is UI caption input only; it grants no authority.
final class AtriaSleepStageEstimateTierProvenanceTests: XCTestCase {
    // Post-2026-08-06 time base.
    private static let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(_ id: String,
                         _ stage: SleepStageKind,
                         offset: TimeInterval,
                         duration: TimeInterval) -> SleepStageSegment {
        SleepStageSegment(id: id,
                          start: Self.base.addingTimeInterval(offset),
                          end: Self.base.addingTimeInterval(offset + duration),
                          stage: stage)
    }

    /// A 6h window that passes `AtriaSleepStageIntegrity.validates`: full
    /// coverage, one interior awake hour, classified sleep 5h.
    private func integrityValidSegments(ids: (String, String, String)) -> [SleepStageSegment] {
        [
            segment(ids.0, .light, offset: 0, duration: 2 * 3_600),
            segment(ids.1, .awake, offset: 2 * 3_600, duration: 3_600),
            segment(ids.2, .deep, offset: 3 * 3_600, duration: 3 * 3_600)
        ]
    }

    private var rr90IDs: (String, String, String) {
        (SleepStageSegment.hrEstimateStrongRRIDPrefix + "a",
         SleepStageSegment.hrEstimateStrongRRIDPrefix + "b",
         SleepStageSegment.hrEstimateStrongRRIDPrefix + "c")
    }

    private var plainEstimateIDs: (String, String, String) {
        (SleepStageSegment.hrEstimateIDPrefix + "a",
         SleepStageSegment.hrEstimateIDPrefix + "b",
         SleepStageSegment.hrEstimateIDPrefix + "c")
    }

    private var motionIDs: (String, String, String) {
        (SleepStageSegment.motionReceiptIDPrefix + "a",
         SleepStageSegment.motionReceiptIDPrefix + "b",
         SleepStageSegment.motionReceiptIDPrefix + "c")
    }

    private var mixedTierIDs: (String, String, String) {
        (SleepStageSegment.hrEstimateStrongRRIDPrefix + "a",
         SleepStageSegment.hrEstimateIDPrefix + "b",
         SleepStageSegment.hrEstimateStrongRRIDPrefix + "c")
    }

    private var mixedEstimateMotionIDs: (String, String, String) {
        (SleepStageSegment.hrEstimateStrongRRIDPrefix + "a",
         SleepStageSegment.motionReceiptIDPrefix + "b",
         SleepStageSegment.hrEstimateIDPrefix + "c")
    }

    // MARK: - Choke-point prefix-set semantics

    func testAllHREstimateProvenanceAcceptsEitherEstimatePrefixAndNothingElse() {
        XCTAssertTrue(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: plainEstimateIDs)))
        XCTAssertTrue(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: rr90IDs)),
            "a pure strong-RR set is estimate provenance through the same choke point")
        XCTAssertTrue(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: mixedTierIDs)),
            "rr90+plain is still all estimate lane — the fences apply identically")

        XCTAssertFalse(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: mixedEstimateMotionIDs)),
            "estimate+motion mixes fail toward the stricter non-estimate handling")
        XCTAssertFalse(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: motionIDs)))
        XCTAssertFalse(SleepStageSegment.allHREstimateProvenance(
            integrityValidSegments(ids: ("research-legacy-a",
                                         "research-legacy-b",
                                         "research-legacy-c"))))
        XCTAssertFalse(SleepStageSegment.allHREstimateProvenance([]))
        XCTAssertFalse(SleepStageSegment.allHREstimateProvenance(nil))
    }

    func testAllStrongRREstimateProvenanceRequiresEveryIdToCarryTheStrongPrefix() {
        XCTAssertTrue(SleepStageSegment.allStrongRREstimateProvenance(
            integrityValidSegments(ids: rr90IDs)))

        XCTAssertFalse(SleepStageSegment.allStrongRREstimateProvenance(
            integrityValidSegments(ids: mixedTierIDs)),
            "a single plain-estimate id hedges the whole night down to standard")
        XCTAssertFalse(SleepStageSegment.allStrongRREstimateProvenance(
            integrityValidSegments(ids: plainEstimateIDs)))
        XCTAssertFalse(SleepStageSegment.allStrongRREstimateProvenance(
            integrityValidSegments(ids: motionIDs)))
        XCTAssertFalse(SleepStageSegment.allStrongRREstimateProvenance([]))
        XCTAssertFalse(SleepStageSegment.allStrongRREstimateProvenance(nil))
    }

    func testProvenancePrefixesAreMutuallyNonAliasing() {
        // hasPrefix-based tiering stays sound only while no provenance prefix
        // is a prefix of another. A rename that violates this would silently
        // alias tiers; fail loudly here instead.
        let prefixes = [
            SleepStageSegment.motionReceiptIDPrefix,
            SleepStageSegment.hrEstimateIDPrefix,
            SleepStageSegment.hrEstimateStrongRRIDPrefix
        ]
        for (leftIndex, left) in prefixes.enumerated() {
            for (rightIndex, right) in prefixes.enumerated() where leftIndex != rightIndex {
                XCTAssertFalse(left.hasPrefix(right),
                               "\(left) must not alias \(right)")
            }
        }
        XCTAssertEqual(SleepStageSegment.hrEstimateIDPrefixes,
                       [SleepStageSegment.hrEstimateIDPrefix,
                        SleepStageSegment.hrEstimateStrongRRIDPrefix])
    }

    // MARK: - Duration-credit fence (design 1.0: extends automatically)

    func testDurationCreditFenceSkipsStrongRRAndMixedEstimateSets() {
        let observed: TimeInterval = 6 * 3_600
        let classifiedSleep: TimeInterval = 5 * 3_600
        func credited(_ ids: (String, String, String)) -> TimeInterval {
            UserConfirmedSleep.effectiveSleepDuration(
                source: "auto_confirmed_sleep",
                observedDuration: observed,
                start: Self.base,
                end: Self.base.addingTimeInterval(observed),
                span: observed,
                stageSegments: integrityValidSegments(ids: ids)
            )
        }

        // Motion-receipt stages are duration authority: classified non-awake
        // caps the credit.
        XCTAssertEqual(credited(motionIDs), classifiedSleep, accuracy: 1)

        // Every estimate tier is display material only — measured hours stay
        // the duration source.
        XCTAssertEqual(credited(plainEstimateIDs), observed, accuracy: 1)
        XCTAssertEqual(credited(rr90IDs), observed, accuracy: 1,
                       "the strong-RR tier must never gain duration credit")
        XCTAssertEqual(credited(mixedTierIDs), observed, accuracy: 1,
                       "rr90+plain mixes stay behind the same fence")

        // An estimate+motion mix loses estimate provenance and falls to the
        // stricter classified credit of its non-estimate members.
        XCTAssertEqual(credited(mixedEstimateMotionIDs), classifiedSleep, accuracy: 1)
    }

    // MARK: - Backfill hygiene (retention through the choke point)

    private func confirmedSleep(ids: (String, String, String),
                                segments: [SleepStageSegment]? = nil,
                                source: String = "auto_confirmed_sleep") -> UserConfirmedSleep {
        let span: TimeInterval = 6 * 3_600
        return UserConfirmedSleep(id: "tier-hygiene-\(ids.0)",
                                  createdAt: Self.base.addingTimeInterval(span + 60),
                                  start: Self.base,
                                  end: Self.base.addingTimeInterval(span),
                                  source: source,
                                  confidence: "user_confirmed_hr_only",
                                  sessions: 4,
                                  samples: 4_000,
                                  avgHR: 62,
                                  peakHR: 96,
                                  restingHR: 55,
                                  hrv: 48,
                                  hrvWindowCount: 4,
                                  duration: span,
                                  span: span,
                                  reason: "rr90 hygiene fixture",
                                  motionSource: "hr_only",
                                  motionValidated: false,
                                  stageSegments: segments ?? integrityValidSegments(ids: ids),
                                  eventTimeZoneIdentifier: "GMT")
    }

    func testBackfillHygieneRetainsStrongRRAndMixedEstimateSegments() {
        XCTAssertTrue(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: plainEstimateIDs)))
        XCTAssertTrue(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: rr90IDs)),
            "strong-RR estimate segments are versioned receipts and must survive the hygiene pass")
        XCTAssertTrue(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: mixedTierIDs)))
        XCTAssertTrue(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: motionIDs)))

        // Estimate+motion mixes and unversioned legacy ids stay stripped
        // until source sessions reconstruct them.
        XCTAssertFalse(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: mixedEstimateMotionIDs)))
        XCTAssertFalse(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: ("research-legacy-a",
                                 "research-legacy-b",
                                 "research-legacy-c"))))

        // An all-awake rr90 timeline carries no sleep estimate to preserve.
        XCTAssertFalse(SessionStore.shouldPreserveConfirmedSleepStageSegments(
            confirmedSleep(ids: rr90IDs,
                           segments: [segment(rr90IDs.0,
                                              .awake,
                                              offset: 0,
                                              duration: 6 * 3_600)])))
    }

    func testUserAdjustedEpochHygieneStripRoutesThroughTheProvenanceChokePoint() throws {
        // The user-adjusted missing-motion strip cannot be reached as a pure
        // function; pin (in the repo's source-scan idiom) that its guard keys
        // on `allHREstimateProvenance` — the one choke point the strong-RR
        // tier extends through — and never on a literal single-tier prefix.
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func backfillConfirmedSleepStagesFromSessions"))
        let end = try XCTUnwrap(
            source.range(of: "private static func confirmedSleepStagesCoverSleep",
                         range: start.upperBound..<source.endIndex))
        let backfill = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(backfill.contains("!SleepStageSegment.allHREstimateProvenance("),
                      "the epoch-hygiene strip must key on the estimate choke point")
        XCTAssertFalse(backfill.contains("hasPrefix(SleepStageSegment.hrEstimateIDPrefix)"),
                       "no single-tier literal check may bypass the choke point in the backfill")
    }

    // MARK: - Night tier derivation + downgrade gate extension

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026,
                                           month: 8,
                                           day: 14,
                                           hour: hour,
                                           minute: minute))!
    }

    /// Raw engine-shaped night: 6h window, 10-minute interior awake, so the
    /// raw timeline reconciles within tolerance and the display
    /// reconciliation has an over-called awake to fold.
    private func nightSegments(ids: (String, String, String)) -> [SleepStageSegment] {
        [
            SleepStageSegment(id: ids.0, start: date(0), end: date(3), stage: .light),
            SleepStageSegment(id: ids.1, start: date(3), end: date(3, 10), stage: .awake),
            SleepStageSegment(id: ids.2, start: date(3, 10), end: date(6), stage: .deep)
        ]
    }

    private func night(ids: (String, String, String),
                       motionValidated: Bool = true,
                       confidence: String = "ready") -> SleepHistorySnapshot.Night {
        SleepHistorySnapshot.Night(id: "tier-night",
                                   day: calendar.startOfDay(for: date(6)),
                                   start: date(0),
                                   end: date(6),
                                   duration: date(6).timeIntervalSince(date(0)),
                                   restingHR: 54,
                                   hrv: 42,
                                   respiratoryRate: 12,
                                   sleepEfficiency: 0.92,
                                   confidence: confidence,
                                   source: "aggregate_sleep",
                                   confirmed: true,
                                   stageSegments: nightSegments(ids: ids),
                                   motionValidated: motionValidated)
    }

    func testStrongRRNightDerivesStrongTierBehindTheMandatoryEstimateLabel() {
        // Deliberately contradictory record-level claims (motionValidated
        // true, "ready" confidence): the downgrade gate must still fail the
        // night toward the estimate label purely from the rr90 id prefixes —
        // proof the gate extended through the choke point.
        let result = night(ids: rr90IDs)

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate,
                       "strong-RR ids are estimate provenance; no flag may promote them")
        XCTAssertEqual(result.estimateConfidenceTier, .strongRR)
        XCTAssertTrue(result.isEstimatedStageDisplay)
        XCTAssertEqual(result.stageDisplayLabel, AtriaSleepStageEstimateLabel.title,
                       "the estimate label is mandatory regardless of tier")
        XCTAssertEqual(result.stageSegments, nightSegments(ids: rr90IDs),
                       "stored segments stay untouched")
        XCTAssertFalse(result.displayStageSegments.isEmpty)
        XCTAssertTrue(result.displayStageSegments.allSatisfy {
            $0.id.hasPrefix(SleepStageSegment.hrEstimateStrongRRIDPrefix)
        }, "folding/reconciliation must preserve the incoming prefix — never re-mint plain ids")
    }

    func testMixedTierNightFailsTowardTheStandardTierButStaysLabeled() {
        let result = night(ids: mixedTierIDs)

        XCTAssertEqual(result.stageEvidence, .hrOnlyEstimate)
        XCTAssertEqual(result.estimateConfidenceTier, .standard,
                       "one plain-estimate segment hedges the whole night")
        XCTAssertEqual(result.stageDisplayLabel, AtriaSleepStageEstimateLabel.title)
    }

    func testPlainEstimateAndMotionNightsBothDeriveStandardTier() {
        XCTAssertEqual(night(ids: plainEstimateIDs).estimateConfidenceTier, .standard)

        let motionNight = night(ids: motionIDs)
        XCTAssertEqual(motionNight.estimateConfidenceTier, .standard,
                       "the tier never claims strong-RR outside the estimate lane")
        XCTAssertNotEqual(motionNight.stageEvidence, .hrOnlyEstimate,
                          "motion-receipt nights keep their unchanged evidence path")
        XCTAssertFalse(motionNight.isEstimatedStageDisplay)
    }

    // MARK: - Tier captions (new copy, new pins; generic strings unchanged)

    func testTierCaptionsArePinnedAndGenericLabelStringsAreUntouched() {
        XCTAssertEqual(AtriaSleepStageEstimateLabel.title,
                       "Estimated stages · HR-only")
        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption,
                       "Motion not available — stage boundaries are estimates from heart rate and breathing.")

        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption(for: .strongRR),
                       "Motion not available — stage boundaries are estimates from heart rate and near-continuous beat-to-beat rhythm.")
        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption(for: .standard),
                       "Motion not available — stage boundaries are rough estimates from heart rate with limited beat-to-beat rhythm data.")
        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption(for: .strongRR),
                       AtriaSleepStageEstimateLabel.strongRRCaption)
        XCTAssertEqual(AtriaSleepStageEstimateLabel.caption(for: .standard),
                       AtriaSleepStageEstimateLabel.standardCaption)

        // Three distinct captions: generic (existing pins), hedged standard,
        // and strong — the tier changes caption copy only, never the title.
        XCTAssertNotEqual(AtriaSleepStageEstimateLabel.strongRRCaption,
                          AtriaSleepStageEstimateLabel.standardCaption)
        XCTAssertNotEqual(AtriaSleepStageEstimateLabel.strongRRCaption,
                          AtriaSleepStageEstimateLabel.caption)
        XCTAssertNotEqual(AtriaSleepStageEstimateLabel.standardCaption,
                          AtriaSleepStageEstimateLabel.caption)
    }
}
