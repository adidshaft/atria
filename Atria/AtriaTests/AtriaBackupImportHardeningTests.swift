import XCTest
@testable import Atria

final class AtriaBackupImportHardeningTests: XCTestCase {
    func testCompressedArchiveRoundTripsExactly() throws {
        let original = Data((0..<96_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let compressed = try AtriaBackupCompression.compressedArchiveData(from: original)

        XCTAssertEqual(try AtriaBackupCompression.archivePayloadData(
            from: compressed,
            fileExtension: "gz"
        ), original)
    }

    func testOversizedPlainArchiveIsRejectedBeforeDecode() {
        let plain = Data(repeating: 0x20, count: 1_025)

        XCTAssertThrowsError(try AtriaBackupCompression.archivePayloadData(
            from: plain,
            fileExtension: "json",
            maximumCompressedBytes: 512,
            maximumDecodedBytes: 1_024
        )) { error in
            XCTAssertEqual(error as? AtriaBackupCompression.ArchiveError,
                           .decodedArchiveTooLarge)
        }
    }

    func testCompressedExpansionBombStopsAtDecodedCeiling() throws {
        let expanded = Data(repeating: 0x41, count: 64 * 1_024)
        let compressed = try AtriaBackupCompression.compressedArchiveData(from: expanded)
        XCTAssertLessThan(compressed.count, 1_024)

        XCTAssertThrowsError(try AtriaBackupCompression.archivePayloadData(
            from: compressed,
            fileExtension: "gz",
            maximumCompressedBytes: 1_024,
            maximumDecodedBytes: 4_096
        )) { error in
            XCTAssertEqual(error as? AtriaBackupCompression.ArchiveError,
                           .decodedArchiveTooLarge)
        }
    }

    func testCorruptAndTruncatedCompressedArchivesAreRejected() throws {
        XCTAssertThrowsError(try AtriaBackupCompression.archivePayloadData(
            from: Data([0x00, 0x01, 0x02, 0x03]),
            fileExtension: "gz"
        ))

        let compressed = try AtriaBackupCompression.compressedArchiveData(
            from: Data("{\"valid\":true}".utf8)
        )
        let truncated = compressed.dropLast(max(1, compressed.count / 3))
        XCTAssertThrowsError(try AtriaBackupCompression.archivePayloadData(
            from: Data(truncated),
            fileExtension: "gz"
        ))
    }

    func testCompressedArchiveRejectsTrailingBytesAfterEndMarker() throws {
        var compressed = try AtriaBackupCompression.compressedArchiveData(
            from: Data("{\"valid\":true}".utf8)
        )
        compressed.append(contentsOf: [0x41, 0x54, 0x52, 0x49, 0x41])

        XCTAssertThrowsError(try AtriaBackupCompression.archivePayloadData(
            from: compressed,
            fileExtension: "gz"
        )) { error in
            XCTAssertEqual(error as? AtriaBackupCompression.ArchiveError, .corruptArchive)
        }
    }

    func testEnvelopeValidationRejectsWrongAppAndInvalidHeartRateDomain() throws {
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let wrongApp = SessionBackupEnvelope(schema: 4,
                                             createdAt: Date(),
                                             app: "Other.local",
                                             sessions: [],
                                             baseline: PersonalBaseline(),
                                             profile: profile)
        XCTAssertThrowsError(try SessionStore.validateSessionBackupEnvelopeForImport(wrongApp)) { caught in
            XCTAssertEqual(caught as? SessionStore.SessionBackupImportError, .invalidApp)
        }

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let invalid = SavedSession(id: UUID(),
                                   start: start,
                                   end: start.addingTimeInterval(60),
                                   label: "invalid",
                                   points: [.init(t: 1, bpm: 999)])
        let invalidDomain = SessionBackupEnvelope(schema: 4,
                                                  createdAt: Date(),
                                                  app: "Atria.local",
                                                  sessions: [invalid],
                                                  baseline: PersonalBaseline(),
                                                  profile: profile)
        XCTAssertThrowsError(try SessionStore.validateSessionBackupEnvelopeForImport(invalidDomain)) { caught in
            XCTAssertEqual(caught as? SessionStore.SessionBackupImportError, .invalidDomain)
        }
    }

    func testEnvelopeValidationRejectsInconsistentRawExportCounts() {
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: nil,
                                     hasCompletedOnboarding: true)
        let raw = SessionBackupRawExport(schemaVersion: 1,
                                         schemaHeader: "header",
                                         schemaDocument: "doc",
                                         hrRows: [],
                                         rrRows: [],
                                         hrSamples: 1,
                                         rrSamples: 0,
                                         sleeps: 0,
                                         workouts: 0,
                                         rollups: 0)
        let envelope = SessionBackupEnvelope(schema: 4,
                                             createdAt: Date(),
                                             app: "Atria.local",
                                             sessions: [],
                                             baseline: PersonalBaseline(),
                                             profile: profile,
                                             rawExport: raw)

        XCTAssertThrowsError(try SessionStore.validateSessionBackupEnvelopeForImport(envelope)) { caught in
            XCTAssertEqual(caught as? SessionStore.SessionBackupImportError,
                           .inconsistentRawExport)
        }
    }

    func testEnvelopeValidationRejectsDuplicateDurableIdentitiesAcrossEveryMergeDomain() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: day,
                                     hasCompletedOnboarding: true)
        let session = SavedSession(id: UUID(),
                                   start: day,
                                   end: day.addingTimeInterval(60),
                                   label: "duplicate",
                                   points: [.init(t: 0, bpm: 70)])
        let sleep = UserConfirmedSleep(id: "duplicate-sleep",
                                       createdAt: day,
                                       start: day,
                                       end: day.addingTimeInterval(60),
                                       source: "test",
                                       confidence: "test",
                                       sessions: 1,
                                       samples: 1,
                                       avgHR: 60,
                                       peakHR: 70,
                                       restingHR: 55,
                                       hrv: 50,
                                       hrvWindowCount: 1,
                                       duration: 60,
                                       span: 60,
                                       reason: "test",
                                       motionSource: "test",
                                       motionValidated: false,
                                       stageSegments: nil)
        let workout = UserConfirmedWorkout(id: "duplicate-workout",
                                           createdAt: day,
                                           start: day,
                                           end: day.addingTimeInterval(60),
                                           label: "Walking",
                                           source: "test",
                                           confidence: "test",
                                           sessions: 1,
                                           samples: 1,
                                           avgHR: 80,
                                           peakHR: 90,
                                           p95HR: 88,
                                           p99HR: 89,
                                           thresholdHR: 85,
                                           streamCoveragePercent: 100,
                                           observedDuration: 60,
                                           reason: "test")
        let metric = SavedDailyMetric(day: day,
                                      recoveryPercent: 70,
                                      recoveryConfidence: "test",
                                      hrv: 50,
                                      restingHR: 60,
                                      respiratoryRate: 15,
                                      sleepDuration: nil,
                                      sleepSpan: nil,
                                      sleepStart: nil,
                                      sleepEnd: nil,
                                      sleepSource: nil,
                                      sleepStageSegments: [],
                                      sleepConsistencyPercent: nil,
                                      strain: 5)
        let rollup = DailyRollupStoreEntry(day: day, recovery: 70)
        let envelopes = [
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [session, session], baseline: PersonalBaseline(), profile: profile),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: PersonalBaseline(), profile: profile,
                                  dailyMetrics: [metric, metric]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: PersonalBaseline(), profile: profile,
                                  dailyRollups: [rollup, rollup]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: PersonalBaseline(), profile: profile,
                                  confirmedSleeps: [sleep, sleep]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: PersonalBaseline(), profile: profile,
                                  confirmedWorkouts: [workout, workout])
        ]

        for envelope in envelopes {
            XCTAssertThrowsError(try SessionStore.validateSessionBackupEnvelopeForImport(envelope)) {
                XCTAssertEqual($0 as? SessionStore.SessionBackupImportError, .duplicateIdentity)
            }
        }
    }

    func testEnvelopeValidationRejectsMalformedNestedDomainRecords() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: day,
                                     hasCompletedOnboarding: true)
        let baseline = PersonalBaseline(restingHR: 60, hrvEMA: 50, sessions: 1, updated: day)
        let unorderedSession = SavedSession(
            id: UUID(),
            start: day,
            end: day.addingTimeInterval(60),
            label: "unordered",
            points: [.init(t: 30, bpm: 80), .init(t: 10, bpm: 81)]
        )
        let reversedSleepMetric = SavedDailyMetric(
            day: day,
            recoveryPercent: 70,
            recoveryConfidence: "test",
            hrv: 50,
            restingHR: 60,
            respiratoryRate: 15,
            sleepDuration: 3_600,
            sleepSpan: 3_600,
            sleepStart: day.addingTimeInterval(3_600),
            sleepEnd: day,
            sleepSource: "test",
            sleepStageSegments: [],
            sleepConsistencyPercent: 80,
            strain: 5
        )
        let negativeNutrition = AtriaNutritionSummary(kcal: -1,
                                                       proteinG: nil,
                                                       carbsG: nil,
                                                       fatG: nil,
                                                       waterMl: nil,
                                                       caffeineMg: nil,
                                                       lastCaffeineHour: nil,
                                                       alcoholDrinks: nil)
        let malformedRollup = DailyRollupStoreEntry(day: day,
                                                    recovery: 70,
                                                    nutrition: negativeNutrition)
        var malformedWorkout = UserConfirmedWorkout(
            id: "workout",
            createdAt: day,
            start: day,
            end: day.addingTimeInterval(60),
            label: "Walking",
            source: "test",
            confidence: "test",
            sessions: 1,
            samples: 10,
            avgHR: 90,
            peakHR: 100,
            p95HR: 98,
            p99HR: 99,
            thresholdHR: 95,
            streamCoveragePercent: 90,
            observedDuration: 60,
            reason: "test"
        )
        malformedWorkout.zoneSeconds = ["z2": 10_000]
        let malformedSleep = UserConfirmedSleep(
            id: "overlapping-stages",
            createdAt: day.addingTimeInterval(3_700),
            start: day,
            end: day.addingTimeInterval(3_600),
            source: "test",
            confidence: "test",
            sessions: 1,
            samples: 100,
            avgHR: 60,
            peakHR: 70,
            restingHR: 55,
            hrv: 50,
            hrvWindowCount: 1,
            duration: 3_600,
            span: 3_600,
            reason: "test",
            motionSource: "test",
            motionValidated: true,
            stageSegments: [
                SleepStageSegment(id: "first", start: day,
                                  end: day.addingTimeInterval(2_000), stage: .light),
                SleepStageSegment(id: "second", start: day.addingTimeInterval(1_800),
                                  end: day.addingTimeInterval(3_600), stage: .rem)
            ])

        let malformed: [SessionBackupEnvelope] = [
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [unorderedSession], baseline: baseline, profile: profile),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: baseline, profile: profile,
                                  dailyMetrics: [reversedSleepMetric]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: baseline, profile: profile,
                                  dailyRollups: [malformedRollup]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: baseline, profile: profile,
                                  confirmedWorkouts: [malformedWorkout]),
            SessionBackupEnvelope(schema: 4, createdAt: day, app: "Atria.local",
                                  sessions: [], baseline: baseline, profile: profile,
                                  confirmedSleeps: [malformedSleep])
        ]

        for envelope in malformed {
            XCTAssertThrowsError(try SessionStore.validateSessionBackupEnvelopeForImport(envelope)) {
                XCTAssertEqual($0 as? SessionStore.SessionBackupImportError, .invalidDomain)
            }
        }
    }

    func testCalibrationEvidenceImportRequiresCanonicalDetectedReviewProvenance() throws {
        let day = Date(timeIntervalSince1970: 1_700_100_000)
        let end = day.addingTimeInterval(10 * 60)
        let sourceID = UUID()
        let profile = AthleteProfile(age: 30,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     updated: day,
                                     hasCompletedOnboarding: true)
        let canonicalBins = [0, 300].map { offset in
            AtriaActivityCalibrationEvidence.Bin(
                startOffsetSeconds: offset,
                durationSeconds: 300,
                hrSampleCount: 10,
                averageHR: 100,
                minimumHR: 90,
                maximumHR: 110,
                validatedMotionEpochs: 1,
                validatedMotionCoverageFraction: 1,
                meanStillnessRatio: 0.2,
                meanMovementIntensity: 0.4,
                meanP95VectorDelta: 0.3
            )
        }
        func evidence(algorithm: String = AtriaActivityCalibrationEvidence.algorithmVersion,
                      status: String = "ready",
                      sourceIDs: [UUID]? = nil,
                      sourceCount: Int = 1,
                      truncated: Bool = false,
                      bins: [AtriaActivityCalibrationEvidence.Bin]? = nil,
                      provenance: String = AtriaRecoveredMotionEpoch.source)
            -> AtriaActivityCalibrationEvidence {
            AtriaActivityCalibrationEvidence(
                schemaVersion: AtriaActivityCalibrationEvidence.schemaVersion,
                algorithmVersion: algorithm,
                windowStart: day,
                windowEnd: end,
                sourceSessionIDs: sourceIDs ?? [sourceID],
                sourceSessionCount: sourceCount,
                sourceSessionIDsTruncated: truncated,
                status: status,
                bins: bins ?? canonicalBins,
                motion: .init(epochCount: 2,
                              validatedEpochCount: 2,
                              validatedCoverageFraction: 1,
                              meanStillnessRatio: 0.2,
                              meanMovementIntensity: 0.4,
                              meanP95VectorDelta: 0.3,
                              provenance: provenance)
            )
        }
        func workout(reviewSource: String? = "detected_activity_review",
                     candidateID: String? = "candidate-1",
                     calibration: AtriaActivityCalibrationEvidence) -> UserConfirmedWorkout {
            UserConfirmedWorkout(id: UUID().uuidString,
                                 createdAt: day,
                                 start: day,
                                 end: end,
                                 label: "Walking",
                                 source: "manual_activity_add",
                                 confidence: "live_window_user_confirmed",
                                 sessions: 1,
                                 samples: 10,
                                 avgHR: 100,
                                 peakHR: 110,
                                 p95HR: 108,
                                 p99HR: 109,
                                 thresholdHR: 95,
                                 streamCoveragePercent: 100,
                                 observedDuration: 600,
                                 reason: "test",
                                 reviewSource: reviewSource,
                                 reviewCandidateID: candidateID,
                                 activityCalibrationEvidence: calibration)
        }
        func envelope(_ workout: UserConfirmedWorkout) -> SessionBackupEnvelope {
            SessionBackupEnvelope(schema: 4,
                                  createdAt: day,
                                  app: "Atria.local",
                                  sessions: [],
                                  baseline: PersonalBaseline(),
                                  profile: profile,
                                  confirmedWorkouts: [workout])
        }
        func assertRejected(_ workout: UserConfirmedWorkout,
                            file: StaticString = #filePath,
                            line: UInt = #line) {
            XCTAssertThrowsError(
                try SessionStore.validateSessionBackupEnvelopeForImport(envelope(workout)),
                file: file,
                line: line
            ) {
                XCTAssertEqual($0 as? SessionStore.SessionBackupImportError,
                               .invalidDomain,
                               file: file,
                               line: line)
            }
        }

        XCTAssertNoThrow(try SessionStore.validateSessionBackupEnvelopeForImport(
            envelope(workout(calibration: evidence()))
        ))
        assertRejected(workout(reviewSource: nil, calibration: evidence()))
        assertRejected(workout(candidateID: "   ", calibration: evidence()))
        assertRejected(workout(calibration: evidence(algorithm: "activity_calibration_unknown")))
        assertRejected(workout(calibration: evidence(status: "maybe_ready")))
        assertRejected(workout(calibration: evidence(sourceIDs: [sourceID, sourceID], sourceCount: 2)))
        assertRejected(workout(calibration: evidence(bins: [canonicalBins[0], canonicalBins[0]])))
        assertRejected(workout(calibration: evidence(provenance: "unverified_motion")))
    }

    @MainActor
    func testLargeArchiveValidationLeavesMainActorResponsive() async throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let pointCount = 75_000
        let session = SavedSession(
            id: UUID(),
            start: day,
            end: day.addingTimeInterval(TimeInterval(pointCount)),
            label: "large import",
            points: (0..<pointCount).map { .init(t: Double($0), bpm: 70 + ($0 % 30)) }
        )
        let envelope = SessionBackupEnvelope(
            schema: 4,
            createdAt: day,
            app: "Atria.local",
            sessions: [session],
            baseline: PersonalBaseline(restingHR: 60, hrvEMA: 50, sessions: 1, updated: day),
            profile: AthleteProfile(age: 30, measuredMaxHR: 190,
                                    maxHRSource: .measured, updated: day,
                                    hasCompletedOnboarding: true)
        )
        let payload = try JSONEncoder().encode(envelope)
        let workerStarted = expectation(description: "validation worker started")
        let mainHeartbeat = expectation(description: "main actor heartbeat")
        let workerFinished = expectation(description: "validation worker finished")
        let releaseValidation = DispatchSemaphore(value: 0)
        let result = LockedValidationResult()

        DispatchQueue.global(qos: .utility).async {
            workerStarted.fulfill()
            releaseValidation.wait()
            do {
                let decoded = try JSONDecoder().decode(SessionBackupEnvelope.self, from: payload)
                try SessionStore.validateSessionBackupEnvelopeForImport(decoded)
                result.set(success: true, performedOnMain: Thread.isMainThread)
            } catch {
                result.set(success: false, performedOnMain: Thread.isMainThread)
            }
            workerFinished.fulfill()
        }

        await fulfillment(of: [workerStarted], timeout: 2)
        DispatchQueue.main.async { mainHeartbeat.fulfill() }
        releaseValidation.signal()
        await fulfillment(of: [mainHeartbeat], timeout: 1)
        await fulfillment(of: [workerFinished], timeout: 5)

        XCTAssertTrue(result.success)
        XCTAssertFalse(result.performedOnMain)
    }
}

private final class LockedValidationResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSuccess = false
    private var storedPerformedOnMain = true

    func set(success: Bool, performedOnMain: Bool) {
        lock.lock()
        storedSuccess = success
        storedPerformedOnMain = performedOnMain
        lock.unlock()
    }

    var success: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedSuccess
    }

    var performedOnMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedPerformedOnMain
    }
}
