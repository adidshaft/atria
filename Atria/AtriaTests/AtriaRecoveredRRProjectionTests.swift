import XCTest
@testable import Atria

final class AtriaRecoveredRRProjectionTests: XCTestCase {
    func testProjectsExactBeatEndTimesFromVerifiedRTCTimestampWithoutInterpolation() throws {
        let record = makeRecord()

        let result = AtriaRecoveredRRProjection.project(records: [record])

        XCTAssertEqual(result.statistics.inputRecordCount, 1)
        XCTAssertEqual(result.statistics.acceptedRecordCount, 1)
        XCTAssertEqual(result.statistics.emittedBeatCount, 2)
        XCTAssertEqual(result.beats.map(\.intervalMilliseconds), [717, 744])
        XCTAssertEqual(result.beats.map(\.beatIndex), [0, 1])
        XCTAssertTrue(result.beats.allSatisfy {
            $0.provenance == .verifiedWhoop4HistoricalV24
        })

        let recordEnd = TimeInterval(record.clockCorrectedUnix7!)
            + TimeInterval(record.subsec11) / 32_768
        XCTAssertEqual(result.beats[0].timestamp.timeIntervalSince1970,
                       recordEnd - 0.744,
                       accuracy: 0.000_001)
        XCTAssertEqual(result.beats[1].timestamp.timeIntervalSince1970,
                       recordEnd,
                       accuracy: 0.000_001)
        XCTAssertEqual(result.beats.count, record.whoofRR19.count,
                       "projection must not resample or fill the one-second record")
    }

    func testReplayAndInputOrderingAreIdempotent() throws {
        let first = makeRecord()
        let second = makeRecord(counter: first.flash13 + 1,
                                timestamp: first.unix7 + 1,
                                subsecond: 4_096,
                                intervals: [800])

        let canonical = AtriaRecoveredRRProjection.project(records: [first, second])
        let replayed = AtriaRecoveredRRProjection.project(
            records: [second, first, first, second]
        )

        XCTAssertEqual(replayed.beats, canonical.beats)
        XCTAssertEqual(replayed.stableFingerprint, canonical.stableFingerprint)
        XCTAssertEqual(replayed.statistics.acceptedRecordCount, 2)
        XCTAssertEqual(replayed.statistics.replayedRecordCount, 2)
        XCTAssertEqual(replayed.statistics.emittedBeatCount, 3)
        XCTAssertEqual(Set(replayed.beats.map(\.id)).count, replayed.beats.count)
    }

    func testStableIdentityNormalizesHexPresentationButIncludesRecordIdentity() throws {
        let canonical = makeRecord()
        let decoratedHex = canonical.rawPayloadHex.uppercased()
            .enumerated()
            .map { $0.offset.isMultiple(of: 8) ? " \($0.element)" : String($0.element) }
            .joined()
        let decorated = makeRecord(rawPayloadHex: decoratedHex)
        let differentCounter = makeRecord(counter: canonical.flash13 + 1)

        let canonicalResult = AtriaRecoveredRRProjection.project(records: [canonical])
        let decoratedResult = AtriaRecoveredRRProjection.project(records: [decorated])
        let otherResult = AtriaRecoveredRRProjection.project(records: [differentCounter])

        XCTAssertEqual(canonicalResult.beats.map(\.id), decoratedResult.beats.map(\.id))
        XCTAssertNotEqual(canonicalResult.beats.first?.recordID,
                          otherResult.beats.first?.recordID)
    }

