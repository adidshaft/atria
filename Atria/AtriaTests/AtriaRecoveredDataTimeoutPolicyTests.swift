import XCTest
@testable import Atria

final class AtriaRecoveredDataTimeoutPolicyTests: XCTestCase {
    func testPhysicalProjectionLeaseCoversMeasuredReleaseEvidence() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let measuredPipelineMilestoneSeconds = 95.923

        XCTAssertGreaterThanOrEqual(
            Double(policy.projectionLeaseSeconds),
            measuredPipelineMilestoneSeconds * 1.5,
            "projection watchdog must retain measured physical headroom"
        )
        XCTAssertEqual(policy.projectionLeaseSeconds, 150)
        XCTAssertEqual(policy.maximumProjectionLeaseRenewals, 8)
        XCTAssertEqual(policy.maximumDerivedStageLeaseRenewals, 5)
        XCTAssertEqual(policy.projectionLeaseRenewalMinimumBytes,
                       8 * 1_024 * 1_024)
        XCTAssertEqual(policy.projectionLeaseRenewalMinimumIntervalSeconds, 75)
        XCTAssertLessThanOrEqual(
            policy.projectionLeaseSeconds,
            180,
            "the projection watchdog must remain finite and bounded"
        )
    }

    func testPhysicalDerivedLeaseHasMeasuredPerComponentHeadroom() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore

        XCTAssertGreaterThan(policy.derivedComponentLeaseSeconds, 96)
        XCTAssertEqual(policy.derivedComponentLeaseSeconds, 150)
        XCTAssertLessThanOrEqual(policy.derivedComponentLeaseSeconds, 180,
                                 "the progress lease must remain bounded")
    }

    func testSessionPublicationWaitCoversEveryFiniteInternalLease() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let componentCount = AtriaRecoveredDataRecomputeCoordinator
            .sessionStoreComponents.count
        let expected = policy.projectionLeaseSeconds
            * (1 + policy.maximumProjectionLeaseRenewals)
            + componentCount * policy.derivedComponentLeaseSeconds
            + policy.maximumDerivedStageLeaseRenewals
                * policy.derivedComponentLeaseSeconds
            + policy.publicationSchedulingGraceSeconds

        XCTAssertEqual(SessionStore.recoveredDataMaximumPipelineWaitSeconds,
                       expected)
        XCTAssertEqual(expected, 3_330)
    }

    func testShortRequestedWaitCannotUndercutInternalPipelineBound() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let componentCount = AtriaRecoveredDataRecomputeCoordinator
            .sessionStoreComponents.count

        XCTAssertEqual(policy.publicationWaitSeconds(
            requestedSeconds: 25,
            requiredDerivedComponentCount: componentCount
        ), 3_330)
        XCTAssertEqual(policy.publicationWaitSeconds(
            requestedSeconds: 3_000,
            requiredDerivedComponentCount: componentCount
        ), 3_330)
        XCTAssertEqual(SessionStore.recoveredDataPublicationWaitDuration(
            requested: .seconds(25)
        ), .seconds(3_330))
        XCTAssertEqual(SessionStore.recoveredDataPublicationWaitDuration(
            requested: .seconds(3_000)
        ), .seconds(3_330))
    }

    func testProjectionLeaseRenewsOnlyForMeasuredBoundedProgress() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore
        let threshold = policy.projectionLeaseRenewalMinimumBytes

        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLease(
            newByteCount: threshold,
            lastRenewedByteCount: 0,
            secondsSinceLastRenewal: 74.999,
            renewalsUsed: 0,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLease(
            newByteCount: threshold - 1,
            lastRenewedByteCount: 0,
            secondsSinceLastRenewal: 75,
            renewalsUsed: 0,
            policy: policy
        ))
        XCTAssertTrue(SessionStore.shouldRenewRecoveredProjectionLease(
            newByteCount: threshold,
            lastRenewedByteCount: 0,
            secondsSinceLastRenewal: 75,
            renewalsUsed: 0,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLease(
            newByteCount: threshold * 9,
            lastRenewedByteCount: threshold * 8,
            secondsSinceLastRenewal: 75,
            renewalsUsed: policy.maximumProjectionLeaseRenewals,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLease(
            newByteCount: threshold - 1,
            lastRenewedByteCount: threshold,
            secondsSinceLastRenewal: 75,
            renewalsUsed: 0,
            policy: policy
        ))
    }

    func testProjectionStageLeaseRenewsOnlyForNewFiniteProgress() {
        let policy = AtriaRecoveredDataTimeoutPolicy.physicalSessionStore

        XCTAssertTrue(SessionStore.shouldRenewRecoveredProjectionLeaseForStage(
            stage: "archive_snapshot",
            completedStages: [],
            renewalsUsed: 0,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLeaseForStage(
            stage: "archive_snapshot",
            completedStages: ["archive_snapshot"],
            renewalsUsed: 1,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLeaseForStage(
            stage: "",
            completedStages: [],
            renewalsUsed: 0,
            policy: policy
        ))
        XCTAssertFalse(SessionStore.shouldRenewRecoveredProjectionLeaseForStage(
            stage: "motion_projection",
            completedStages: [],
            renewalsUsed: policy.maximumProjectionLeaseRenewals,
            policy: policy
        ))
    }

    func testRecoveredWorkoutRepairCannotReachBeforeProjectionCoverage() {
        let coverageStart = Date(timeIntervalSince1970: 10_000)

        XCTAssertTrue(SessionStore.confirmedWorkoutFallsWithinRecoveredArchive(
            workoutStart: coverageStart,
            coverageStart: coverageStart
        ))
        XCTAssertTrue(SessionStore.confirmedWorkoutFallsWithinRecoveredArchive(
            workoutStart: coverageStart.addingTimeInterval(1),
            coverageStart: coverageStart
        ))
        XCTAssertFalse(SessionStore.confirmedWorkoutFallsWithinRecoveredArchive(
            workoutStart: coverageStart.addingTimeInterval(-0.001),
            coverageStart: coverageStart
        ))
    }

    func testRecoveredDailyPreparationIsScopedToAffectedAndActiveCycle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let physiologicalStart = now.addingTimeInterval(-6 * 60 * 60)
        let affectedStart = calendar.startOfDay(
            for: now.addingTimeInterval(-2 * 24 * 60 * 60)
        )
        func session(start: Date, label: String) -> SavedSession {
            SavedSession(
                id: UUID(),
                start: start,
                end: start.addingTimeInterval(10 * 60),
                label: label,
                points: [SavedSession.Point(t: 0, bpm: 70)]
            )
        }
        let affected = session(
            start: affectedStart.addingTimeInterval(12 * 60 * 60),
            label: "affected"
        )
        let active = session(
            start: physiologicalStart.addingTimeInterval(60),
            label: "active"
        )
        let unrelated = session(
            start: affectedStart.addingTimeInterval(-2 * 24 * 60 * 60),
            label: "unrelated"
        )

        let selected = SessionStore.recoveredDailyPreparationSessions(
            sessions: [unrelated, active, affected],
            affectedDays: [affectedStart],
            physiologicalDayStart: physiologicalStart,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(Set(selected.map(\.id)), [affected.id, active.id])
    }
}
