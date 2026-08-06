import XCTest
@testable import Atria

final class AtriaSceneResumePolicyTests: XCTestCase {
    func testTransientInactiveEdgeDoesNotCheckpointOrStopMotion() {
        XCTAssertFalse(AtriaSceneResumePolicy.shouldRunInactiveCheckpoint(
            isStillInactive: true,
            elapsed: AtriaSceneResumePolicy.inactiveCheckpointDelay - 0.01
        ))
        XCTAssertFalse(AtriaSceneResumePolicy.shouldRunInactiveCheckpoint(
            isStillInactive: false,
            elapsed: AtriaSceneResumePolicy.inactiveCheckpointDelay
        ))
        XCTAssertFalse(AtriaSceneResumePolicy.shouldStopMotionMonitor(isBackground: false))
    }

    func testSustainedInactiveCheckpointAndBackgroundMotionStopRemainDurable() {
        XCTAssertTrue(AtriaSceneResumePolicy.shouldRunInactiveCheckpoint(
            isStillInactive: true,
            elapsed: AtriaSceneResumePolicy.inactiveCheckpointDelay
        ))
        XCTAssertTrue(AtriaSceneResumePolicy.shouldStopMotionMonitor(isBackground: true))
    }

    func testBLEBoundaryDefersAnalyticalPublicationOutsideActiveScene() {
        XCTAssertTrue(AtriaSceneResumePolicy.shouldDeferSessionBoundaryDerivedPublication(
            isApplicationActive: false
        ))
        XCTAssertFalse(AtriaSceneResumePolicy.shouldDeferSessionBoundaryDerivedPublication(
            isApplicationActive: true
        ))
    }

    func testHealthyConnectedWorkoutUsesFastForegroundPathRegardlessOfRadioMode() {
        XCTAssertTrue(AtriaBLEManager.shouldUseFastWorkoutForegroundResume(
            activeExplicitWorkout: true,
            hasLiveSession: true,
            linkConnected: true
        ))
    }

    func testWorkoutFastPathFailsClosedToRecoveryWhenAnyEvidenceIsMissing() {
        XCTAssertFalse(AtriaBLEManager.shouldUseFastWorkoutForegroundResume(
            activeExplicitWorkout: false,
            hasLiveSession: true,
            linkConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseFastWorkoutForegroundResume(
            activeExplicitWorkout: true,
            hasLiveSession: false,
            linkConnected: true
        ))
        XCTAssertFalse(AtriaBLEManager.shouldUseFastWorkoutForegroundResume(
            activeExplicitWorkout: true,
            hasLiveSession: true,
            linkConnected: false
        ))
    }

    func testForegroundSleepEvaluationIsRecentCappedAndMergesActiveJournal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let replacedID = UUID()
        let sessions = (0..<700).map { index in
            let id = index == 10 ? replacedID : UUID()
            let start = now.addingTimeInterval(-TimeInterval(index) * 10 * 60)
            return SavedSession(id: id,
                                start: start,
                                end: start.addingTimeInterval(5 * 60),
                                label: "Wear",
                                points: [SavedSession.Point(t: 0, bpm: 60)])
        } + [SavedSession(id: UUID(),
                          start: now.addingTimeInterval(-8 * 24 * 60 * 60),
                          end: now.addingTimeInterval(-8 * 24 * 60 * 60 + 300),
                          label: "Old",
                          points: [SavedSession.Point(t: 0, bpm: 60)])]
        let activeStart = now.addingTimeInterval(-30 * 60)
        let active = SavedSession(id: replacedID,
                                  start: activeStart,
                                  end: now,
                                  label: "Active journal",
                                  points: [SavedSession.Point(t: 0, bpm: 58),
                                           SavedSession.Point(t: 60, bpm: 59)])

        let bounded = SessionStore.foregroundSleepEvaluationSessions(
            from: sessions,
            activeJournalSession: active,
            now: now
        )

        XCTAssertEqual(bounded.count, SessionStore.foregroundSleepEvaluationMaximumSessions)
        XCTAssertEqual(bounded.filter { $0.id == replacedID }.count, 1)
        XCTAssertEqual(bounded.first { $0.id == replacedID }?.points.count, 2)
        XCTAssertTrue(bounded.allSatisfy {
            $0.start >= now.addingTimeInterval(-7 * 24 * 60 * 60)
        })
        XCTAssertEqual(bounded.map(\.start), bounded.map(\.start).sorted(by: >))
    }

    func testMorningSleepEvaluationRetainsResidentJournalAfterLiveFreshnessExpires() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = residentJournalRecord(latestEvidenceAt: now.addingTimeInterval(-2 * 60),
                                           updatedAt: now)

