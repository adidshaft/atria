import XCTest
@testable import Atria

final class AtriaPendingSleepReviewStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        suiteName = "AtriaPendingSleepReviewStoreTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    func testQualifiedReviewSurvivesRelaunchProjectionLoss() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let night = makeNight(now: now)
        AtriaPendingSleepReviewStore.save(
            night,
            now: now,
            defaults: defaults
        )

        let restored = AtriaPendingSleepReviewStore.load(
            now: now.addingTimeInterval(60),
            confirmedSleeps: [],
            dismissedCandidates: [],
            defaults: defaults
        )

        XCTAssertEqual(restored, night)
    }

    func testConfirmedOverlapCannotReappear() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let night = makeNight(now: now)
        AtriaPendingSleepReviewStore.save(
            night,
            now: now,
            defaults: defaults
        )
        let confirmed = UserConfirmedSleep(
            id: "confirmed",
            createdAt: now,
            start: try XCTUnwrap(night.start),
            end: try XCTUnwrap(night.end),
            source: "user_confirmed_sleep",
            confidence: "user_confirmed_sleep",
            sessions: 1,
            samples: 300,
            avgHR: 60,
            peakHR: 72,
            restingHR: 55,
            hrv: nil,
            hrvWindowCount: nil,
            respiratoryRate: nil,
            duration: night.duration,
            span: night.duration,
            reason: "test",
            motionSource: "strap",
            motionValidated: true,
            stageSegments: nil,
            eventTimeZoneIdentifier: nil
        )

        XCTAssertNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [confirmed],
                dismissedCandidates: [],
                defaults: defaults
            )
        )
    }

    func testDismissalClearsDurableReview() throws {
        let now = Date(timeIntervalSince1970: 200_000)
        let night = makeNight(now: now)
        AtriaPendingSleepReviewStore.save(
            night,
            now: now,
            defaults: defaults
        )
        AtriaPendingSleepReviewStore.clear(
            overlappingStart: try XCTUnwrap(night.start),
            end: try XCTUnwrap(night.end),
            defaults: defaults
        )

        XCTAssertNil(
            AtriaPendingSleepReviewStore.load(
                now: now,
                confirmedSleeps: [],
                dismissedCandidates: [],
                defaults: defaults
            )
        )
    }

    func testStaleReviewExpires() {
        let now = Date(timeIntervalSince1970: 200_000)
        let night = makeNight(now: now)
        AtriaPendingSleepReviewStore.save(
            night,
            now: now,
            defaults: defaults
        )

        XCTAssertNil(
            AtriaPendingSleepReviewStore.load(
                now: now.addingTimeInterval(
                    AtriaPendingSleepReviewStore.maximumAge + 1
                ),
                confirmedSleeps: [],
                dismissedCandidates: [],
                defaults: defaults
            )
        )
    }

    private func makeNight(now: Date) -> SleepHistorySnapshot.Night {
        let end = now.addingTimeInterval(-60)
        let start = end.addingTimeInterval(-8 * 60 * 60)
        return .init(
            id: "sleep-review-test",
            day: end,
            start: start,
            end: end,
            duration: 7 * 60 * 60,
            restingHR: 55,
            hrv: 42,
            hrvWindowCount: 2,
            respiratoryRate: 14.2,
            sleepEfficiency: 0.875,
            confidence: "review_needed",
            source: "aggregate_sleep",
            confirmed: false,
            stageSegments: []
        )
    }
}
