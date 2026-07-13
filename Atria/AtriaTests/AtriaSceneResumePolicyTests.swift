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
}
