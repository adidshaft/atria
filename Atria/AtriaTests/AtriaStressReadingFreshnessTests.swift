import XCTest
@testable import Atria

final class AtriaStressReadingFreshnessTests: XCTestCase {
    private func scoredState(level: AtriaStressLevel = .medium) -> AtriaStressState {
        AtriaStressState(level: level,
                         label: level.title,
                         detail: "Personal HR + HRV",
                         kind: .scored,
                         confidence: 1,
                         rawActivation: 0.6,
                         hrvAvailable: true)
    }

    func testFreshScoredReadingIsLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: now.addingTimeInterval(-30),
            now: now
        ), .live)
    }

    func testOldScoredReadingIsStaleInsteadOfLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: now.addingTimeInterval(-91),
            now: now
        ), .stale)
    }

    func testFreshReadingBeforePhysiologicalCycleIsNotLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: now.addingTimeInterval(-30),
            physiologicalCycleStart: now.addingTimeInterval(-15),
            now: now
        ), .previousPhysiologicalCycle)
    }

    func testReadingAtPhysiologicalCycleBoundaryCanBeLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let boundary = now.addingTimeInterval(-30)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: boundary,
            physiologicalCycleStart: boundary,
            now: now
        ), .live)
    }

    func testPhysiologicalRolloverCanExpireBeforeAgeLease() {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let rollover = measuredAt.addingTimeInterval(40)
        XCTAssertEqual(
            AtriaStressReadingFreshness.expirationDeadline(
                updatedAt: measuredAt,
                nextPhysiologicalCycleStart: rollover
            ),
            rollover
        )
    }

    func testAgeLeaseStillWinsWhenRolloverIsLater() {
        let measuredAt = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(
            AtriaStressReadingFreshness.expirationDeadline(
                updatedAt: measuredAt,
                nextPhysiologicalCycleStart: measuredAt.addingTimeInterval(600)
            ),
            measuredAt.addingTimeInterval(AtriaStressReadingFreshness.liveWindow)
        )
    }

    func testScoredReadingWithoutClockIsUntimedInsteadOfLive() {
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: true,
            updatedAt: nil
        ), .untimed)
    }

    func testUnscoredStateNeverClaimsLive() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertEqual(AtriaStressReadingFreshness.resolve(
            isScored: false,
            updatedAt: now,
            now: now
        ), .untimed)
    }

    func testHomeHeroPreservesFreshScoredStress() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let presentation = AtriaHomeModel.HeroSnapshot.resolvedStressPresentation(
            state: scoredState(),
            lastMeasuredAt: now.addingTimeInterval(-30),
            now: now
        )

        XCTAssertEqual(presentation.level, .medium)
        XCTAssertEqual(presentation.value, "1.8 / 3")
        XCTAssertEqual(presentation.detail, "Medium · Personal HR + HRV")
    }

    func testHomeHeroHidesStaleScoredStress() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let presentation = AtriaHomeModel.HeroSnapshot.resolvedStressPresentation(
            state: scoredState(level: .high),
            lastMeasuredAt: now.addingTimeInterval(-91),
            now: now
        )

        XCTAssertNil(presentation.level)
        XCTAssertEqual(presentation.value, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(presentation.detail, "Waiting for a fresh stress reading")
        XCTAssertFalse(presentation.narrative.contains("High"))
    }

    func testHomeHeroHidesUntimedScoredStress() {
        let presentation = AtriaHomeModel.HeroSnapshot.resolvedStressPresentation(
            state: scoredState(level: .low),
            lastMeasuredAt: nil
        )

        XCTAssertNil(presentation.level)
        XCTAssertEqual(presentation.value, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(presentation.detail, "Reading time unavailable")
        XCTAssertFalse(presentation.narrative.contains("Low"))
    }

    func testHomeHeroHidesFreshStressFromPreviousPhysiologicalCycle() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let presentation = AtriaHomeModel.HeroSnapshot.resolvedStressPresentation(
            state: scoredState(level: .medium),
            lastMeasuredAt: now.addingTimeInterval(-30),
            physiologicalCycleStart: now.addingTimeInterval(-15),
            now: now
        )

        XCTAssertNil(presentation.level)
        XCTAssertEqual(presentation.value, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(presentation.detail, "Waiting for this cycle's first stress reading")
        XCTAssertTrue(presentation.narrative.contains("previous physiological day"))
    }

    func testHomeHeroLeavesUnscoredPresentationUnchangedWithoutClock() {
        let state = AtriaStressState(level: nil,
                                     label: "Warming up",
                                     detail: "",
                                     kind: .warmingUp,
                                     confidence: 0,
                                     rawActivation: 0,
                                     hrvAvailable: false)

        XCTAssertEqual(
            AtriaHomeModel.HeroSnapshot.resolvedStressPresentation(
                state: state,
                lastMeasuredAt: nil
            ),
            AtriaStressPresentation.make(state: state)
        )
    }
}