    func testReplayWithNewerClockCorrectionKeepsRawIdentityAndIsOrderIndependent() throws {
        let original = makeRecord(clockWallRef: 1_120,
                                  clockCorrectedUnix: 1_781_626_642)
        let recalibrated = makeRecord(clockWallRef: 1_121,
                                      clockCorrectedUnix: 1_781_626_643)

        let forward = AtriaRecoveredRRProjection.project(records: [original, recalibrated])
        let reverse = AtriaRecoveredRRProjection.project(records: [recalibrated, original])

        XCTAssertEqual(forward.beats, reverse.beats)
        XCTAssertEqual(forward.stableFingerprint, reverse.stableFingerprint)
        XCTAssertEqual(forward.statistics.acceptedRecordCount, 1)
        XCTAssertEqual(forward.statistics.replayedRecordCount, 1)
        XCTAssertEqual(forward.beats.first?.recordID, reverse.beats.first?.recordID)
        let finalTimestamp = try XCTUnwrap(forward.beats.last?.timestamp.timeIntervalSince1970)
        XCTAssertEqual(finalTimestamp,
                       TimeInterval(1_781_626_643) + TimeInterval(original.subsec11) / 32_768,
                       accuracy: 0.000_001)
    }

    func testExplicitArchiveAndProtocolGatesFailClosed() throws {
        let cases: [(HistoricalArchive.Record, AtriaRecoveredRRProjection.RejectionReason)] = [
            (makeRecord(metricUsable: false), .metricNotUsable),
            (makeRecord(currentSessionUsable: false), .archiveFieldsNotUsable),
            (makeRecord(gravityValidated: false), .archiveFieldsNotUsable),
            (makeRecord(source: "diagnostic"), .wrongTransportProvenance),
            (makeRecord(command: 0x28), .wrongTransportProvenance),
            (makeRecord(sequence: 12), .layoutNotValidatedV24),
            (makeRecord(layoutVersion: "unvalidated"), .layoutNotValidatedV24),
            (makeRecord(clockCorrectionStatus: "clock_ref_missing"), .clockNotVerified),
            (makeRecord(clockDeviceRef: nil), .clockNotVerified),
            (makeRecord(clockWallRef: nil), .clockNotVerified),
            (makeRecord(includeCorrectedUnix: false), .clockNotVerified),
            (makeRecord(clockCorrectedUnix: 1_781_626_999), .clockNotVerified),
            (makeRecord(subsecond: 32_768), .invalidTimestamp),
            (makeRecord(rawPayloadHex: "not-hex"), .invalidRawPayload),
            (makeRecord(storedIntervals: [999]), .rrMetadataMismatch),
        ]

        for (record, expectedReason) in cases {
            let result = AtriaRecoveredRRProjection.project(records: [record])
            XCTAssertTrue(result.beats.isEmpty, "expected rejection: \(expectedReason)")
            XCTAssertEqual(result.statistics.rejected(expectedReason), 1,
                           "expected rejection: \(expectedReason)")
        }
    }

    func testRawPayloadMustIndependentlyProvePhysiologyAndMetadata() throws {
        let base = makeRecord()
        var payload = decodeHex(base.rawPayloadHex)
        payload[17] = 5
        let withheld = makeRecord(payload: payload,
                                  storedHeartRate: 5,
                                  metricUsable: true)
        let mismatchedCounter = makeRecord(storedCounter: base.flash13 + 1)

        let withheldResult = AtriaRecoveredRRProjection.project(records: [withheld])
        let mismatchResult = AtriaRecoveredRRProjection.project(records: [mismatchedCounter])

        XCTAssertEqual(withheldResult.statistics.rejected(.physiologyWithheld), 1)
        XCTAssertEqual(mismatchResult.statistics.rejected(.rawPayloadMismatch), 1)
        XCTAssertTrue(withheldResult.beats.isEmpty)
        XCTAssertTrue(mismatchResult.beats.isEmpty)
    }

    func testRawPayloadMustIndependentlyProvePlausibleGravity() throws {
        let base = makeRecord()
        var payload = decodeHex(base.rawPayloadHex)
        replaceFloat32LE(0, at: 44, in: &payload)
        let result = AtriaRecoveredRRProjection.project(records: [
            makeRecord(payload: payload, gravityValidated: true)
        ])

        XCTAssertTrue(result.beats.isEmpty)
        XCTAssertEqual(result.statistics.rejected(.rawPayloadMismatch), 1)
    }

