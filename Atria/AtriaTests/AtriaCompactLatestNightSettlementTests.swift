import XCTest
@testable import Atria

final class AtriaCompactLatestNightSettlementTests: XCTestCase {
    private final class StepClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        func next() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }
    }

    func testLatestNightWindowIsStructurallyAtMostTwoUTCShards() throws {
        for hour in [0, 1, 6, 12, 18, 23] {
            let now = Date(timeIntervalSince1970:
                1_800_000_000 + TimeInterval(hour * 3_600))
            let window = try XCTUnwrap(
                SessionStore.compactLatestNightWindow(now: now)
            )
            let first = Int64(floor(
                window.start.timeIntervalSince1970 / 86_400
            ))
            let last = Int64(floor(
                window.end.timeIntervalSince1970.nextDown / 86_400
            ))
            XCTAssertLessThanOrEqual(last - first + 1, 2)
            XCTAssertEqual(window.duration, 20 * 60 * 60, accuracy: 0.001)
        }
    }

    func testPhysicalSnapshotTwentyHourShapePassesUnchangedCaps() throws {
        let now = Date()
        // Read-only device snapshot 2026-08-09:
        // 14 intersecting sessions / 68,842 HR / 47,426 RR. The former
        // previous+current-UTC selection was 22 / 135,930 / 92,497 and would
        // deterministically withhold. Preserve this exact release shape.
        var recent: [SavedSession] = []
        for index in 0..<14 {
            let hourOffset = TimeInterval((index + 1) * 60 * 60)
            let heartRateRowCount = index == 13 ? 4_921 : 4_917
            let rrRowCount = index == 13 ? 3_395 : 3_387
            let points = [SavedSession.Point](
                repeating: SavedSession.Point(t: 0, bpm: 60),
                count: heartRateRowCount
            )
            recent.append(makeSession(
                start: now.addingTimeInterval(-hourOffset),
                points: points,
                rrCount: rrRowCount
            ))
        }
        var older: [SavedSession] = []
        for index in 0..<25 {
            older.append(makeSession(
                start: now.addingTimeInterval(
                    -TimeInterval((30 + index) * 60 * 60)
                ),
                points: [SavedSession.Point(t: 0, bpm: 60)],
                rrCount: 1
            ))
        }
        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: recent + older,
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ).get()
        XCTAssertEqual(slice.sessions.count, 14)
        XCTAssertEqual(slice.heartRateRows, 68_842)
        XCTAssertEqual(slice.rrRows, 47_426)
        XCTAssertLessThanOrEqual(
            slice.heartRateRows,
            SessionStore.compactLatestNightMaximumHeartRateRows
        )
        XCTAssertLessThanOrEqual(
            slice.rrRows,
            SessionStore.compactLatestNightMaximumRRRows
        )
    }

    func testPhysicalRetainedEpochShapeQualifiesLatestNightMotion() throws {
        // Deterministic replay of the retained Aug-8/9 candidate shape:
        // 20:43:34Z...05:56:40Z, 1,105/1,108 measurement-validated
        // epochs, 99.73% coverage, a 60-second largest hole, 77.70%
        // low-motion coverage, and 0.0557 mean movement intensity.
        let start = Date(timeIntervalSince1970: 1_807_000_000)
        let duration: TimeInterval = 9 * 60 * 60 + 13 * 60 + 6
        let end = start.addingTimeInterval(duration)
        let invalidIndices: Set<Int> = [900, 901, 950]
        let lowMotionIndices: Set<Int> = Set(1...857).union([0, 1_107])
        let epochs = (0..<1_108).map { index in
            let offset: TimeInterval
            let epochDuration: TimeInterval
            if index == 0 {
                offset = 0
                epochDuration = 3
            } else if index == 1_107 {
                offset = 3 + TimeInterval(1_106 * 30)
                epochDuration = 3
            } else {
                offset = 3 + TimeInterval((index - 1) * 30)
                epochDuration = 30
            }
            let epochStart = start.addingTimeInterval(offset)
            let epochEnd = epochStart.addingTimeInterval(epochDuration)
            let measurementValidated = !invalidIndices.contains(index)
            return AtriaRecoveredMotionEpoch(
                start: epochStart,
                end: epochEnd,
                rows: measurementValidated ? 6 : 0,
                validatedRows: measurementValidated ? 6 : 0,
                stillnessRatio: measurementValidated ? 0.80 : nil,
                movementIntensity: measurementValidated ? 0.0557 : nil,
                p95VectorDelta: measurementValidated ? 0.08 : nil,
                maximumGapSeconds: measurementValidated ? 6 : 30,
                measurementValidated: measurementValidated,
                lowMotionQualified: measurementValidated
                    && lowMotionIndices.contains(index),
                reason: measurementValidated
                    ? "bounded_historical_gravity_validated"
                    : "window_or_internal_gap"
            )
        }

        let provenance = AtriaRecoveredMotionAnalytics.sleepProvenance(
            epochs: epochs,
            start: start,
            end: end
        )
        XCTAssertEqual(epochs.filter(\.measurementValidated).count, 1_105)
        XCTAssertTrue(provenance.measurementSufficient)
        XCTAssertTrue(provenance.lowMotionValidated)
        XCTAssertEqual(
            provenance.validatedCoverageFraction,
            0.9973,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            provenance.lowMotionCoverageFraction,
            0.7770,
            accuracy: 0.0001
        )
        XCTAssertEqual(provenance.maximumGapSeconds, 60, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(provenance.meanMovementIntensity),
            0.0557,
            accuracy: 0.0001
        )
    }

    func testLatestNightSessionSliceEnforcesEveryPhysiologyCap() throws {
        let now = Date()
        let deadline = DispatchTime.now().uptimeNanoseconds
            + 2_000_000_000
        let base = makeSession(
            start: now.addingTimeInterval(-4 * 60 * 60),
            points: [.init(t: 0, bpm: 60)],
            rrCount: 1
        )
        let accepted = try SessionStore.compactLatestNightSessionSlice(
            from: [base],
            now: now,
            deadlineUptimeNanoseconds: deadline
        ).get()
        XCTAssertEqual(accepted.sessions.count, 1)
        XCTAssertEqual(accepted.heartRateRows, 1)
        XCTAssertEqual(accepted.rrRows, 1)

        let tooManySessions = (0...SessionStore
            .compactLatestNightMaximumSessions).map { index in
            makeSession(
                start: now.addingTimeInterval(
                    -TimeInterval(index * 60 + 3_600)
                ),
                points: [.init(t: 0, bpm: 60)]
            )
        }
        assertFailure(
            SessionStore.compactLatestNightSessionSlice(
                from: tooManySessions,
                now: now,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            ),
            equals: .sessionCapExceeded
        )

        let tooManyHR = makeSession(
            start: now.addingTimeInterval(-4 * 60 * 60),
            points: Array(
                repeating: .init(t: 0, bpm: 60),
                count: SessionStore.compactLatestNightMaximumHeartRateRows + 1
            )
        )
        assertFailure(
            SessionStore.compactLatestNightSessionSlice(
                from: [tooManyHR],
                now: now,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            ),
            equals: .heartRateCapExceeded
        )

        let tooManyRR = makeSession(
            start: now.addingTimeInterval(-4 * 60 * 60),
            points: [.init(t: 0, bpm: 60)],
            rrCount: SessionStore.compactLatestNightMaximumRRRows + 1
        )
        assertFailure(
            SessionStore.compactLatestNightSessionSlice(
                from: [tooManyRR],
                now: now,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            ),
            equals: .rrCapExceeded
        )
    }

    func testReviewSlicePreservesAttachedMotionAndStagesWhileCompactDefaultClearsIt()
        throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2027,
            month: 1,
            day: 12,
            hour: 14
        )))
        let duration: TimeInterval = 60 * 60
        let now = start.addingTimeInterval(4 * 60 * 60)
        var source = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Motion-backed nap",
            points: stride(from: 0.0, through: duration, by: 1.0).map {
                .init(t: $0, bpm: 62 + (Int($0) % 3))
            }
        )
        source.recoveredMotionEpochs = stride(
            from: 0.0,
            to: duration,
            by: 30.0
        ).map { offset in
            AtriaRecoveredMotionEpoch(
                start: start.addingTimeInterval(offset),
                end: start.addingTimeInterval(min(duration, offset + 30)),
                rows: 6,
                validatedRows: 6,
                stillnessRatio: 0.92,
                movementIntensity: 0.02,
                p95VectorDelta: 0.03,
                maximumGapSeconds: 5,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "test_attached_motion"
            )
        }
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds: .max,
            monotonicNow: { 0 }
        )
        let compactDefault = try SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds: .max
        ).get()
        XCTAssertNil(compactDefault.sessions.first?.recoveredMotionEpochs)

        let reviewSlice = try SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds: .max,
            cooperativeDeadline: deadline,
            preserveAttachedMotion: true
        ).get()
        XCTAssertEqual(
            reviewSlice.sessions.first?.recoveredMotionEpochs,
            source.recoveredMotionEpochs
        )

        let direct = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: [source],
            confirmedSleeps: [],
            rest: 62,
            maxHR: 190,
            calendar: calendar,
            cooperativeDeadline: deadline
        )
        let clipped = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: reviewSlice.sessions,
            confirmedSleeps: [],
            rest: 62,
            maxHR: 190,
            calendar: calendar,
            cooperativeDeadline: deadline
        )
        let directNap = try XCTUnwrap(direct.naps.first)
        let clippedNap = try XCTUnwrap(clipped.naps.first)
        XCTAssertEqual(clippedNap.id, directNap.id)
        XCTAssertEqual(clippedNap.stageSegments, directNap.stageSegments)
        XCTAssertFalse(clippedNap.stageSegments.isEmpty)
    }

    func testReviewSliceCancellationStopsMidTraversal() {
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        let start = now.addingTimeInterval(-6 * 60 * 60)
        let source = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(5 * 60 * 60),
            label: "Large cancellable review slice",
            points: (0..<20_000).map {
                .init(t: Double($0), bpm: 60 + ($0 % 3))
            }
        )
        let clock = StepClock()
        let result = SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds: .max,
            cooperativeDeadline: .init(
                uptimeNanoseconds: 4,
                monotonicNow: { clock.next() }
            ),
            preserveAttachedMotion: true
        )
        assertFailure(result, equals: .deadlineExceeded)
    }

    func testLatestNightSessionSliceAcceptsValidRowsAboveRemovedTwelveThousandCap()
        throws
    {
        let now = Date()
        let start = now.addingTimeInterval(-4 * 60 * 60)
        let duration: TimeInterval = 3 * 60 * 60
        let heartRateRowCount = 13_001
        let rrRowCount = 18_000
        let heartRatePoints = (0..<heartRateRowCount).map { index in
            SavedSession.Point(
                t: duration * Double(index)
                    / Double(heartRateRowCount - 1),
                bpm: 65
            )
        }
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Three-hour valid high-row-rate session",
            points: heartRatePoints
        )
        // RR rows are beats rather than notification samples: 18k rows is a
        // valid three-hour interval stream at 100 bpm, and must not be treated
        // as an oversized session while the aggregate 80k cap is respected.
        session.rrPoints = (0..<rrRowCount).map { index in
            SavedSession.RRPoint(
                t: Double(index) * 0.6,
                ms: 600,
                source: .standardHeartRateMeasurement2A37
            )
        }

        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [session],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ).get()

        XCTAssertEqual(slice.sessions.count, 1)
        XCTAssertEqual(slice.heartRateRows, heartRateRowCount)
        XCTAssertEqual(slice.rrRows, rrRowCount)
        XCTAssertGreaterThan(slice.heartRateRows, 12_000)
        XCTAssertGreaterThan(slice.rrRows, 12_000)
        XCTAssertLessThan(
            slice.heartRateRows,
            SessionStore.compactLatestNightMaximumHeartRateRows
        )
        XCTAssertLessThan(
            slice.rrRows,
            SessionStore.compactLatestNightMaximumRRRows
        )
        XCTAssertTrue(try XCTUnwrap(slice.sessions[0].rrPoints).allSatisfy {
            $0.source == .standardHeartRateMeasurement2A37
        })
    }

    func testLatestNightSessionSliceClipsCrossingSessionBeforeCapsAndRebasesRows()
        throws
    {
        let now = Date()
        let window = try XCTUnwrap(
            SessionStore.compactLatestNightWindow(now: now)
        )
        let sourceStart = now.addingTimeInterval(-30 * 60 * 60)
        let sourceEnd = now.addingTimeInterval(-18 * 60 * 60)
        let windowOffset = window.start.timeIntervalSince(sourceStart)
        let outsideHR = Array(
            repeating: SavedSession.Point(t: 0, bpm: 80),
            count: SessionStore.compactLatestNightMaximumHeartRateRows + 1
        )
        let insideHR = (0..<121).map { index in
            SavedSession.Point(
                t: windowOffset + Double(index * 30),
                bpm: 60 + (index % 2)
            )
        }
        var source = SavedSession(
            id: UUID(),
            start: sourceStart,
            end: sourceEnd,
            label: "Crossing connection",
            points: outsideHR + insideHR
        )
        let outsideRR = Array(
            repeating: SavedSession.RRPoint(
                t: 0,
                ms: 750,
                source: .standardHeartRateMeasurement2A37
            ),
            count: SessionStore.compactLatestNightMaximumRRRows + 1
        )
        let insideRR = (0..<180).map { index in
            SavedSession.RRPoint(
                t: windowOffset + Double(index) * 0.6,
                ms: 600,
                source: .standardHeartRateMeasurement2A37
            )
        }
        source.rrPoints = outsideRR + insideRR
        source.hrv = 55
        source.hrvReferenceValidated = true
        source.respiratoryRate = 14.2
        source.hrRaw2A37 = 200_000

        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        ).get()
        let clipped = try XCTUnwrap(slice.sessions.first)
        let clippedRR = try XCTUnwrap(clipped.rrPoints)

        XCTAssertEqual(slice.heartRateRows, insideHR.count)
        XCTAssertEqual(slice.rrRows, insideRR.count)
        XCTAssertEqual(clipped.id, source.id)
        XCTAssertEqual(clipped.start, window.start)
        XCTAssertEqual(clipped.end, sourceEnd)
        XCTAssertEqual(try XCTUnwrap(clipped.points.first?.t), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(clippedRR.first?.t), 0, accuracy: 0.001)
        XCTAssertTrue(clipped.points.allSatisfy {
            let absolute = clipped.start.addingTimeInterval($0.t)
            return absolute >= window.start && absolute < window.end
        })
        XCTAssertTrue(clippedRR.allSatisfy {
            let absolute = clipped.start.addingTimeInterval($0.t)
            return absolute >= window.start
                && absolute < window.end
                && $0.source == .standardHeartRateMeasurement2A37
        })
        XCTAssertNil(clipped.hrv)
        XCTAssertNil(clipped.respiratoryRate)
        XCTAssertEqual(clipped.hrvReferenceValidated, false)
        XCTAssertEqual(clipped.hrRaw2A37, source.hrRaw2A37)
    }

    func testLatestNightClippingCannotUpgradeMixedWholeSessionRRProvenance()
        throws
    {
        let now = Date()
        let window = try XCTUnwrap(
            SessionStore.compactLatestNightWindow(now: now)
        )
        let sourceStart = now.addingTimeInterval(-30 * 60 * 60)
        let sourceEnd = now.addingTimeInterval(-18 * 60 * 60)
        let windowOffset = window.start.timeIntervalSince(sourceStart)
        var source = SavedSession(
            id: UUID(),
            start: sourceStart,
            end: sourceEnd,
            label: "Mixed RR crossing connection",
            points: (0..<600).map { index in
                .init(
                    t: windowOffset + Double(index * 10),
                    bpm: 60 + (index % 2)
                )
            }
        )
        source.rrPoints = [
            .init(
                t: 0,
                ms: 1_000,
                source: .validatedProprietaryRealtime
            ),
        ] + (0..<1_200).map { index in
            .init(
                t: windowOffset + Double(index),
                ms: 1_000 + (index % 2),
                source: .standardHeartRateMeasurement2A37
            )
        }

        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ).get()
        let clipped = try XCTUnwrap(slice.sessions.first)

        XCTAssertEqual(slice.heartRateRows, 600)
        XCTAssertEqual(slice.rrRows, 0)
        XCTAssertNil(clipped.rrPoints)
        XCTAssertFalse(clipped.hasQualifiedRRProvenance)
        XCTAssertNil(try SessionStore.confirmedSleepRespiratoryRate(
            from: [clipped],
            start: clipped.start,
            end: clipped.end,
            cooperativeDeadline: .init(
                uptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        ))
    }

    func testLatestNightClippingRetainsExactSessionEndForThirdHRVWindow()
        throws
    {
        let now = Date()
        let start = now.addingTimeInterval(-2 * 60 * 60)
        let duration: TimeInterval = 15 * 60
        var source = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "Exact endpoint RR",
            points: [
                .init(t: 0, bpm: 60),
                .init(t: duration, bpm: 61),
            ]
        )
        source.rrPoints = (1...900).map { second in
            .init(
                t: Double(second),
                ms: 1_000 + Int((45 * sin(
                    2 * Double.pi * 0.25 * Double(second)
                )).rounded()),
                source: .standardHeartRateMeasurement2A37
            )
        }

        let slice = try SessionStore.compactLatestNightSessionSlice(
            from: [source],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ).get()
        let clipped = try XCTUnwrap(slice.sessions.first)
        let clippedRR = try XCTUnwrap(clipped.rrPoints)

        XCTAssertEqual(clipped.points.count, 2)
        XCTAssertEqual(clipped.points.last?.t, duration)
        XCTAssertEqual(clippedRR.count, 900)
        XCTAssertEqual(clippedRR.last?.t, duration)
        // 2026-08-29 pair-based qualification: the 150 s half-stride places 5
        // windows on this 900 s stream (was 3 under 300 s tiling). The final
        // window still ends exactly at the retained session endpoint, so
        // clipping that endpoint away would drop this to 4 — the sensitivity
        // this test exists to keep.
        XCTAssertEqual(try clipped.qualifiedLnRMSSDWindows(
            in: clipped.start,
            end: clipped.end,
            cooperativeDeadline: .init(
                uptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            )
        ).count, 5)
    }

    func testLatestNightSessionSliceClearsTemperatureAndFailsDeadline()
        throws
    {
        let now = Date()
        var session = makeSession(
            start: now.addingTimeInterval(-4 * 60 * 60),
            points: [.init(t: 0, bpm: 60)]
        )
        session.decodedSkinTemperatureCelsius = [try XCTUnwrap(
            AtriaResearchProbe.DecodedSkinTemperatureCelsius
                .calibratedFixture(celsius: 35.8)
        )]
        let accepted = try SessionStore.compactLatestNightSessionSlice(
            from: [session],
            now: now,
            deadlineUptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        ).get()
        XCTAssertNil(accepted.sessions.first?
            .decodedSkinTemperatureCelsius)

        assertFailure(
            SessionStore.compactLatestNightSessionSlice(
                from: [session],
                now: now,
                deadlineUptimeNanoseconds:
                    DispatchTime.now().uptimeNanoseconds
            ),
            equals: .deadlineExceeded
        )
    }

    func testCriticalThermalFailsBeforeAnyCompactOrSessionWork()
        async throws
    {
        let fingerprint = makeFingerprint()
        let result = await Task.detached(priority: .utility) {
            SessionStore.makeCompactLatestNightSettlementPreparation(
                fingerprint: fingerprint,
                canonicalSessions: [],
                now: Date(),
                rest: 60,
                maxHR: 190,
                learnedWindow: nil,
                strapIdentifier: nil,
                thermalState: .critical
            )
        }.value
        guard case .withheld(let failure) = result else {
            return XCTFail("critical thermal must fail closed")
        }
        XCTAssertEqual(failure, .thermalCritical)
    }

    func testSeriousThermalBuildsArchiveFreeProposalFromCompactPrefixes()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaCompactLatestNightSettlementTests-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        let strapIdentifier = UUID().uuidString
        let now = Date()
        let window = try XCTUnwrap(
            SessionStore.compactLatestNightWindow(now: now)
        )
        let motion = [
            migrationPoint(timestamp: window.start.timeIntervalSince1970 + 1,
                           identity: 1),
            migrationPoint(timestamp: now.timeIntervalSince1970 - 1,
                           identity: 2),
        ]
        try await Task.detached(priority: .utility) {
            _ = try store.appendMigrated(
                motion,
                strapIdentifier: strapIdentifier
            )
            try store.synchronize()
        }.value
        let session = makeSession(
            start: now.addingTimeInterval(-4 * 60 * 60),
            points: [
                .init(t: 0, bpm: 60),
                .init(t: 60, bpm: 61),
            ],
            rrCount: 10
        )
        let fingerprint = makeFingerprint()
        let result = await Task.detached(priority: .utility) {
            SessionStore.makeCompactLatestNightSettlementPreparation(
                fingerprint: fingerprint,
                canonicalSessions: [session],
                now: now,
                rest: 60,
                maxHR: 190,
                learnedWindow: nil,
                strapIdentifier: strapIdentifier,
                thermalState: .serious,
                compactStore: store
            )
        }.value
        guard case .ready(let prepared) = result else {
            return XCTFail("fixed-width path should be admitted under serious")
        }
        XCTAssertEqual(
            prepared.sourceStrapIdentifier,
            UUID(uuidString: strapIdentifier)
        )
        XCTAssertEqual(
            prepared.commitAuthority.sourceStrapIdentifier,
            prepared.sourceStrapIdentifier
        )
        XCTAssertEqual(prepared.sessionCount, 1)
        XCTAssertEqual(prepared.heartRateRows, 2)
        XCTAssertEqual(prepared.rrRows, 10)
        XCTAssertLessThanOrEqual(prepared.compactReceipt.shardCount, 2)
        XCTAssertLessThanOrEqual(
            prepared.compactReceipt.mappedBytes,
            10 * 1_024 * 1_024
        )
        XCTAssertLessThanOrEqual(prepared.compactReceipt.rowCount, 200_000)
        XCTAssertTrue(store.latestNightReceiptIsCurrent(
            prepared.compactReceipt
        ))
        XCTAssertNil(prepared.settlement.sourceSessions.first?
            .decodedSkinTemperatureCelsius)
    }

    func testPhysicalTwentyHourShapeBuildsReadyWithinProductionDeadline()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "AtriaCompactPhysicalReplay-\(UUID().uuidString)"
            )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AtriaWhoop4MotionTickCompactStore(
            directoryURL: directory
        )
        let strapIdentifier = UUID().uuidString
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
            .addingTimeInterval(11 * 60 * 60)
        let window = try XCTUnwrap(
            SessionStore.compactLatestNightWindow(now: now)
        )

        func points(
            count: Int,
            duration: TimeInterval,
            bpm: (Int) -> Int
        ) -> [SavedSession.Point] {
            (0..<count).map { index in
                .init(
                    t: duration * Double(index) / Double(count),
                    bpm: bpm(index)
                )
            }
        }

        let candidateStart = window.start.addingTimeInterval(8 * 60 * 60)
        let candidateDuration: TimeInterval = 11 * 60 * 60
        var sessions: [SavedSession] = []
        sessions.reserveCapacity(14)
        for index in 0..<14 {
            let start = candidateStart.addingTimeInterval(
                candidateDuration * Double(index) / 14
            )
            let end = candidateStart.addingTimeInterval(
                candidateDuration * Double(index + 1) / 14
            )
            let duration = end.timeIntervalSince(start)
            let heartRateRows = index == 13 ? 4_921 : 4_917
            let rrRows = index == 13 ? 3_395 : 3_387
            var fragment = SavedSession(
                id: UUID(),
                start: start,
                end: end,
                label: "Physical-shape sleep fragment \(index)",
                points: points(
                    count: heartRateRows,
                    duration: duration,
                    bpm: { 60 + ($0 % 2) }
                )
            )
            let rrOffsets = irregularRRTimeOffsets(
                count: rrRows,
                duration: duration
            )
            fragment.rrPoints = rrOffsets.enumerated().map {
                rrIndex, t in
                return .init(
                    t: t,
                    ms: 833 + Int((35 * sin(
                        2 * Double.pi * 0.25 * Double(rrIndex)
                    )).rounded()),
                    source: .standardHeartRateMeasurement2A37
                )
            }
            fragment.hrRaw2A37 = fragment.points.count
            fragment.hrAccepted = fragment.points.count
            fragment.eventTimeZoneIdentifier = TimeZone.current.identifier
            sessions.append(fragment)
        }
        XCTAssertEqual(sessions.count, 14)
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.points.count }, 68_842)
        XCTAssertEqual(
            sessions.reduce(0) { $0 + ($1.rrPoints?.count ?? 0) },
            47_426
        )
        var resampledLengths: Set<Int> = []
        var maximumRRGap = 0.0
        for session in sessions {
            let rrPoints = try XCTUnwrap(session.rrPoints)
            for index in 1..<rrPoints.count {
                maximumRRGap = max(
                    maximumRRGap,
                    rrPoints[index].t - rrPoints[index - 1].t
                )
            }
            var evaluation = session.start.addingTimeInterval(60)
            while evaluation <= session.end {
                let lower = evaluation.addingTimeInterval(-90)
                let recent = rrPoints.filter { point in
                    let timestamp = session.start.addingTimeInterval(point.t)
                    return timestamp >= lower && timestamp <= evaluation
                }
                if let first = recent.first, let last = recent.last {
                    resampledLengths.insert(Int(
                        (last.t - first.t) / 0.25
                    ) + 1)
                }
                evaluation = evaluation.addingTimeInterval(30)
            }
        }
        XCTAssertLessThanOrEqual(maximumRRGap, 3)
        XCTAssertGreaterThan(
            resampledLengths.count,
            8,
            "physical replay must cover irregular resampled lengths"
        )

        let motionRowCount = 120_324
        let motionDuration = window.duration - 0.2
        let motion = (0..<motionRowCount).map { index in
            let identity = index + 1
            return AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: window.start.timeIntervalSince1970 + 0.1
                    + motionDuration * Double(index)
                        / Double(motionRowCount - 1),
                flash: UInt32(identity),
                tick: identity & 0xffff,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.01,
                rawPayload: withUnsafeBytes(
                    of: UInt64(identity).littleEndian,
                    Array.init
                )
            )
        }
        let appended = try await Task.detached(priority: .utility) {
            let appended = try store.appendMigrated(
                motion,
                strapIdentifier: strapIdentifier
            )
            try store.synchronize()
            return appended
        }.value
        XCTAssertEqual(appended, motionRowCount)

        // Model the physical ~2 Hz catch-up stream with accelerated wall time.
        // Every row is inside the settled candidate itself. It may land before
        // or after the atomic prefix cut; either ordering must converge without
        // making authority mint chase an infinite historical tail.
        let activeBackfillRowCount = 1_200
        let activeBackfill = (0..<activeBackfillRowCount).map { index in
            let identity = motionRowCount + index + 1
            return AtriaWhoop4MotionTickCompactStore.MigrationPoint(
                timestamp: candidateStart.timeIntervalSince1970
                    + 2 * 60 * 60 + Double(index) * 2,
                flash: UInt32(identity),
                tick: identity & 0xffff,
                gravityX: 0,
                gravityY: 0,
                gravityZ: 1,
                unknownMotionScalar32: 0.01,
                rawPayload: withUnsafeBytes(
                    of: UInt64(identity).littleEndian,
                    Array.init
                )
            )
        }
        let activeAppender = Task.detached(priority: .utility) {
            var appended = 0
            for point in activeBackfill {
                appended += try store.appendMigrated(
                    [point],
                    strapIdentifier: strapIdentifier
                )
                try await Task.sleep(for: .milliseconds(1))
            }
            return appended
        }

        let fingerprint = makeFingerprint()
        let output = await withEmptyDeviceUseJournal {
            await Task.detached(priority: .utility) {
                let startedAt = DispatchTime.now().uptimeNanoseconds
                let result = SessionStore
                    .makeCompactLatestNightSettlementPreparation(
                        fingerprint: fingerprint,
                        canonicalSessions: sessions,
                        now: now,
                        rest: 60,
                        maxHR: 190,
                        learnedWindow: nil,
                        strapIdentifier: strapIdentifier,
                        thermalState: .serious,
                        compactStore: store
                    )
                let finishedAt = DispatchTime.now().uptimeNanoseconds
                return (
                    result,
                    Double(finishedAt - startedAt) / 1_000_000_000
                )
            }.value
        }
        let appendedDuringPreparation = try await activeAppender.value
        guard case .ready(let prepared) = output.0 else {
            return XCTFail(
                "physical-shape replay must be ready; got \(output.0)"
            )
        }
        XCTAssertEqual(
            appendedDuringPreparation,
            activeBackfillRowCount
        )
        print("ATRIA_COMPACT_PHYSICAL_PREPARATION_SECONDS \(output.1)")
        XCTContext.runActivity(
            named: "ATRIA_COMPACT_PHYSICAL_PREPARATION_SECONDS \(output.1)"
        ) { _ in }
        let materialization = try XCTUnwrap(
            prepared.settlement.preparedStrongCandidates.first
        )
        XCTAssertEqual(prepared.sessionCount, 14)
        XCTAssertEqual(prepared.heartRateRows, 68_842)
        XCTAssertEqual(prepared.rrRows, 47_426)
        XCTAssertGreaterThanOrEqual(
            prepared.compactReceipt.rowCount,
            motionRowCount
        )
        XCTAssertLessThanOrEqual(
            prepared.compactReceipt.rowCount,
            motionRowCount + activeBackfillRowCount
        )
        XCTAssertEqual(materialization.candidate.sessions, 14)
        XCTAssertEqual(materialization.candidate.start, candidateStart)
        XCTAssertEqual(
            materialization.candidate.end,
            candidateStart.addingTimeInterval(candidateDuration)
        )
        XCTAssertEqual(
            prepared.settlement.sourceSessions.reduce(0) {
                guard $1.end >= materialization.candidate.start,
                      $1.start <= materialization.candidate.end else {
                    return $0
                }
                return $0 + ($1.rrPoints?.count ?? 0)
            },
            47_426
        )
        XCTAssertNotNil(materialization.metrics.hrv)
        XCTAssertGreaterThanOrEqual(
            materialization.metrics.hrvWindowCount,
            112,
            "the full fragmented night must contribute HRV windows"
        )
        XCTAssertNotNil(materialization.respiratoryRate)
        XCTAssertNil(materialization.stageSegments)
        XCTAssertLessThan(
            output.1,
            SessionStore.compactLatestNightDeadlineSeconds,
            "a ready result must complete within the shared production budget"
        )
        XCTAssertTrue(store.consumeLatestNightCommitAuthority(
            prepared.commitAuthority,
            currentStrapIdentifier: strapIdentifier
        ))
    }

    func testCheckedAggregateWakeHRVAndRespirationAbortDeterministically()
        throws
    {
        let start = Date().addingTimeInterval(-6 * 60 * 60)
        var session = makeSession(
            start: start,
            points: (0..<6_000).map {
                .init(t: Double($0), bpm: 60 + ($0 % 2))
            }
        )
        session.rrPoints = (0..<6_000).map {
            .init(
                t: Double($0),
                ms: 1_000,
                source: .standardHeartRateMeasurement2A37
            )
        }

        func deadline(after checkpoints: UInt64)
            -> AtriaSleepSettlementDeadline {
            let clock = StepClock()
            return .init(
                uptimeNanoseconds: checkpoints,
                monotonicNow: { clock.next() }
            )
        }
        XCTAssertThrowsError(
            try SessionStore.aggregateSleepCandidates(
                in: [session],
                rest: 60,
                maxHR: 190,
                historicalMotionPolicy: .attachedCompactOnly,
                cooperativeDeadline: deadline(after: 8)
            )
        ) { XCTAssertEqual($0 as? AtriaSleepSettlementAbort, .deadlineExceeded) }
        XCTAssertThrowsError(
            try SessionStore.sustainedWakeOnset(
                in: session,
                restingHR: 60,
                cooperativeDeadline: deadline(after: 8)
            )
        ) { XCTAssertEqual($0 as? AtriaSleepSettlementAbort, .deadlineExceeded) }
        XCTAssertThrowsError(
            try SessionStore.confirmedSleepWindowMetrics(
                from: [session],
                start: session.start,
                end: session.end,
                rest: 60,
                cooperativeDeadline: deadline(after: 8)
            )
        ) { XCTAssertEqual($0 as? AtriaSleepSettlementAbort, .deadlineExceeded) }
        XCTAssertThrowsError(
            try SessionStore.confirmedSleepRespiratoryRate(
                from: [session],
                start: session.start,
                end: session.end,
                cooperativeDeadline: deadline(after: 8)
            )
        ) { XCTAssertEqual($0 as? AtriaSleepSettlementAbort, .deadlineExceeded) }
    }

    func testCompactRespiratoryKernelPathMatchesLegacyEstimator() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var sessions: [SavedSession] = []
        for index in 0..<2 {
            let duration = TimeInterval((12 + index) * 60)
            let sessionStart = start.addingTimeInterval(
                TimeInterval(index) * (13 * 60)
            )
            let rrCount = 865 + index * 73
            var session = SavedSession(
                id: UUID(),
                start: sessionStart,
                end: sessionStart.addingTimeInterval(duration),
                label: "Respiration parity \(index)",
                points: [
                    .init(t: 0, bpm: 60),
                    .init(t: duration, bpm: 61),
                ]
            )
            let offsets = irregularRRTimeOffsets(
                count: rrCount,
                duration: duration
            )
            session.rrPoints = offsets.enumerated().map { rrIndex, t in
                .init(
                    t: t,
                    ms: 833 + Int((35 * sin(
                        2 * Double.pi
                            * (0.20 + Double(index) * 0.05)
                            * Double(rrIndex)
                    )).rounded()),
                    source: .standardHeartRateMeasurement2A37
                )
            }
            sessions.append(session)
        }
        let end = try XCTUnwrap(sessions.last?.end)
        let legacy = SessionStore.confirmedSleepRespiratoryRate(
            from: sessions,
            start: start,
            end: end
        )
        let deadline = AtriaSleepSettlementDeadline(
            uptimeNanoseconds:
                DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        )
        let compact = try SessionStore.confirmedSleepRespiratoryRate(
            from: sessions,
            start: start,
            end: end,
            cooperativeDeadline: deadline
        )
        XCTAssertEqual(compact, legacy)
        XCTAssertNotNil(compact)
    }

    func testCheckedProposalCarriesFinishedPhysiologyForSettledCandidate()
        throws
    {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
            .addingTimeInterval(9 * 60 * 60)
        let start = now.addingTimeInterval(-10 * 60 * 60)
        var session = makeSession(
            start: start,
            points: stride(from: 0, through: 5 * 60 * 60, by: 3).map {
                .init(t: Double($0), bpm: 60 + (($0 / 3) % 2))
            }
        )
        // 2026-08-14 assessment P1.10: auto-confirm now requires qualified RR
        // to cover >=60% of the accepted window, so the stream spans the whole
        // five hours instead of the first twenty minutes.
        session.rrPoints = (0..<(5 * 60 * 60)).map {
            .init(
                t: Double($0),
                ms: 1_000 + Int((45 * sin(
                    2 * Double.pi * 0.25 * Double($0)
                )).rounded()),
                source: .standardHeartRateMeasurement2A37
            )
        }
        session.recoveredMotionEpochs = stride(
            from: 0,
            to: 5 * 60 * 60,
            by: 30
        ).map { offset in
            .init(
                start: start.addingTimeInterval(Double(offset)),
                end: start.addingTimeInterval(Double(offset + 30)),
                rows: 30,
                validatedRows: 30,
                stillnessRatio: 0.90,
                movementIntensity: 0.01,
                p95VectorDelta: 0.02,
                maximumGapSeconds: 1,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "bounded_historical_gravity_validated"
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
        let candidate = try XCTUnwrap(proposal.strongCandidates.first)
        let materialization = try XCTUnwrap(
            proposal.preparedStrongCandidates.first
        )
        XCTAssertEqual(materialization.key.kind, candidate.kind)
        XCTAssertEqual(materialization.key.start, candidate.start)
        XCTAssertEqual(materialization.key.end, candidate.end)
        XCTAssertEqual(
            materialization.classification,
            SessionStore.autoSleepClassification(
                for: candidate,
                baselineRestingIsTrusted: true,
                baselineRestingIsNearTrusted: true
            )
        )
        XCTAssertGreaterThanOrEqual(materialization.metrics.hrvWindowCount, 3)
        XCTAssertNotNil(materialization.metrics.hrv)
        XCTAssertNotNil(materialization.respiratoryRate)
        XCTAssertGreaterThan(session.points.count, 4_096)
        XCTAssertNil(
            materialization.stageSegments,
            "optional staging must omit >4,096 rows without withholding HRV/respiration"
        )
    }

    func testCheckedWakeBoundaryCarriesMatchingFinishedPhysiology() throws {
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
            .addingTimeInterval(10 * 60 * 60)
        let start = calendar.date(
            byAdding: .day,
            value: -1,
            to: calendar.startOfDay(for: now)
        )!.addingTimeInterval(23 * 60 * 60)
        let wakeTransition = 8 * 60 * 60
        let duration = Int(now.timeIntervalSince(start))
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: now,
            label: "Overnight with sustained awake tail",
            points: stride(from: 0, through: duration, by: 30).map { offset in
                .init(
                    t: Double(offset),
                    bpm: offset < wakeTransition
                        ? 60 + ((offset / 30) % 2)
                        : 90
                )
            }
        )
        session.rrPoints = (0..<1_200).map { index in
            .init(
                t: Double(index),
                ms: 1_000 + Int((45 * sin(
                    2 * Double.pi * 0.25 * Double(index)
                )).rounded()),
                source: .standardHeartRateMeasurement2A37
            )
        }
        session.recoveredMotionEpochs = stride(
            from: 0,
            through: wakeTransition + 30 * 60,
            by: 30
        ).map { offset in
            .init(
                start: start.addingTimeInterval(Double(offset)),
                end: start.addingTimeInterval(Double(offset + 30)),
                rows: 30,
                validatedRows: 30,
                stillnessRatio: 0.90,
                movementIntensity: 0.01,
                p95VectorDelta: 0.02,
                maximumGapSeconds: 1,
                measurementValidated: true,
                lowMotionQualified: true,
                reason: "bounded_historical_gravity_validated"
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
                learnedWindow: (start: 22 * 60, end: 8 * 60),
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
        let candidate = try XCTUnwrap(proposal.wakeBoundary.candidate)
        let materialization = try XCTUnwrap(
            proposal.wakeBoundary.preparedCandidate
        )
        XCTAssertEqual(proposal.wakeBoundary.blocker, "none")
        XCTAssertEqual(materialization.key.kind, candidate.kind)
        XCTAssertEqual(materialization.key.start, candidate.start)
        XCTAssertEqual(materialization.key.end, candidate.end)
        XCTAssertEqual(materialization.candidate.kind, candidate.kind)
        XCTAssertEqual(materialization.candidate.start, candidate.start)
        XCTAssertEqual(materialization.candidate.end, candidate.end)
        XCTAssertGreaterThanOrEqual(materialization.metrics.hrvWindowCount, 3)
        XCTAssertNotNil(materialization.metrics.hrv)
        XCTAssertNotNil(materialization.respiratoryRate)
    }

    func testCompactRetryIsOneShotAndArchiveFreeSourcePathIsIsolated()
        throws
    {
        XCTAssertEqual(
            SessionStore.compactLatestNightRetryAction(remainingAttempts: 1),
            .retry(delaySeconds: 10 * 60, nextRemainingAttempts: 0)
        )
        XCTAssertEqual(
            SessionStore.compactLatestNightRetryAction(remainingAttempts: 0),
            .awaitSourceOrSceneEdge
        )
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let retryStart = try XCTUnwrap(source.range(
            of: "private func scheduleCompactLatestNightSettlementRetry("
        ))
        let retryEnd = try XCTUnwrap(source.range(
            of: "private func foregroundSleepSettlementFingerprint(",
            range: retryStart.upperBound..<source.endIndex
        ))
        let retry = String(source[retryStart.lowerBound..<retryEnd.lowerBound])
        for forbidden in [
            "HistoricalArchive",
            "scheduleSleepReadinessRetryIfUseful",
            "sleepEvidenceStatusFast",
            "refreshHistoricalArchiveStatus",
        ] {
            XCTAssertFalse(retry.contains(forbidden))
        }

        let scalarBuilderStart = try XCTUnwrap(source.range(
            of: "private func buildAutoConfirmedSleep(\n        from prepared:"
        ))
        let scalarBuilderEnd = try XCTUnwrap(source.range(
            of: "// MARK: - Wake-boundary sleep confirm",
            range: scalarBuilderStart.upperBound..<source.endIndex
        ))
        let scalarBuilder = String(
            source[scalarBuilderStart.lowerBound..<scalarBuilderEnd.lowerBound]
        )
        for forbidden in [
            "sourceSessions",
            "canonicalSessions(",
            "confirmedSleepWindowMetrics",
            "confirmedSleepRespiratoryRate",
            "sleepStageResearchSegments",
        ] {
            XCTAssertFalse(scalarBuilder.contains(forbidden))
        }
    }

    func testPublisherSourceSliceContainsNoArchiveBLEOrGate4Work()
        throws
    {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let adapterStart = try XCTUnwrap(source.range(
            of: "nonisolated static func makeCompactLatestNightSettlementPreparation("
        ))
        let adapterEnd = try XCTUnwrap(source.range(
            of: "nonisolated static func foregroundSleepEvaluationSessions(",
            range: adapterStart.upperBound..<source.endIndex
        ))
        let adapter = String(
            source[adapterStart.lowerBound..<adapterEnd.lowerBound]
        )
        for forbidden in [
            "HistoricalArchive.",
            "AtriaBLEManager",
            "AtriaApp",
            "AtriaWhoop4GravityCadenceStepModel",
            "canonicalSessions(includeActiveJournal:",
        ] {
            XCTAssertFalse(
                adapter.contains(forbidden),
                "compact adapter must not contain \(forbidden)"
            )
        }
        let foregroundMarker = try XCTUnwrap(source.range(
            of: "// Read only the persisted strap identity."
        ))
        let foregroundEnd = try XCTUnwrap(source.range(
            of: "private func finishForegroundSleepSettlementCompletions(",
            range: foregroundMarker.upperBound..<source.endIndex
        ))
        let foreground = String(
            source[foregroundMarker.lowerBound..<foregroundEnd.lowerBound]
        )
        for forbidden in [
            "HistoricalArchive.",
            "AtriaBLEManager",
            "refreshHistorySnapshotCache(",
            "scheduleSleepReviewCacheRefresh(",
            "loadResidentJournalSessionForSleepEvaluation(",
            "AtriaWhoop4GravityCadenceStepModel",
        ] {
            XCTAssertFalse(
                foreground.contains(forbidden),
                "foreground compact publisher must not contain \(forbidden)"
            )
        }
        XCTAssertTrue(source.contains(
            "skinTemperatureSourceValidated: false"
        ))
        XCTAssertTrue(source.contains(
            "preserveExistingSkinTemperature:\n                    !archiveFreeLatestNightSettlement"
        ))
    }

    private func makeSession(
        start: Date,
        points: [SavedSession.Point],
        rrCount: Int = 0
    ) -> SavedSession {
        let end = start.addingTimeInterval(5 * 60 * 60)
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: end,
            label: "Test",
            points: points
        )
        if rrCount > 0 {
            session.rrPoints = Array(
                repeating: SavedSession.RRPoint(
                    t: 0,
                    ms: 1_000,
                    source: .standardHeartRateMeasurement2A37
                ),
                count: rrCount
            )
        }
        return session
    }

    /// Produces valid <=3-second RR gaps with enough deterministic timing
    /// variation to exercise many different 90-second resampled lengths. Most
    /// beats are close together; two longer gaps in each 17-beat block keep
    /// the physiological run continuous while defeating length-keyed caches.
    private func irregularRRTimeOffsets(
        count: Int,
        duration: TimeInterval
    ) -> [TimeInterval] {
        guard count > 0, duration > 0 else { return [] }
        let weights = (0..<count).map { index -> Double in
            switch index % 17 {
            case 0: return 2.75
            case 1: return 1.80
            default: return 0.58
            }
        }
        let total = weights.reduce(0, +)
        var accumulated = 0.0
        return weights.map { weight in
            accumulated += weight
            return duration * accumulated / total
        }
    }

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

    private func migrationPoint(
        timestamp: TimeInterval,
        identity: Int
    ) -> AtriaWhoop4MotionTickCompactStore.MigrationPoint {
        .init(
            timestamp: timestamp,
            flash: UInt32(identity),
            tick: identity,
            gravityX: 0,
            gravityY: 0,
            gravityZ: 1,
            unknownMotionScalar32: 0.05,
            rawPayload: withUnsafeBytes(
                of: UInt64(identity).littleEndian,
                Array.init
            )
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

    private func withEmptyDeviceUseJournal<T>(
        _ body: () async throws -> T
    ) async rethrows -> T {
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
        return try await body()
    }

    private func assertFailure<T>(
        _ result: Result<
            T,
            SessionStore.CompactLatestNightSettlementFailure
        >,
        equals expected: SessionStore.CompactLatestNightSettlementFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let failure) = result else {
            return XCTFail("expected failure \(expected)", file: file, line: line)
        }
        XCTAssertEqual(failure, expected, file: file, line: line)
    }
}
