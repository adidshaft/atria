import XCTest
@testable import Atria

/// Handoff-12: current-sleep review admission (terminal + observable), the
/// shifted-morning seam tolerance measured on the physical Aug-13 candidate,
/// bounded starvation repairs, stress gap receipts, and the clamped chart
/// pointer placement policy.
final class AtriaHandoff12Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        suiteName = "AtriaHandoff12Tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    // MARK: - CP1: the physical Aug-13 two-session shape

    /// 09:56:03–10:36:23 + 10:39:07–13:39:05 (164 s reconnect seam), dense
    /// ~61–63 bpm HR/RR against resting 58 — the exact physical evidence the
    /// previous 60 s span tolerance silently discarded. It must now produce
    /// exactly one unconfirmed review candidate.
    func testPhysicalAug13TwoSessionShapeQualifiesForReview() throws {
        let (sessions, now) = physicalCandidateSessions(seamSeconds: 164)
        let projection = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: 58,
            maxHR: 190,
            cooperativeDeadline: .init(uptimeNanoseconds: .max,
                                       monotonicNow: { 0 })
        )
        _ = now
        let main = try XCTUnwrap(projection.main,
                                 "the seam-bearing dense candidate must surface")
        XCTAssertFalse(main.confirmed)
        XCTAssertNotEqual(main.motionValidated, true)
        let duration = main.duration
        XCTAssertGreaterThan(duration, 3 * 3_600)
        XCTAssertLessThan(duration, 4 * 3_600)
    }

    /// The morning-tier seam boundary is exact: the diagnosis names a seam
    /// beyond 300 s. (A large-seam cluster may still surface through the
    /// separate fragmented lane, which allows up to 2 h gaps with its own
    /// stricter span floor — that lane is review-only too and unchanged.)
    func testSeamAboveToleranceIsNamedByTheDiagnosis() {
        let (sessions, _) = physicalCandidateSessions(seamSeconds: 360)
        XCTAssertEqual(
            SessionStore.sleepReviewAdmissionDiagnosis(sessions: sessions,
                                                       rest: 58),
            "morning_tier_span_seam_exceeded",
            "the decision receipt must name the exact failing gate"
        )
        let (withinTolerance, _) = physicalCandidateSessions(seamSeconds: 164)
        XCTAssertNotEqual(
            SessionStore.sleepReviewAdmissionDiagnosis(
                sessions: withinTolerance,
                rest: 58
            ),
            "morning_tier_span_seam_exceeded",
            "the physical 164 s seam sits inside the allowance"
        )
    }

    /// The elevated 21:00–09:23 physiology (mean 73–90 bpm) can never be
    /// appended or auto-confirmed as sleep merely to match a recollection.
    func testElevatedOvernightSpanCannotQualify() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let start = dayStart.addingTimeInterval(-3 * 3_600) // 21:00 prior day
        let duration: TimeInterval = 6 * 3_600
        let session = denseSession(start: start,
                                   duration: duration,
                                   bpm: { 76 + ($0 / 600) % 12 })
        let now = start.addingTimeInterval(duration + 3 * 3_600)
        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [session],
            now: now,
            deadlineUptimeNanoseconds: .max
        ).get()
        let projection = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: slice.sessions,
            confirmedSleeps: [],
            rest: 58,
            maxHR: 190,
            cooperativeDeadline: .init(uptimeNanoseconds: .max,
                                       monotonicNow: { 0 })
        )
        XCTAssertNil(projection.main,
                     "mean ~80 bpm against resting 58 is awake, not sleep")
        XCTAssertEqual(
            SessionStore.sleepReviewAdmissionDiagnosis(sessions: slice.sessions,
                                                       rest: 58),
            "mean_hr_above_sleep_band"
        )
    }

    func testAdmissionDiagnosisNamesEmptyAndClockGates() {
        XCTAssertEqual(
            SessionStore.sleepReviewAdmissionDiagnosis(sessions: [], rest: 58),
            "no_recent_sessions"
        )
    }

    // MARK: - CP1: admission receipt ring

    func testAdmissionReceiptRingIsBoundedAndDecodes() throws {
        for index in 0..<12 {
            SessionStore.recordSleepReviewAdmissionReceipt(
                .init(attemptedAtUnix: Double(index),
                      source: "test",
                      sourceRevisionKey: "rev-\(index)",
                      strapPseudonymousID: nil,
                      candidateStartUnix: nil,
                      candidateEndUnix: nil,
                      candidateDuration: nil,
                      heartRateRows: index,
                      rrRows: 0,
                      gateResult: "qualified",
                      compactMotionOutcome: "qualified_not_saved",
                      frontierUnix: 0,
                      pendingStoreOutcome: "saved",
                      finalOutcome: "saved_review"),
                defaults: defaults
            )
        }
        let ring = SessionStore.loadSleepReviewAdmissionReceipts(
            defaults: defaults
        )
        XCTAssertEqual(ring.count,
                       SessionStore.sleepReviewAdmissionReceiptCapacity)
        XCTAssertEqual(ring.last?.sourceRevisionKey, "rev-11",
                       "newest attempt survives; oldest four rolled off")
        XCTAssertEqual(ring.first?.sourceRevisionKey, "rev-4")
    }

    // MARK: - CP0/CP1: coverage-failure suppression is now time-bounded

    func testCoverageFailureEqualitySuppressionIsTimeBounded() {
        let now = Date()
        // Equal fingerprints inside the retry interval still suppress.
        XCTAssertTrue(
            AtriaBLEManager.shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                cachedFingerprint: "fp", currentFingerprint: "fp",
                cachedAt: now.addingTimeInterval(-3_600), now: now
            )
        )
        // The physically observed starvation: equality used to suppress with
        // no clock term at all. A stale cache must now allow the retry.
        XCTAssertFalse(
            AtriaBLEManager.shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                cachedFingerprint: "fp", currentFingerprint: "fp",
                cachedAt: now.addingTimeInterval(-25 * 3_600), now: now
            )
        )
        // Legacy caches without a timestamp stay conservative (suppressed).
        XCTAssertTrue(
            AtriaBLEManager.shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                cachedFingerprint: "fp", currentFingerprint: "fp",
                cachedAt: nil, now: now
            )
        )
        // Changed fingerprints keep the pre-existing bounded behavior.
        XCTAssertFalse(
            AtriaBLEManager.shouldSuppressUnchangedTerminalConsumerCoverageFailure(
                cachedFingerprint: "fp", currentFingerprint: "fp2",
                cachedAt: now.addingTimeInterval(-25 * 3_600), now: now
            )
        )
    }

    // MARK: - CP0: proof-disconnect context record

    func testProofDisconnectContextRoundTrips() throws {
        let context = AtriaBLEManager.ProtectedR10ProofDisconnectContext(
            atUnix: 1_786_585_209,
            decision: "ambient_or_unattributed",
            errorDomain: "CBErrorDomain",
            errorCode: 6,
            centralState: 5,
            confirmedNotifyUUIDs: "AAA,BBB",
            framesAfterActivation: 0,
            crcRejectedFrames: 3,
            activationAgeSeconds: 2_844,
            proofStartedAgeSeconds: 2_873,
            connectedDurationSeconds: 3_105,
            owner: "protected_redp_v9",
            ownerState: "proving",
            ownerGenerationUnix: 1_786_582_104,
            lastRollbackReason: "passive_reprobe_after_stable_hr",
            ambientDisconnectIntervalSeconds: 41
        )
        let data = try JSONEncoder().encode(context)
        let decoded = try JSONDecoder().decode(
            AtriaBLEManager.ProtectedR10ProofDisconnectContext.self,
            from: data
        )
        XCTAssertEqual(decoded.errorCode, 6)
        XCTAssertEqual(decoded.crcRejectedFrames, 3,
                       "decoder rejection is finally distinguishable from silence")
        XCTAssertEqual(decoded.decision, "ambient_or_unattributed")
        XCTAssertEqual(decoded.framesAfterActivation, 0)
    }

    // MARK: - CP2: stress gap receipts

    func testGapReceiptsSeparateSourceClassesHonestly() throws {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let now = base.addingTimeInterval(2 * 3_600)
        // One dense hour of 1 Hz HR ending an hour before `now`; the last
        // hour has no HR at all (a real outage / not-yet-durable tail).
        let dense = denseSession(start: base,
                                 duration: 3_600,
                                 bpm: { _ in 70 })
        // Facts produced for the first 30 dense minutes only.
        var produced: [AtriaPhysiologicalStressModel.MinuteFact] = []
        for index in 5..<35 {
            if let fact = AtriaPhysiologicalStressModel.evaluate(
                windowInput(endingAt: base.addingTimeInterval(
                    Double(index) * 60
                ))
            ) { produced.append(fact) }
        }
        let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
            sessions: [dense],
            producedFacts: produced,
            activeJournalSpan: nil,
            now: now,
            windowHours: 2
        )
        AtriaHistoricalStressReplay.finalizeGapReceipts(
            draft: draft,
            mergedStoreMinutes: [],
            now: now,
            defaults: defaults
        )
        let data = try XCTUnwrap(defaults.data(
            forKey: AtriaHistoricalStressReplay.gapReceiptKey
        ))
        let summary = try JSONDecoder().decode(
            AtriaHistoricalStressReplay.GapReceiptSummary.self,
            from: data
        )
        XCTAssertGreaterThan(summary.qualifiedAndReconciled, 0,
                             "scored minutes count as reconciled")
        XCTAssertGreaterThan(summary.sourceNotYetDurable, 0,
                             "minutes past the newest HR row are named, not blamed")
        XCTAssertGreaterThan(
            summary.insufficientHRSamples + summary.rawHRGap
                + summary.insufficientHRSpan,
            0,
            "the true outage classifies as an evidence shortfall"
        )
        XCTAssertLessThanOrEqual(
            summary.missingMinutes.count,
            AtriaHistoricalStressReplay.gapReceiptMinuteCap
        )
        // Handoff-13 CP2: categories sum exactly to the window's minute keys.
        let total = summary.presentInMergedStore
            + summary.qualifiedAndReconciled + summary.rawHRGap
            + summary.insufficientHRSpan + summary.insufficientHRSamples
            + summary.sourceNotYetDurable
            + summary.activeJournalRowCapDeferred + summary.kernelDeclined
        XCTAssertEqual(total, draft.classesByMinute.count)
    }

    /// Handoff-13 CP2: a minute already present in the merged store can never
    /// be called missing, and a shortfall inside the unsealed active journal's
    /// span is a named row-cap deferral, not a generic evidence failure.
    func testGapReceiptsHonorMergedStoreAndActiveJournalRowCap() throws {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let now = base.addingTimeInterval(2 * 3_600)
        let dense = denseSession(start: base,
                                 duration: 3_600,
                                 bpm: { _ in 70 })
        let journalStart = base.addingTimeInterval(3_600).timeIntervalSince1970
        let journalEnd = now.timeIntervalSince1970
        let draft = AtriaHistoricalStressReplay.classifyGapMinutes(
            sessions: [dense],
            producedFacts: [],
            activeJournalSpan: journalStart...journalEnd,
            now: now,
            windowHours: 2
        )
        // Pretend the merged store already has live facts for the first
        // 20 dense minutes.
        let cadence = AtriaPhysiologicalStressModel.evaluationCadence
        var merged: Set<Int> = []
        for index in 6..<26 {
            let t = base.addingTimeInterval(Double(index) * 60)
            merged.insert(Int(floor(t.timeIntervalSince1970 / cadence) * cadence))
        }
        AtriaHistoricalStressReplay.finalizeGapReceipts(
            draft: draft,
            mergedStoreMinutes: merged,
            now: now,
            defaults: defaults
        )
        let data = try XCTUnwrap(defaults.data(
            forKey: AtriaHistoricalStressReplay.gapReceiptKey
        ))
        let summary = try JSONDecoder().decode(
            AtriaHistoricalStressReplay.GapReceiptSummary.self,
            from: data
        )
        XCTAssertEqual(summary.presentInMergedStore, merged.count,
                       "live facts cannot inflate missing counts")
        XCTAssertGreaterThan(summary.activeJournalRowCapDeferred, 0,
                             "the capped active tail is deferred, not blamed")
        XCTAssertTrue(summary.missingMinutes.contains {
            $0.hasSuffix("|source_not_yet_durable(active_journal_row_cap)")
        })
        XCTAssertFalse(summary.missingMinutes.contains { entry in
            merged.contains(Int(entry.split(separator: "|")[0]) ?? -1)
        }, "no minute present in the merged store may be listed missing")
    }

    /// The reconciliation source (dense resident HR through the same batch
    /// kernel) really produces the missing minute facts — no interpolation:
    /// each fact's window is fully evidence-backed or the minute stays empty.
    @MainActor
    func testReplayKernelScoresDenseWindowAndSkipsOutage() throws {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date()).addingTimeInterval(10 * 3_600)
        let now = base.addingTimeInterval(2 * 3_600)
        var session = denseSession(start: base,
                                   duration: 30 * 60,
                                   bpm: { _ in 72 })
        // A second dense block after a 40-minute outage.
        let second = denseSession(start: base.addingTimeInterval(70 * 60),
                                  duration: 20 * 60,
                                  bpm: { _ in 74 })
        session.rrPoints = nil
        let snapshot = try XCTUnwrap(AtriaHistoricalStressReplay.snapshot(
            sessions: [session, second],
            personalization: .init(restingHeartRate: 58,
                                   maximumHeartRate: 190,
                                   restingBaselineDayCount: 20,
                                   hrvBaseline: nil),
            now: now
        ))
        let result = AtriaHistoricalStressReplay.evaluate(snapshot)
        XCTAssertFalse(result.facts.isEmpty)
        let factMinutes = Set(result.facts.map {
            Int($0.date.timeIntervalSince1970 / 60)
        })
        // A minute in the middle of the outage must stay blank.
        let outageMinute = Int(
            base.addingTimeInterval(50 * 60).timeIntervalSince1970 / 60
        )
        XCTAssertFalse(factMinutes.contains(outageMinute),
                       "no score may be interpolated across a telemetry gap")
        // A dense minute inside the first block is scored.
        let denseMinute = Int(
            base.addingTimeInterval(20 * 60).timeIntervalSince1970 / 60
        )
        XCTAssertTrue(factMinutes.contains(denseMinute))
    }

    // MARK: - CP3: pointer placement policy

    func testPointerPlacementStaysInsidePlotForEveryEdge() {
        let plot = CGRect(x: 20, y: 10, width: 320, height: 160)
        let landscape = CGRect(x: 20, y: 10, width: 700, height: 120)
        let narrow = CGRect(x: 0, y: 0, width: 150, height: 200)
        let anchors: [(CGRect, CGPoint, String)] = [
            (plot, CGPoint(x: 22, y: 90), "far left"),
            (plot, CGPoint(x: 338, y: 90), "far right"),
            (plot, CGPoint(x: 180, y: 90), "center"),
            (plot, CGPoint(x: 180, y: 12), "top band"),
            (plot, CGPoint(x: 180, y: 168), "bottom band"),
            (narrow, CGPoint(x: 75, y: 100), "narrow portrait"),
            (landscape, CGPoint(x: 690, y: 20), "landscape corner"),
        ]
        for (frame, anchor, label) in anchors {
            let card = AtriaChartPointerPlacement.frame(anchor: anchor,
                                                        plot: frame)
            XCTAssertTrue(
                frame.insetBy(dx: 2, dy: 2).contains(card)
                    || frame.contains(card),
                "\(label): card \(card) must stay inside plot \(frame)"
            )
            // The selected point itself stays visible whenever a side
            // placement was possible.
            let placement = AtriaChartPointerPlacement.place(anchor: anchor,
                                                             plot: frame)
            if !placement.usedVerticalFallback {
                XCTAssertFalse(card.contains(anchor),
                               "\(label): a side card must not cover the point")
            }
        }
    }

    // MARK: - CP3: single stress owner + compact copy

    func testVitalsScreenKeepsExactlyOneStressOwner() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let health = try String(
            contentsOf: root.appendingPathComponent("Atria/AtriaHealthScreen.swift"),
            encoding: .utf8
        )
        let sections = try String(
            contentsOf: root.appendingPathComponent(
                "Atria/AtriaVitalsCollectionSections.swift"
            ),
            encoding: .utf8
        )
        // The coordinator renders no metric row; the Live monitor remains the
        // sole interactive Stress owner on the Vitals screen.
        let coordinatorStart = try XCTUnwrap(health.range(
            of: "private struct AtriaHealthStressSection: View"
        ))
        let coordinatorEnd = try XCTUnwrap(health.range(
            of: "private final class AtriaHealthBreathworkStressStore",
            range: coordinatorStart.upperBound..<health.endIndex
        ))
        let coordinator = String(
            health[coordinatorStart.lowerBound..<coordinatorEnd.lowerBound]
        )
        XCTAssertFalse(coordinator.contains("AtriaHealthMetricRow("),
                       "the duplicate Health Monitor stress row must stay gone")
        XCTAssertTrue(coordinator.contains("Color.clear"),
                      "the coordinator contributes no layout")
        XCTAssertTrue(sections.contains("private var stressMonitor: some View"),
                      "the Live monitor owner still exists")
        // The chart no longer uses the wide top annotation; the clamped
        // plot-local card owns inspection.
        let chartStart = try XCTUnwrap(sections.range(
            of: "private struct AtriaVitalsStressTimelineChart"
        ))
        let chartEnd = try XCTUnwrap(sections.range(
            of: "private struct AtriaHeartRateExplorerPresentationRoot",
            range: chartStart.upperBound..<sections.endIndex
        ))
        let chart = String(sections[chartStart.lowerBound..<chartEnd.lowerBound])
        XCTAssertFalse(chart.contains(".annotation(position: .top"),
                       "the escaping annotation card must stay replaced")
        XCTAssertTrue(chart.contains("AtriaChartPointerPlacement.place"),
                      "the clamped placement policy owns the pointer")
        XCTAssertEqual(AtriaVitalsStressTimelineCopy.gapNote,
                       "5-min estimates · gaps are missing data")
        for forbidden in ["HR-only estimate", "Motion unavailable",
                          "lower confidence"] {
            XCTAssertFalse(
                AtriaVitalsStressTimelineCopy.gapNote.contains(forbidden),
                "the visible footer must not repeat provenance literature"
            )
        }
    }

    // MARK: - Fixtures

    private func physicalCandidateSessions(
        seamSeconds: TimeInterval
    ) -> ([SavedSession], Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let firstStart = dayStart.addingTimeInterval(
            9 * 3_600 + 56 * 60 + 3
        )
        let firstDuration: TimeInterval = 40 * 60 + 20
        let secondStart = firstStart.addingTimeInterval(
            firstDuration + seamSeconds
        )
        let secondDuration: TimeInterval = 3 * 3_600 - 2
        let first = denseSession(start: firstStart,
                                 duration: firstDuration,
                                 bpm: { 62 + ($0 / 420) % 2 })
        let second = denseSession(start: secondStart,
                                  duration: secondDuration,
                                  bpm: { 60 + ($0 / 300) % 3 })
        let now = secondStart.addingTimeInterval(secondDuration + 45 * 60)
        return ([second, first], now)
    }

    private func denseSession(
        start: Date,
        duration: TimeInterval,
        bpm: (Int) -> Int
    ) -> SavedSession {
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "H12 fixture",
            points: stride(from: 0.0, through: duration, by: 1.0).map {
                .init(t: $0, bpm: bpm(Int($0)))
            }
        )
        session.rrPoints = stride(from: 0.0, through: duration, by: 1.0).map {
            .init(t: $0, ms: 980,
                  source: .standardHeartRateMeasurement2A37)
        }
        return session
    }

    private func windowInput(
        endingAt end: Date
    ) -> AtriaPhysiologicalStressModel.WindowInput {
        let start = end.addingTimeInterval(
            -AtriaPhysiologicalStressModel.windowDuration
        )
        let samples = stride(from: 0.0, through: 300.0, by: 5.0).map {
            AtriaPhysiologicalStressModel.HeartRateSample(
                date: start.addingTimeInterval($0),
                bpm: 70,
                qualified: true
            )
        }
        return .init(
            end: end,
            heartRates: samples,
            rrIntervals: [],
            personalization: .init(restingHeartRate: 58,
                                   maximumHeartRate: 190,
                                   restingBaselineDayCount: 20,
                                   hrvBaseline: nil),
            motionContext: .init(kind: .unavailable, intensity: 0,
                                 qualified: false),
            sleepContext: .unavailable
        )
    }
}
