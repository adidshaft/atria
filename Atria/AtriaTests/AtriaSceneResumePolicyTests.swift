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

    func testForegroundSleepSettlementCommitRequiresCurrentGenerationAndFingerprint() {
        let prepared = SessionStore.ForegroundSleepSettlementFingerprint(
            canonicalSessionsRevision: 9,
            confirmedSleepsRevision: 4,
            restingHR: 58,
            baselineRestingIsTrusted: true,
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
                                      maxHR: 190)
        ), "baseline trust is part of the mutation identity even when its numeric value is unchanged")
    }

    func testForegroundSleepSettlementProposalCanBuildAwayFromMainThread() {
        let completed = expectation(description: "utility proposal")
        DispatchQueue.global(qos: .utility).async {
            XCTAssertFalse(Thread.isMainThread)
            let fingerprint = SessionStore.ForegroundSleepSettlementFingerprint(
                canonicalSessionsRevision: 1,
                confirmedSleepsRevision: 2,
                restingHR: 60,
                baselineRestingIsTrusted: false,
                maxHR: 190
            )
            let proposal = SessionStore.makeForegroundSleepSettlementProposal(
                fingerprint: fingerprint,
                canonicalSessions: [],
                activeJournalSession: nil,
                now: Date(timeIntervalSince1970: 1_800_000_000),
                rest: 60,
                maxHR: 190,
                learnedWindow: nil
            )

            XCTAssertEqual(proposal.fingerprint, fingerprint)
            XCTAssertTrue(proposal.strongCandidates.isEmpty)
            XCTAssertNil(proposal.wakeBoundary.candidate)
            completed.fulfill()
        }
        // The full test plan launches several simulator clones concurrently;
        // allow utility work to survive that harness-only scheduling pressure.
        wait(for: [completed], timeout: 5)
    }
}