        XCTAssertTrue(SessionStore.activeJournalRecordIsEligibleForSleepEvaluation(
            record,
            now: now
        ), "a durable two-minute-old overnight tail must remain available to morning settlement")
    }

    func testMorningSleepEvaluationUsesEvidenceAgeAndRejectsExpiredOrInvalidJournal() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredEvidence = residentJournalRecord(
            latestEvidenceAt: now.addingTimeInterval(
                -SessionStore.residentSleepEvaluationJournalMaximumAge - 1
            ),
            updatedAt: now
        )
        let wrongSchema = residentJournalRecord(latestEvidenceAt: now.addingTimeInterval(-60),
                                                updatedAt: now,
                                                schema: ActiveSessionJournal.schema + 1)
        let metadataOnlyRefresh = residentJournalRecord(
            latestEvidenceAt: now.addingTimeInterval(-20 * 60 * 60),
            updatedAt: now
        )

        XCTAssertFalse(SessionStore.activeJournalRecordIsEligibleForSleepEvaluation(
            expiredEvidence,
            now: now
        ))
        XCTAssertFalse(SessionStore.activeJournalRecordIsEligibleForSleepEvaluation(
            wrongSchema,
            now: now
        ))
        XCTAssertFalse(SessionStore.activeJournalRecordIsEligibleForSleepEvaluation(
            metadataOnlyRefresh,
            now: now
        ), "a lifecycle metadata checkpoint must not revive old physiological evidence")
    }

    func testForegroundSleepSettlementCommitRequiresCurrentGenerationAndFingerprint() {
        let prepared = SessionStore.ForegroundSleepSettlementFingerprint(
            canonicalSessionsRevision: 9,
            confirmedSleepsRevision: 4,
            restingHR: 58,
            baselineRestingIsTrusted: true,
            baselineRestingIsNearTrusted: true,
            maxHR: 190
        )

        XCTAssertTrue(SessionStore.shouldCommitForegroundSleepSettlement(
            completedGeneration: 3,
            currentGeneration: 3,
            preparedFingerprint: prepared,
            currentFingerprint: prepared
        ))
        XCTAssertFalse(SessionStore.shouldCommitForegroundSleepSettlement(
            completedGeneration: 2,
            currentGeneration: 3,
            preparedFingerprint: prepared,
            currentFingerprint: prepared
        ))
        XCTAssertFalse(SessionStore.shouldCommitForegroundSleepSettlement(
            completedGeneration: 3,
            currentGeneration: 3,
            preparedFingerprint: prepared,
            currentFingerprint: .init(canonicalSessionsRevision: 10,
                                      confirmedSleepsRevision: 4,
                                      restingHR: 58,
                                      baselineRestingIsTrusted: true,
                                      baselineRestingIsNearTrusted: true,
                                      maxHR: 190)
        ))
        XCTAssertFalse(SessionStore.shouldCommitForegroundSleepSettlement(
            completedGeneration: 3,
            currentGeneration: 3,
            preparedFingerprint: prepared,
            currentFingerprint: .init(canonicalSessionsRevision: 9,
                                      confirmedSleepsRevision: 4,
                                      restingHR: 58,
                                      baselineRestingIsTrusted: false,
                                      baselineRestingIsNearTrusted: true,
                                      maxHR: 190)
        ), "baseline trust is part of the mutation identity even when its numeric value is unchanged")
    }

    func testForegroundSleepSettlementProposalCanBuildAwayFromMainThread() async {
        let result = await Task.detached(priority: .utility) {
            let wasMainThread = Thread.isMainThread
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let fingerprint = SessionStore.ForegroundSleepSettlementFingerprint(
                canonicalSessionsRevision: 1,
                confirmedSleepsRevision: 2,
                restingHR: 60,
                baselineRestingIsTrusted: false,
                baselineRestingIsNearTrusted: false,
                maxHR: 190
            )
            let activeJournal = SavedSession(
                id: UUID(),
                start: now.addingTimeInterval(-30 * 60),
                end: now,
                label: "Resident overnight journal",
                points: (0..<30).map {
                    SavedSession.Point(t: TimeInterval($0 * 60), bpm: 58)
                },
                rrPoints: (0..<30).map {
                    SavedSession.RRPoint(t: TimeInterval($0 * 60),
                                         ms: 1_000,
                                         source: .standardHeartRateMeasurement2A37)
                }
            )
            let proposal = SessionStore.makeForegroundSleepSettlementProposal(
                fingerprint: fingerprint,
                canonicalSessions: [],
                activeJournalSession: activeJournal,
                now: now,
                rest: 60,
                maxHR: 190,
                learnedWindow: nil
            )

            return (wasMainThread, fingerprint, activeJournal.id, proposal)
        }.value

        XCTAssertFalse(result.0)
        XCTAssertEqual(result.3.fingerprint, result.1)
        XCTAssertEqual(result.3.sourceSessions.map(\.id), [result.2],
                       "the off-main resident journal must survive into stage/HRV construction")
        XCTAssertTrue(result.3.strongCandidates.isEmpty)
        XCTAssertNil(result.3.wakeBoundary.candidate)
    }

    private func residentJournalRecord(
        latestEvidenceAt: Date,
        updatedAt: Date,
        schema: Int = ActiveSessionJournal.schema
    ) -> ActiveSessionJournalRecord {
        ActiveSessionJournalRecord(
            schema: schema,
            id: UUID(),
            label: "Resident overnight journal",
            startedAt: latestEvidenceAt.addingTimeInterval(-60),
            updatedAt: updatedAt,
            samples: [
                .init(t: latestEvidenceAt.addingTimeInterval(-60), bpm: 58),
                .init(t: latestEvidenceAt, bpm: 57)
            ],
            rrSamples: [
                .init(t: latestEvidenceAt.addingTimeInterval(-1),
                      ms: 1_000,
                      source: .standardHeartRateMeasurement2A37)
            ],
            rawHRNotifications: 2,
            acceptedHRSamples: 2,
            zeroHRSamples: 0,
            heldArtifacts: 0,
            droppedArtifacts: 0,
            rawHRGaps: 0,
            acceptedHRGaps: 0,
            maxRawHRGap: 60,
            maxAcceptedHRGap: 60,
            batteryLevel: 58,
            thermalState: "nominal",
            lowPowerMode: false,
            powerMode: "normal",
            cadenceMultiplier: 1,
            strengthSets: nil,
            excludedIntervals: nil
        )
    }
}
