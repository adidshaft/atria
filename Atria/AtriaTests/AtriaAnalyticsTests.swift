import XCTest
@testable import Atria

final class AtriaAnalyticsTests: XCTestCase {
    func testCalibrationExamplesRemainInRange() {
        for check in AtriaAnalytics.CalibrationExamples.numericChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected) +/- \(check.tolerance), got \(check.actual)")
        }

        for check in AtriaAnalytics.CalibrationExamples.labelChecks {
            XCTAssertTrue(check.passed,
                          "\(check.name) expected \(check.expected), got \(check.actual)")
        }
    }

    func testSleepStagesIncludeREMInUserFacingOrder() {
        XCTAssertTrue(SleepStageKind.allCases.contains(.rem))
        XCTAssertEqual(SleepStageKind.rem.label, "REM")
        XCTAssertEqual(SleepStageKind.allCases.map(\.label), ["Awake", "Light", "REM", "SWS", "Deep"])
    }

    func testBiologicalAgeIsLocalEstimateAndClamped() {
        let factors = [
            AtriaAnalytics.BiologicalAge.factor(id: "vo2",
                                                label: "VO2max",
                                                ageEquivalent: 18,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "strong aerobic base"),
            AtriaAnalytics.BiologicalAge.factor(id: "sleep",
                                                label: "Sleep",
                                                ageEquivalent: 20,
                                                chronologicalAge: 45,
                                                weight: 0.50,
                                                detail: "stable sleep")
        ]

        let summary = AtriaAnalytics.BiologicalAge.summary(chronologicalAge: 45, factors: factors)
        XCTAssertEqual(summary.biologicalAge, 25)
        XCTAssertEqual(summary.ageDelta, -20)
        XCTAssertEqual(summary.agingPaceText, "Younger pace")
        XCTAssertTrue(summary.footnote.lowercased().contains("estimate"))
    }

    func testHRVAnalyzerRequiresContinuousCleanRRWindow() {
        let now = Date()
        let cleanRR = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: index.isMultiple(of: 2) ? 1_000 : 1_020,
                       expectedHR: 60)
        }

        let clean = HRVAnalyzer.analyze(cleanRR, now: now, includeTachogram: false).0
        XCTAssertEqual(clean?.readinessReason, "ready")
        XCTAssertEqual(clean?.kept, 301)
        XCTAssertEqual(clean?.rejectedOutOfRange, 0)
        XCTAssertEqual(clean?.rejectedHRMismatch, 0)
        XCTAssertTrue(clean?.isReady == true)

        let sparseRR = stride(from: 0, through: 300, by: 5).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60)
        }

        let sparse = HRVAnalyzer.analyze(sparseRR, now: now, includeTachogram: false).0
        XCTAssertEqual(sparse?.readinessReason, "gap")
        XCTAssertFalse(sparse?.isReady ?? true)
        XCTAssertGreaterThan(sparse?.maxRRGapSeconds ?? 0, HRVSnapshot.maxReadyRRGapSeconds)
    }

    func testHRVAnalyzerRejectsOutOfRangeAndHeartRateMismatch() {
        let now = Date()
        var samples = (0...300).map { index in
            RRInterval(t: now.addingTimeInterval(Double(index - 300)),
                       ms: 1_000,
                       expectedHR: 60)
        }
        samples[20] = RRInterval(t: samples[20].t, ms: 250, expectedHR: 60)
        samples[40] = RRInterval(t: samples[40].t, ms: 2_100, expectedHR: 60)
        samples[60] = RRInterval(t: samples[60].t, ms: 1_000, expectedHR: 120)

        let snapshot = HRVAnalyzer.analyze(samples, now: now, includeTachogram: false).0
        XCTAssertEqual(snapshot?.rejectedOutOfRange, 2)
        XCTAssertEqual(snapshot?.rejectedHRMismatch, 1)
        XCTAssertEqual(snapshot?.kept, 298)
        XCTAssertTrue(snapshot?.isReady == true)
    }

    func testRecoveryRefusesThinAndStaleBaselines() {
        let now = Date()
        let thinBaseline = PersonalBaseline(restingHR: 60,
                                            hrvEMA: 50,
                                            sessions: 3,
                                            updated: now,
                                            samples: baselineSamples(count: 3, now: now))

        let thin = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                    fallbackRMSSD: 55,
                                                    restingNow: 58,
                                                    baseline: thinBaseline,
                                                    sleepEfficiency: 0.90,
                                                    sleepDurationHours: 7.5)
        XCTAssertNil(thin.percent)
        XCTAssertEqual(thin.confidence, .learning)
        XCTAssertFalse(thin.usesHRV)

        let staleDate = now.addingTimeInterval(-(PersonalBaseline.staleAfter + 86_400))
        let staleBaseline = PersonalBaseline(restingHR: 60,
                                             hrvEMA: 50,
                                             sessions: PersonalBaseline.trustedMinimumSamples,
                                             updated: staleDate,
                                             samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                      now: staleDate))
        let stale = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                     fallbackRMSSD: 55,
                                                     restingNow: 58,
                                                     baseline: staleBaseline,
                                                     sleepEfficiency: 0.90,
                                                     sleepDurationHours: 7.5)
        XCTAssertNil(stale.percent)
        XCTAssertEqual(stale.confidence, .learning)
    }

    func testRecoveryUsesTrustedBaselineAndSleepEvidence() {
        let now = Date()
        let baseline = PersonalBaseline(restingHR: 60,
                                        hrvEMA: 50,
                                        sessions: PersonalBaseline.trustedMinimumSamples,
                                        updated: now,
                                        samples: baselineSamples(count: PersonalBaseline.trustedMinimumSamples,
                                                                 now: now))

        let estimate = AtriaAnalytics.Recovery.estimate(hrvSnapshot: nil,
                                                        fallbackRMSSD: 56,
                                                        restingNow: 58,
                                                        baseline: baseline,
                                                        hrvReferenceValidated: false,
                                                        sleepEfficiency: 0.91,
                                                        sleepDurationHours: 7.6)

        XCTAssertNotNil(estimate.percent)
        XCTAssertEqual(estimate.confidence, .personalBaseline)
        XCTAssertTrue(estimate.usesHRV)
        XCTAssertTrue((1...99).contains(estimate.percent ?? 0))
        XCTAssertTrue(estimate.detail.contains("lnRMSSD z"))
    }

    func testTrainingLoadFlagsUnsafeSpikesAndBalancedLoad() {
        let spike = AtriaAnalytics.TrainingLoad.summary(dailyStrains: Array(repeating: 16.0, count: 7)
                                                        + Array(repeating: 8.0, count: 21))
        XCTAssertEqual(spike.confidence, "local")
        XCTAssertEqual(spike.acwrSignal, "bad")
        XCTAssertEqual(spike.readiness, "rundown")

        let balancedHistory = [9.0, 10.0, 11.0, 9.5, 10.5, 11.0, 9.0]
            + Array(repeating: 10.0, count: 21)
        let balanced = AtriaAnalytics.TrainingLoad.summary(dailyStrains: balancedHistory)
        XCTAssertEqual(balanced.confidence, "local")
        XCTAssertEqual(balanced.acwrSignal, "good")
        XCTAssertEqual(balanced.monotonySignal, "good")
        XCTAssertEqual(balanced.readiness, "balanced")
        XCTAssertNotNil(balanced.targetBand)
    }

    func testHistoricalArchiveStatusFailsClosedUntilArchiveIsParseable() {
        let parseFailed = SessionStore.HistoricalArchiveStatus(exists: true,
                                                               parseOK: false,
                                                               rows: 12,
                                                               metricUsableRows: 4,
                                                               currentSessionUsableRows: 4,
                                                               reason: "invalid_jsonl_row_12")
        XCTAssertFalse(parseFailed.metricReady)
        XCTAssertEqual(parseFailed.valueText, "Repair")
        XCTAssertEqual(parseFailed.metricGateText, "Metric gated")
        XCTAssertEqual(parseFailed.userFootnoteText, "Archive needs repair.")

        let gated = SessionStore.HistoricalArchiveStatus(exists: true,
                                                         parseOK: true,
                                                         rows: 12,
                                                         metricUsableRows: 0,
                                                         currentSessionUsableRows: 8,
                                                         reason: "ok")
        XCTAssertFalse(gated.metricReady)
        XCTAssertEqual(gated.valueText, "Gated")
        XCTAssertEqual(gated.metricGateText, "Metric gated")
        XCTAssertTrue(gated.userFootnoteText.contains("HRV, Recovery and Sleep stay gated"))

        let ready = SessionStore.HistoricalArchiveStatus(exists: true,
                                                         parseOK: true,
                                                         rows: 12,
                                                         metricUsableRows: 3,
                                                         currentSessionUsableRows: 3,
                                                         reason: "ok")
        XCTAssertTrue(ready.metricReady)
        XCTAssertEqual(ready.valueText, "Ready")
        XCTAssertEqual(ready.metricGateText, "Metric-ready")
    }

    func testHistoricalArchiveDiagnosticsInferReplayRowsWithoutPromotingMetrics() throws {
        try withCleanHistoricalArchive {
            let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 1)
            let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                  capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                  source: "0x2f",
                                                  layoutVersion: HistoricalArchive.layoutVersion,
                                                  sequence: 7,
                                                  command: 0x16,
                                                  unix7: 1_800_000_000,
                                                  subsec11: 0,
                                                  flash13: 42,
                                                  payloadLength: payload.count,
                                                  whoofHR17: 61,
                                                  whoofRRNum18: 2,
                                                  whoofRR19: [980, 1_010],
                                                  kRR64: [980, 1_010],
                                                  gravityX36: 0,
                                                  gravityY40: 0,
                                                  gravityZ44: 1,
                                                  gravityMagnitude: 1,
                                                  gravityValidated: true,
                                                  candidateRR: ["whoof19", "k64"],
                                                  rawPayloadHex: HistoricalArchive.hex(payload),
                                                  clockDeviceRef: 1_800_000_000,
                                                  clockWallRef: 1_800_000_000,
                                                  clockDriftSeconds: 0,
                                                  clockCorrectedUnix7: 1_800_000_000,
                                                  clockCorrectionStatus: "corrected",
                                                  currentSessionUsable: false,
                                                  metricUsable: false,
                                                  usabilityReason: "provisional_historical_layout_old_or_unvalidated")

            _ = try HistoricalArchive.append(record)

            let diagnostics = HistoricalArchive.diagnostics()
            XCTAssertTrue(diagnostics.exists)
            XCTAssertTrue(diagnostics.parseOK)
            XCTAssertEqual(diagnostics.rows, 1)
            XCTAssertEqual(diagnostics.rawPayloadRows, 1)
            XCTAssertEqual(diagnostics.gravityRows, 1)
            XCTAssertEqual(diagnostics.gravityValidatedRows, 1)
            XCTAssertEqual(diagnostics.currentSessionUsableRows, 1)
            XCTAssertEqual(diagnostics.metricUsableRows, 0)
            XCTAssertEqual(diagnostics.reason, "ok")

            let status = SessionStore.HistoricalArchiveStatus(diagnostics: diagnostics)
            XCTAssertEqual(status.valueText, "Gated")
            XCTAssertFalse(status.metricReady)
        }
    }

    func testHistoricalArchiveDiagnosticsRejectIncidentalRRWithoutValidatedMotion() throws {
        try withCleanHistoricalArchive {
            let payload = historicalPayloadWithGravity(x: 0, y: 0, z: 0)
            let record = HistoricalArchive.Record(schema: HistoricalArchive.schema,
                                                  capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                                  source: "0x2f",
                                                  layoutVersion: HistoricalArchive.layoutVersion,
                                                  sequence: 8,
                                                  command: 0x16,
                                                  unix7: 1_800_000_000,
                                                  subsec11: 0,
                                                  flash13: 43,
                                                  payloadLength: payload.count,
                                                  whoofHR17: 61,
                                                  whoofRRNum18: 2,
                                                  whoofRR19: [980, 1_010],
                                                  kRR64: [],
                                                  gravityX36: 0,
                                                  gravityY40: 0,
                                                  gravityZ44: 0,
                                                  gravityMagnitude: 0,
                                                  gravityValidated: false,
                                                  candidateRR: ["whoof19", "k64"],
                                                  rawPayloadHex: HistoricalArchive.hex(payload),
                                                  clockDeviceRef: 1_800_000_000,
                                                  clockWallRef: 1_800_000_000,
                                                  clockDriftSeconds: 0,
                                                  clockCorrectedUnix7: 1_800_000_000,
                                                  clockCorrectionStatus: "corrected",
                                                  currentSessionUsable: false,
                                                  metricUsable: false,
                                                  usabilityReason: "provisional_historical_layout_old_or_unvalidated")

            _ = try HistoricalArchive.append(record)

            let diagnostics = HistoricalArchive.diagnostics()
            XCTAssertEqual(diagnostics.currentSessionUsableRows, 0)
            XCTAssertEqual(diagnostics.metricUsableRows, 0)
        }
    }

    private func baselineSamples(count: Int, now: Date) -> [PersonalBaseline.BaselineSample] {
        (0..<count).map { index in
            PersonalBaseline.BaselineSample(date: now.addingTimeInterval(Double(-index * 86_400)),
                                            restingHR: [58.0, 60.0, 62.0][index % 3],
                                            rmssd: [48.0, 52.0, 56.0][index % 3])
        }
    }

    private func withCleanHistoricalArchive(_ body: () throws -> Void) throws {
        let fileManager = FileManager.default
        let url = HistoricalArchive.fileURL
        let directory = url.deletingLastPathComponent()
        let existing = try? Data(contentsOf: url)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: url)
            if let existing {
                try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try? existing.write(to: url, options: .atomic)
            }
        }
        try body()
    }

    private func historicalPayloadWithGravity(x: Float, y: Float, z: Float) -> [UInt8] {
        var payload = Array(repeating: UInt8(0), count: 80)
        writeFloat32LE(x, into: &payload, at: 36)
        writeFloat32LE(y, into: &payload, at: 40)
        writeFloat32LE(z, into: &payload, at: 44)
        return payload
    }

    private func writeFloat32LE(_ value: Float, into payload: inout [UInt8], at offset: Int) {
        let raw = value.bitPattern
        payload[offset] = UInt8(raw & 0xff)
        payload[offset + 1] = UInt8((raw >> 8) & 0xff)
        payload[offset + 2] = UInt8((raw >> 16) & 0xff)
        payload[offset + 3] = UInt8((raw >> 24) & 0xff)
    }
}
