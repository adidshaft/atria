import XCTest
@testable import Atria

/// Sleep-stage convergence coverage (2026-08-29).
///
/// Two device-verified starvation causes are pinned here:
/// 1. Auto-confirm minted NO estimate segments (`allowHROnlyEstimate` was
///    never passed on the auto lanes) — a dense-HR motion-insufficient night
///    persisted stage-less forever.
/// 2. The stage engine saw session HR only. Confirmed windows routinely span
///    multi-hour session holes whose HR exists only in the drained
///    `HistoricalArchive`; the density gate then correctly failed, so stages
///    could never converge even after the drain caught up. The cooperative
///    backfill lane now unions bounded archive HR into the STAGE INPUTS
///    (and the refresh trigger's candidate-sample count) — never into
///    durations, coverage, or persisted metrics.
final class AtriaSleepStageArchiveUnionTests: XCTestCase {
    private let calendar = Calendar.current

    // MARK: - 1. Auto-confirm mints labeled estimate stages

    func testAutoConfirmMaterializationMintsLabeledEstimateStagesOnDenseHROnlyNight() throws {
        let now = calendar.startOfDay(for: Date())
            .addingTimeInterval(9 * 60 * 60)
        let start = now.addingTimeInterval(-10 * 60 * 60)
        // Dense HR-only fixture: 5s cadence stays under the compact lane's
        // 4,096-row staging budget while beating the >=6 samples/min density
        // gate; no recovered motion epochs anywhere (pure HR-only night).
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(5 * 60 * 60),
            label: "HR-only overnight",
            points: stride(from: 0, through: 5 * 60 * 60, by: 5).map {
                .init(t: Double($0), bpm: 60 + (($0 / 5) % 2))
            }
        )
        // Auto-confirm requires qualified RR across >=60% of the window
        // (2026-08-14 P1.10); the stream spans the whole five hours.
        session.rrPoints = (0..<(5 * 60 * 60)).map {
            .init(
                t: Double($0),
                ms: 1_000,
                source: .standardHeartRateMeasurement2A37
            )
        }
        let proposal = try withEmptyDeviceUseJournal {
            try SessionStore.makeForegroundSleepSettlementProposal(
                fingerprint: makeFingerprint(),
                canonicalSessions: [session],
                activeJournalSession: nil,
                now: now,
                rest: 60,
                maxHR: 190,
                learnedWindow: nil,
                lookbackDays: 2,
                maximumSessions: 64,
                historicalMotionPolicy: .attachedCompactOnly,
                cooperativeDeadline: .init(
                    uptimeNanoseconds:
                        DispatchTime.now().uptimeNanoseconds
                            + 10_000_000_000
                ),
                autoConfirmLimit: 2
            )
        }
        let materialization = try XCTUnwrap(
            proposal.preparedStrongCandidates.first,
            "the dense HR-only night must remain a strong auto-confirmable candidate"
        )
        let segments = try XCTUnwrap(
            materialization.stageSegments,
            "auto-confirm must now mint HR-only ESTIMATE segments instead of persisting stage-less"
        )
        XCTAssertFalse(segments.isEmpty)
        XCTAssertTrue(
            SleepStageSegment.allHREstimateProvenance(segments),
            "auto-confirmed HR-only staging must carry estimate id prefixes so it can only render through the labeled-estimate lane"
        )
        XCTAssertTrue(AtriaSleepStageIntegrity.validates(
            segments,
            start: materialization.candidate.start,
            end: materialization.candidate.end,
            duration: materialization.candidate.duration,
            span: materialization.candidate.span
        ))
        // The persisted record renders through the honest estimate tier, never
        // as validated stages.
        let night = SleepHistorySnapshot.Night(
            id: "auto-hr-only-night",
            day: materialization.candidate.start,
            start: materialization.candidate.start,
            end: materialization.candidate.end,
            duration: materialization.candidate.duration,
            restingHR: 60,
            hrv: nil,
            respiratoryRate: materialization.respiratoryRate,
            sleepEfficiency: nil,
            confidence: materialization.classification.confidence,
            source: materialization.classification.source,
            confirmed: true,
            stageSegments: segments,
            eventTimeZoneIdentifier: TimeZone.current.identifier
        )
        XCTAssertEqual(night.stageEvidence, .hrOnlyEstimate,
                       "estimate-prefixed segments must resolve to the labeled estimate tier")
    }

    // MARK: - 2. Archive-HR union fills session holes for stage evidence

    func testCooperativeStageInputsUnionArchiveHeartRateAcrossSessionHoles() throws {
        let start = Date(timeIntervalSinceReferenceDate: 805_316_709)
        let span: TimeInterval = 6 * 60 * 60
        let end = start.addingTimeInterval(span)
        // Sessions cover only the first 40% of the confirmed window.
        let coveredSeconds = Int(span * 0.4)
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(TimeInterval(coveredSeconds)),
            label: "Partial capture",
            points: stride(from: 0, to: coveredSeconds, by: 5).map {
                .init(t: Double($0), bpm: 58 + (($0 / 5) % 2))
            }
        )
        // Drained archive covers the remaining 60%.
        let archive: [AtriaSleepWakeResearch.HeartSample] = stride(
            from: coveredSeconds,
            to: Int(span),
            by: 5
        ).map {
            .init(t: start.addingTimeInterval(TimeInterval($0)),
                  bpm: 57 + (($0 / 5) % 2))
        }
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 10_000_000_000
        )
        let sessionOnly = try SessionStore.sleepStageResearchSegments(
            from: [session],
            start: start,
            end: end,
            restingHR: 58,
            isNap: false,
            motionValidated: false,
            allowHROnlyEstimate: true,
            maximumRows: Int.max,
            cooperativeDeadline: deadline
        )
        XCTAssertTrue(sessionOnly.isEmpty,
                      "40% session coverage must keep failing the density gate on its own")
        let unioned = try SessionStore.sleepStageResearchSegments(
            from: [session],
            start: start,
            end: end,
            restingHR: 58,
            isNap: false,
            motionValidated: false,
            allowHROnlyEstimate: true,
            extraHeartSamples: archive,
            maximumRows: Int.max,
            cooperativeDeadline: deadline
        )
        XCTAssertFalse(unioned.isEmpty,
                       "archive HR across the session hole must produce dense evidence and mint estimate segments")
        XCTAssertTrue(SleepStageSegment.allHREstimateProvenance(unioned),
                      "archive-unioned HR-only staging stays in the labeled estimate lane")
    }

    func testUnionSampleCountDedupesOnTimestampWithSessionPointsWinning() throws {
        let start = Date(timeIntervalSinceReferenceDate: 805_316_709)
        let end = start.addingTimeInterval(600)
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Overlap",
            points: (0..<100).map { .init(t: Double($0), bpm: 60) }
        )
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )
        // Fully colliding extras (same seconds, different bpm) add nothing.
        let colliding: [AtriaSleepWakeResearch.HeartSample] = (0..<100).map {
            .init(t: start.addingTimeInterval(Double($0)), bpm: 90)
        }
        XCTAssertEqual(
            try SessionStore.sleepStageResearchSampleCount(
                from: [session],
                start: start,
                end: end,
                extraHeartSamples: colliding,
                cooperativeDeadline: deadline
            ),
            100,
            "session points win timestamp collisions — colliding archive rows must not inflate the count"
        )
        // Disjoint extras count once each; duplicate extras dedupe against
        // each other; out-of-window and non-positive rows contribute nothing.
        var disjoint: [AtriaSleepWakeResearch.HeartSample] = (100..<150).map {
            .init(t: start.addingTimeInterval(Double($0)), bpm: 62)
        }
        disjoint.append(.init(t: start.addingTimeInterval(120), bpm: 70))
        disjoint.append(.init(t: start.addingTimeInterval(-30), bpm: 62))
        disjoint.append(.init(t: end.addingTimeInterval(30), bpm: 62))
        disjoint.append(.init(t: start.addingTimeInterval(130), bpm: 0))
        XCTAssertEqual(
            try SessionStore.sleepStageResearchSampleCount(
                from: [session],
                start: start,
                end: end,
                extraHeartSamples: disjoint,
                cooperativeDeadline: deadline
            ),
            150
        )
        // No extras keeps the historical session-only count byte-for-byte.
        XCTAssertEqual(
            try SessionStore.sleepStageResearchSampleCount(
                from: [session],
                start: start,
                end: end,
                cooperativeDeadline: deadline
            ),
            100
        )
    }

    // MARK: - 3. Archive growth retriggers the refresh gate

    func testRefreshTriggersWhenArchiveSamplesGrowWithoutSessionGrowth() throws {
        let start = Date(timeIntervalSinceReferenceDate: 805_316_709)
        let end = start.addingTimeInterval(600)
        let session = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Confirmed-at",
            points: (0..<100).map { .init(t: Double($0), bpm: 60) }
        )
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )
        let existingSamples = try SessionStore.sleepStageResearchSampleCount(
            from: [session],
            start: start,
            end: end,
            cooperativeDeadline: deadline
        )
        let drained: [AtriaSleepWakeResearch.HeartSample] = (200..<400).map {
            .init(t: start.addingTimeInterval(Double($0)), bpm: 58)
        }
        let candidateSamples = try SessionStore.sleepStageResearchSampleCount(
            from: [session],
            start: start,
            end: end,
            extraHeartSamples: drained,
            cooperativeDeadline: deadline
        )
        XCTAssertGreaterThan(candidateSamples, existingSamples)
        XCTAssertTrue(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: existingSamples,
            candidateSamples: candidateSamples,
            existingDuration: 600,
            candidateCoverage: 600
        ), "a night whose holes drained AFTER confirmation must retry its stage refresh")
        // Fully colliding archive rows are not growth — no spurious retrigger.
        let colliding: [AtriaSleepWakeResearch.HeartSample] = (0..<100).map {
            .init(t: start.addingTimeInterval(Double($0)), bpm: 58)
        }
        let collidingCandidate = try SessionStore.sleepStageResearchSampleCount(
            from: [session],
            start: start,
            end: end,
            extraHeartSamples: colliding,
            cooperativeDeadline: deadline
        )
        XCTAssertFalse(SessionStore.shouldRefreshUserAdjustedSleepEvidence(
            source: "user_adjusted_sleep",
            existingSamples: existingSamples,
            candidateSamples: collidingCandidate,
            existingDuration: 600,
            candidateCoverage: 600
        ))
    }

    // MARK: - 4. Withheld/unusable archive rows never become stage evidence

    func testArchiveExactWindowReaderExcludesPhysiologyWithheldRows() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "atria-stage-union-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(600)
        func row(unix: UInt32,
                 bpm: Int,
                 metricUsable: Bool) -> [String: Any] {
            [
                "metricUsable": metricUsable,
                "layoutVersion": HistoricalArchive.layoutVersion,
                "clockCorrectionStatus": "clock_ref_present",
                "gravityValidated": true,
                "whoofHR17": bpm,
                "unix7": unix,
                "currentSessionUsable": false,
            ]
        }
        let baseUnix = UInt32(start.timeIntervalSince1970)
        let rows: [[String: Any]] = [
            row(unix: baseUnix + 10, bpm: 62, metricUsable: true),
            // Physiology-withheld frame: excluded regardless of its HR value.
            row(unix: baseUnix + 20, bpm: 70, metricUsable: false),
            // Off-wrist HR==0: excluded by the physiologic bpm bound.
            row(unix: baseUnix + 30, bpm: 0, metricUsable: true),
        ]
        let lines = try rows.map { object -> String in
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        }
        let fileURL = directory.appendingPathComponent("chunk-0001.jsonl")
        try (lines.joined(separator: "\n") + "\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let read = try XCTUnwrap(HistoricalArchive.exactMetricHeartRatePoints(
            in: [fileURL],
            catalog: nil,
            archiveRoot: directory,
            start: start,
            end: end,
            maximumPoints: 10
        ))
        XCTAssertEqual(read.points.map(\.bpm), [62],
                       "only metric-usable, physiologic rows may become stage evidence")
    }

    func testArchiveStageEvidenceFetchIsRecencyBoundedAndFailClosed() {
        let now = Date()
        let recentEnd = now.addingTimeInterval(-60 * 60)
        let recentStart = recentEnd.addingTimeInterval(-6 * 60 * 60)
        var readerCalls = 0
        let samples = SessionStore.archiveStageEvidenceHeartSamples(
            start: recentStart,
            end: recentEnd,
            now: now,
            reader: { _, _, maximumPoints in
                readerCalls += 1
                XCTAssertEqual(
                    maximumPoints,
                    SessionStore.stageEvidenceArchiveHRMaximumPoints
                )
                return .init(
                    points: [.init(t: recentStart.addingTimeInterval(30),
                                   bpm: 61)],
                    scannedFileCount: 1,
                    scannedByteCount: 100
                )
            }
        )
        XCTAssertEqual(readerCalls, 1)
        XCTAssertEqual(samples.map(\.bpm), [61])
        // A failed (nil) exact-window read contributes nothing.
        XCTAssertTrue(SessionStore.archiveStageEvidenceHeartSamples(
            start: recentStart,
            end: recentEnd,
            now: now,
            reader: { _, _, _ in nil }
        ).isEmpty)
        // Beyond the recency bound the reader is never consulted: the
        // cooperative lane must not rescan deep history window-by-window.
        var staleReaderCalls = 0
        let staleEnd = now.addingTimeInterval(
            -(SessionStore.stageEvidenceArchiveHRRecencyDays * 86_400 + 3_600)
        )
        XCTAssertTrue(SessionStore.archiveStageEvidenceHeartSamples(
            start: staleEnd.addingTimeInterval(-6 * 60 * 60),
            end: staleEnd,
            now: now,
            reader: { _, _, _ in
                staleReaderCalls += 1
                return nil
            }
        ).isEmpty)
        XCTAssertEqual(staleReaderCalls, 0)
    }

    // MARK: - 5. Durations/metrics stay session-derived (regression pin)

    func testArchiveUnionFeedsStageEvidenceOnlyNeverDurationsOrMetrics() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private nonisolated static func refreshedUserAdjustedSleepEvidenceIfNeeded("
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func backfillConfirmedSleepStagesFromSessions",
            range: start.upperBound..<source.endIndex
        ))
        let refreshPath = String(source[start.lowerBound..<end.lowerBound])
        // Archive HR reaches exactly two consumers: the refresh trigger's
        // candidate-sample count and the stage-evidence gather.
        XCTAssertEqual(
            refreshPath.components(
                separatedBy: "extraHeartSamples: archiveHeartSamples"
            ).count - 1,
            2
        )
        // Coverage, metrics, duration, and respiration stay session-derived:
        // no archive samples flow into any of their derivations.
        for token in [
            "confirmedSleepSensorCoverage(\n            from: sourceSessions,",
            "confirmedSleepWindowMetrics(\n            from: sourceSessions,",
            "let duration = min(sleep.span, sensorCovered)",
        ] {
            XCTAssertTrue(refreshPath.contains(token),
                          "Missing session-derived token: \(token)")
        }
        XCTAssertFalse(refreshPath.contains(
            "confirmedSleepSensorCoverage(\n            from: sourceSessions,\n            extraHeartSamples"
        ))
        // The backfill loop fetches archive HR for stage-less records only —
        // staged nights never re-pay the stager pass-over-pass.
        let backfillStart = try XCTUnwrap(source.range(
            of: "private func backfillConfirmedSleepStagesFromSessions"
        ))
        let backfillEnd = try XCTUnwrap(source.range(
            of: "private static func confirmedSleepStagesCoverSleep",
            range: backfillStart.upperBound..<source.endIndex
        ))
        let backfill = String(
            source[backfillStart.lowerBound..<backfillEnd.lowerBound]
        )
        XCTAssertTrue(backfill.contains(
            "if sleep.stageSegments?.isEmpty != false {"
        ))
        XCTAssertTrue(backfill.contains("archiveStageEvidenceHeartSamples"))
    }

    // MARK: - Fixture helpers (mirrors AtriaCompactLatestNightSettlementTests)

    private func makeFingerprint()
        -> SessionStore.ForegroundSleepSettlementFingerprint {
        .init(
            canonicalSessionsRevision: 1,
            confirmedSleepsRevision: 1,
            restingHR: 60,
            baselineRestingIsTrusted: true,
            baselineRestingIsNearTrusted: true,
            maxHR: 190
        )
    }

    private func withEmptyDeviceUseJournal<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        let defaults = UserDefaults.standard
        let key = "atria.deviceUseJournal.v1"
        let priorValue = defaults.data(forKey: key)
        AtriaDeviceUseJournal.reset(defaults: defaults)
        defer {
            if let priorValue {
                defaults.set(priorValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return try body()
    }
}