    func testUnifiedRecoveredSnapshotDoesNotGateVerifiedHRAndRROnMotionUsability() throws {
        let base = makeRecord()
        var payload = decodeHex(base.rawPayloadHex)
        // RR accepts the decoder's broad physical magnitude range, while the
        // recovered motion feature path deliberately requires near-1g gravity.
        replaceFloat32LE(0.7, at: 44, in: &payload)
        let record = makeRecord(payload: payload, gravityValidated: true)
        let timestamp = TimeInterval(try XCTUnwrap(record.clockCorrectedUnix7))
            + TimeInterval(record.subsec11) / 32_768

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [record],
            since: Date(timeIntervalSince1970: timestamp - 1)
        )
        let motion = snapshot.motion.recoveredEpochs(windows: [
            .init(id: "window",
                  start: Date(timeIntervalSince1970: timestamp - 1),
                  end: Date(timeIntervalSince1970: timestamp + 29))
        ])["window"] ?? []

        XCTAssertEqual(snapshot.heartRatePoints.count, 1)
        XCTAssertEqual(snapshot.rrProjection.statistics.acceptedRecordCount, 1)
        XCTAssertEqual(snapshot.rrProjection
            .statistics.acceptedRecordCount, 1)
        XCTAssertFalse(motion.contains(where: \.measurementValidated),
                       "the stricter unusable gravity row remains isolated to motion")
    }

    func testUnifiedRecoveredSnapshotDeduplicatesLegacyMotionReplayIdentity() throws {
        let record = makeRecord()
        let timestamp = TimeInterval(try XCTUnwrap(record.clockCorrectedUnix7))
            + TimeInterval(record.subsec11) / 32_768
        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [record, record, record],
            since: Date(timeIntervalSince1970: timestamp - 1)
        )

        let epochs = snapshot.motion.recoveredEpochs(windows: [
            .init(id: "window",
                  start: Date(timeIntervalSince1970: timestamp - 1),
                  end: Date(timeIntervalSince1970: timestamp + 29))
        ])["window"] ?? []

        XCTAssertEqual(epochs.reduce(0) { $0 + $1.rows }, 1,
                       "one raw RTC+flash gravity identity is one physical frame")
    }

    func testUnifiedRecoveredSnapshotCarriesWearGatedWhoop4TemperatureRaw() throws {
        let base = makeRecord()
        var payload = decodeHex(base.rawPayloadHex)
        payload[51] = 1
        replaceUInt16LE(900, at: 68, in: &payload)
        let record = makeRecord(payload: payload)
        let timestamp = TimeInterval(try XCTUnwrap(record.clockCorrectedUnix7))
            + TimeInterval(record.subsec11) / 32_768

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [record],
            since: Date(timeIntervalSince1970: timestamp - 1)
        )

        XCTAssertEqual(snapshot.skinTemperatureRawPoints.count, 1)
        XCTAssertEqual(snapshot.skinTemperatureRawPoints.first?.raw, 900)
        XCTAssertEqual(
            try XCTUnwrap(snapshot.skinTemperatureRawPoints.first).t.timeIntervalSince1970,
            timestamp,
            accuracy: 1e-6
        )

        payload[51] = 0
        let doff = makeRecord(payload: payload)
        let doffSnapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [doff],
            since: Date(timeIntervalSince1970: timestamp - 1)
        )
        XCTAssertTrue(doffSnapshot.skinTemperatureRawPoints.isEmpty)
    }

    func testConfirmedSleepWindowsPublishRecoveredTemperatureWithoutSleepTaggedSessions() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let firstMorning = Date(timeIntervalSince1970: 1_780_000_000)
        let nightlyRaw = [800, 820, 840, 900]
        var points: [HistoricalArchive.SkinTemperatureRawPoint] = []
        var sleeps: [UserConfirmedSleep] = []

        for (night, raw) in nightlyRaw.enumerated() {
            let end = firstMorning.addingTimeInterval(TimeInterval(night) * 86_400)
            let start = end.addingTimeInterval(-8 * 60 * 60)
            sleeps.append(UserConfirmedSleep(
                id: "night-\(night)",
                createdAt: end,
                start: start,
                end: end,
                source: "manual_sleep",
                confidence: "user_confirmed_hr_only",
                sessions: 1,
                samples: 100,
                avgHR: 60,
                peakHR: 75,
                restingHR: 55,
                hrv: nil,
                hrvWindowCount: nil,
                duration: 8 * 60 * 60,
                span: 8 * 60 * 60,
                reason: "test",
                motionSource: "user_review",
                motionValidated: false,
                stageSegments: nil,
                eventTimeZoneIdentifier: "UTC"
            ))
            for sample in 0..<100 {
                points.append(.init(
                    t: start.addingTimeInterval(TimeInterval(sample) * 60),
                    raw: raw,
                    strapIdentifier: "strap-a"
                ))
            }
        }
        let napStart = sleeps[3].end.addingTimeInterval(60 * 60)
        let napEnd = napStart.addingTimeInterval(30 * 60)
        sleeps.append(UserConfirmedSleep(
            id: "nap",
            createdAt: napEnd,
            start: napStart,
            end: napEnd,
            source: "nap_candidate",
            confidence: "user_confirmed_hr_only",
            sessions: 1,
            samples: 100,
            avgHR: 60,
            peakHR: 75,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: nil,
            duration: 30 * 60,
            span: 30 * 60,
            reason: "test",
            motionSource: "user_review",
            motionValidated: false,
            stageSegments: nil,
            eventTimeZoneIdentifier: "UTC"
        ))
        for sample in 0..<100 {
            points.append(.init(
                t: napStart.addingTimeInterval(TimeInterval(sample) * 10),
                raw: 600,
                strapIdentifier: "strap-a"
            ))
        }

        let projection = SessionStore.recoveredSkinTemperatureProjection(
            points: points,
            confirmedSleeps: sleeps,
            calendar: calendar
        )
        let result = projection.deviations
        let fourthDay = calendar.startOfDay(for: sleeps[3].end)
        XCTAssertEqual(projection.baselineNightCount, 4)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[fourthDay] ?? .nan, 4.0, accuracy: 0.000_001)
    }

    func testTemperatureBudgetFailsOnlyTemperatureChannel() {
        func temperatureRecord(counter: UInt32, timestamp: UInt32, raw: UInt16)
            -> HistoricalArchive.Record {
            var payload = makePayload(counter: counter,
                                      timestamp: timestamp,
                                      subsecond: 0,
                                      heartRate: 70,
                                      intervals: [800])
            payload[51] = 1
            replaceUInt16LE(raw, at: 68, in: &payload)
            return makeRecord(counter: counter,
                              timestamp: timestamp,
                              subsecond: 0,
                              intervals: [800],
                              payload: payload)
        }
        let first = temperatureRecord(counter: 100, timestamp: 1_781_626_500, raw: 900)
        let second = temperatureRecord(counter: 101, timestamp: 1_781_626_501, raw: 901)
        let budget = HistoricalArchive.RecoveredProjectionBudget(
            maximumHeartRatePoints: 10,
            maximumRRRecords: 10,
            maximumSkinTemperaturePoints: 1,
            maximumGravitySamples: 10,
            maximumMotionReplayIdentities: 10
        )

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [first, second],
            since: Date(timeIntervalSince1970: 1_781_626_000),
            budget: budget
        )

        XCTAssertEqual(snapshot.physiologyCompleteness, .complete)
        XCTAssertEqual(snapshot.skinTemperatureCompleteness,
                       .budgetExceeded(channel: .skinTemperature, limit: 1))
        XCTAssertEqual(snapshot.skinTemperatureRawPoints.count, 1)
    }

    func testMotionDedupDoesNotCollapseTimestampCollisionWithDifferentRawPayload() throws {
        let first = makeRecord()
        var changedPayload = decodeHex(first.rawPayloadHex)
        replaceFloat32LE(0.9, at: 44, in: &changedPayload)
        let second = makeRecord(payload: changedPayload)
        let timestamp = TimeInterval(try XCTUnwrap(first.clockCorrectedUnix7))
            + TimeInterval(first.subsec11) / 32_768
        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [first, second],
            since: Date(timeIntervalSince1970: timestamp - 1)
        )

        let epochs = snapshot.motion.recoveredEpochs(windows: [
            .init(id: "window",
                  start: Date(timeIntervalSince1970: timestamp - 1),
                  end: Date(timeIntervalSince1970: timestamp + 29))
        ])["window"] ?? []

        XCTAssertEqual(epochs.reduce(0) { $0 + $1.rows }, 2,
                       "same RTC+flash metadata with a distinct raw payload is not a replay identity")
    }

    func testEmptyAcceptedRRRecordDoesNotManufactureBeats() throws {
        let result = AtriaRecoveredRRProjection.project(records: [
            makeRecord(intervals: [])
        ])

        XCTAssertTrue(result.beats.isEmpty)
        XCTAssertEqual(result.statistics.acceptedRecordCount, 0)
        XCTAssertEqual(result.statistics.rejected(.noIntervals), 1)
    }

    func testRelativeProjectionPreservesBoundariesAndProvenance() throws {
        let result = AtriaRecoveredRRProjection.project(records: [makeRecord()])
        let first = try XCTUnwrap(result.beats.first)
        let last = try XCTUnwrap(result.beats.last)
        let sessionStart = first.timestamp.addingTimeInterval(-1)

        let relative = result.relativeBeats(sessionStart: sessionStart,
                                            sessionEnd: last.timestamp)
        let excluded = result.relativeBeats(sessionStart: last.timestamp.addingTimeInterval(0.001))

        let expectedTimes = [1, last.timestamp.timeIntervalSince(sessionStart)]
        XCTAssertEqual(relative.count, expectedTimes.count)
        for (actual, expected) in zip(relative.map(\.secondsFromSessionStart), expectedTimes) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(relative.map(\.intervalMilliseconds), [717, 744])
        XCTAssertTrue(relative.allSatisfy {
            $0.provenance == .verifiedWhoop4HistoricalV24
        })
        XCTAssertTrue(excluded.isEmpty)
    }

    func testUnifiedRecoveredSnapshotFailsClosedOnlyTheExhaustedPhysiologyChannel() {
        let first = makeRecord(counter: 100, timestamp: 1_781_626_500)
        let second = makeRecord(counter: 101, timestamp: 1_781_626_501)
        let budget = HistoricalArchive.RecoveredProjectionBudget(
            maximumHeartRatePoints: 1,
            maximumRRRecords: 10,
            maximumGravitySamples: 10,
            maximumMotionReplayIdentities: 10
        )

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [first, second],
            since: Date(timeIntervalSince1970: 1_781_626_000),
            budget: budget
        )

        XCTAssertEqual(snapshot.completeness,
                       .budgetExceeded(channel: .heartRate, limit: 1))
        XCTAssertEqual(snapshot.physiologyCompleteness,
                       .budgetExceeded(channel: .heartRate, limit: 1))
        XCTAssertEqual(snapshot.heartRatePoints.count, 1)
        XCTAssertEqual(snapshot.rrProjection.statistics.acceptedRecordCount, 2,
                       "an HR bound must not silently truncate independently verified RR")
        XCTAssertEqual(snapshot.completeness.failureReason,
                       "archive_projection_budget_exceeded_heart_rate_1")
    }

    func testMotionBudgetPublishesCompletePhysiologyWithoutImplyingCompleteMotion() {
        let first = makeRecord(counter: 100, timestamp: 1_781_626_500)
        let second = makeRecord(counter: 101, timestamp: 1_781_626_501)
        let budget = HistoricalArchive.RecoveredProjectionBudget(
            maximumHeartRatePoints: 10,
            maximumRRRecords: 10,
            maximumGravitySamples: 10,
            maximumMotionReplayIdentities: 1
        )

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [first, second],
            since: Date(timeIntervalSince1970: 1_781_626_000),
            budget: budget
        )

        XCTAssertEqual(snapshot.completeness,
                       .budgetExceeded(channel: .motionReplayIdentity, limit: 1),
                       "whole-snapshot completeness must remain truthful")
        XCTAssertEqual(snapshot.physiologyCompleteness, .complete)
        XCTAssertEqual(snapshot.motion.completeness,
                       .budgetExceeded(channel: .motionReplayIdentity, limit: 1))
        XCTAssertEqual(snapshot.budgetLimitations, [
            .init(channel: .motionReplayIdentity, limit: 1)
        ])
        XCTAssertEqual(snapshot.heartRatePoints.count, 2)
        XCTAssertEqual(snapshot.rrProjection.statistics.acceptedRecordCount, 2)

        let epochs = snapshot.motion.recoveredEpochs(windows: [
            .init(id: "bounded", start: Date(timeIntervalSince1970: 1_781_626_499),
                  end: Date(timeIntervalSince1970: 1_781_626_502))
        ])
        XCTAssertTrue(epochs.isEmpty,
                      "partial motion must be unavailable, never presented as complete evidence")
    }

    func testUnifiedRecoveredSnapshotAcceptsExactBudgetBoundary() {
        let record = makeRecord()
        let budget = HistoricalArchive.RecoveredProjectionBudget(
            maximumHeartRatePoints: 1,
            maximumRRRecords: 1,
            maximumGravitySamples: 1,
            maximumMotionReplayIdentities: 1
        )

        let snapshot = HistoricalArchive.makeRecoveredDataSnapshot(
            records: [record],
            since: Date(timeIntervalSince1970: 1_781_626_000),
            budget: budget
        )

        XCTAssertEqual(snapshot.completeness, .complete)
        XCTAssertEqual(snapshot.physiologyCompleteness, .complete)
        XCTAssertEqual(snapshot.motion.completeness, .complete)
        XCTAssertTrue(snapshot.budgetLimitations.isEmpty)
        XCTAssertEqual(snapshot.heartRatePoints.count, 1)
        XCTAssertEqual(snapshot.rrProjection.statistics.acceptedRecordCount, 1)
    }

    func testProductionConsumerUsesPhysiologyGateWithoutClaimingMotionCompleteness() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sessionsURL = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sessionsURL, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "guard recoveredSnapshot.physiologyCompleteness == .complete"
        ))
        XCTAssertFalse(source.contains(
            "guard recoveredSnapshot.completeness == .complete"
        ))
    }

    private func makeRecord(
        counter: UInt32 = 0x0131_4944,
        timestamp: UInt32 = 1_781_626_522,
        subsecond: UInt16 = 15_000,
        intervals: [Int] = [717, 744],
        payload explicitPayload: [UInt8]? = nil,
        rawPayloadHex explicitRawPayloadHex: String? = nil,
        source: String = "0x2f",
        layoutVersion: String = HistoricalArchive.layoutVersion,
        sequence: Int = 24,
        command: Int = 0x2f,
        storedCounter: UInt32? = nil,
        storedHeartRate: Int = 84,
        storedIntervals: [Int]? = nil,
        clockDeviceRef: UInt32? = 1_000,
        clockWallRef: UInt32? = 1_120,
        clockCorrectedUnix: UInt32? = nil,
        includeCorrectedUnix: Bool = true,
        clockCorrectionStatus: String = "clock_ref_present",
        currentSessionUsable: Bool = true,
        metricUsable: Bool = true,
        gravityValidated: Bool = true
    ) -> HistoricalArchive.Record {
        let payload = explicitPayload ?? makePayload(counter: counter,
                                                     timestamp: timestamp,
                                                     subsecond: subsecond,
                                                     heartRate: storedHeartRate,
                                                     intervals: intervals)
        let storedRR = storedIntervals ?? intervals
        let drift = clockDeviceRef.flatMap { device in
            clockWallRef.map { wall in Int(wall) - Int(device) }
        }
        let snappedDrift = drift.map { value -> Int in
            guard abs(value) >= 86_400 else { return value }
            return value >= 0
                ? ((value + 150) / 300) * 300
                : ((value - 150) / 300) * 300
        }
        let derivedCorrectedUnix = snappedDrift.flatMap { value -> UInt32? in
            let result = Int64(timestamp) + Int64(value)
            return result > 0 && result <= Int64(UInt32.max) ? UInt32(result) : nil
        }
        return HistoricalArchive.Record(
            schema: HistoricalArchive.schema,
            capturedAt: Date(timeIntervalSince1970: TimeInterval(timestamp + 120)),
            source: source,
            layoutVersion: layoutVersion,
            sequence: sequence,
            command: command,
            unix7: timestamp,
            subsec11: subsecond,
            flash13: storedCounter ?? counter,
            payloadLength: payload.count,
            whoofHR17: storedHeartRate,
            whoofRRNum18: storedRR.count,
            whoofRR19: storedRR,
            kRR64: [],
            gravityX36: 0,
            gravityY40: 0,
            gravityZ44: 1,
            gravityMagnitude: 1,
            gravityValidated: gravityValidated,
            candidateRR: [],
            rawPayloadHex: explicitRawPayloadHex ?? encodeHex(payload),
            clockDeviceRef: clockDeviceRef,
            clockWallRef: clockWallRef,
            clockDriftSeconds: drift,
            clockCorrectedUnix7: includeCorrectedUnix
                ? (clockCorrectedUnix ?? (clockCorrectionStatus == "clock_ref_present"
                ? derivedCorrectedUnix
                : nil))
                : nil,
            clockCorrectionStatus: clockCorrectionStatus,
            currentSessionUsable: currentSessionUsable,
            metricUsable: metricUsable,
            usabilityReason: "verified_v24_heart_rate"
        )
    }

    private func makePayload(counter: UInt32,
                             timestamp: UInt32,
                             subsecond: UInt16,
                             heartRate: Int,
                             intervals: [Int]) -> [UInt8] {
        precondition(intervals.count <= 4)
        var bytes = [UInt8](repeating: 0, count: 80)
        bytes[0] = 0x2f
        bytes[1] = 24
        replaceUInt32LE(counter, at: 3, in: &bytes)
        replaceUInt32LE(timestamp, at: 7, in: &bytes)
        replaceUInt16LE(subsecond, at: 11, in: &bytes)
        bytes[17] = UInt8(heartRate)
        bytes[18] = UInt8(intervals.count)
        for (index, interval) in intervals.enumerated() {
            replaceUInt16LE(UInt16(interval), at: 19 + index * 2, in: &bytes)
        }
        replaceFloat32LE(0, at: 36, in: &bytes)
        replaceFloat32LE(0, at: 40, in: &bytes)
        replaceFloat32LE(1, at: 44, in: &bytes)
        return bytes
    }

    private func replaceUInt16LE(_ value: UInt16, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    private func replaceUInt32LE(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    private func replaceFloat32LE(_ value: Float, at offset: Int, in bytes: inout [UInt8]) {
        replaceUInt32LE(value.bitPattern, at: offset, in: &bytes)
    }

    private func encodeHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func decodeHex(_ value: String) -> [UInt8] {
        stride(from: 0, to: value.count, by: 2).compactMap { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start..<end], radix: 16)
        }
    }
}
