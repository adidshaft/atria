import XCTest
@testable import Atria

/// Design-parity slice 6 (2026-08-01): the onboarding nickname (P1), rings (P2)
/// and cycle (P3) pages must bind to the REAL backing stores the rest of the app
/// reads — not cosmetic-only controls. These lock the persistence seam each page
/// control writes through, proving an onboarding choice actually takes effect.
///
/// Every case uses an isolated `UserDefaults` suite so a test never disturbs the
/// device's real defaults (and vice-versa). The one exception is
/// `AtriaCycleTracking`, which hardcodes `.standard`; that case saves and
/// restores the real value around its assertions.
@MainActor
final class AtriaOnboardingPersonalizationTests: XCTestCase {
    private var suiteName: String!
    private var store: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "atria.onboarding.personalization.tests.\(UUID().uuidString)"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
        store = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - Nickname (P1) -> the real "atria.user.nickname" greeting key

    func testNicknameKeyMatchesTodayScreenGreetingKey() {
        // The Today screen greets the user from this exact key, so the onboarding
        // field is wired to the real store, not a private copy.
        XCTAssertEqual(AtriaOnboardingPersonalization.nicknameKey, "atria.user.nickname")
    }

    func testPersistNicknameWritesTrimmedValueToRealKey() {
        AtriaOnboardingPersonalization.persistNickname("  Jamie  ", store: store)
        XCTAssertEqual(store.string(forKey: "atria.user.nickname"), "Jamie")
        XCTAssertEqual(AtriaOnboardingPersonalization.loadNickname(store: store), "Jamie")
    }

    func testPersistBlankNicknameRemovesKeySoSkippingLooksLikeSkipping() {
        store.set("Old", forKey: "atria.user.nickname")
        AtriaOnboardingPersonalization.persistNickname("   ", store: store)
        XCTAssertNil(store.string(forKey: "atria.user.nickname"))
        XCTAssertEqual(AtriaOnboardingPersonalization.loadNickname(store: store), "")
    }

    // MARK: - Ring slots (P2) -> the real "atria.today.ringMetrics" CSV

    func testRingMetricsKeyMatchesTodayScreenKey() {
        XCTAssertEqual(AtriaOnboardingPersonalization.ringMetricsKey, "atria.today.ringMetrics")
    }

    func testLoadRingSlotsDefaultsToOuterInnerSleepRecoveryStrain() {
        XCTAssertEqual(AtriaOnboardingPersonalization.loadRingSlots(store: store),
                       [.sleep, .recovery, .strain])
    }

    func testPersistRingSlotsWritesCSVTheTodayScreenCanParse() {
        AtriaOnboardingPersonalization.persistRingSlots([.strain, .recovery, .sleep], store: store)
        XCTAssertEqual(store.string(forKey: "atria.today.ringMetrics"), "strain,recovery,sleep")
        XCTAssertEqual(AtriaOnboardingPersonalization.loadRingSlots(store: store),
                       [.strain, .recovery, .sleep])
    }

    func testLoadRingSlotsAdoptsLegacyRingOrderSeedWhenMetricsUnset() {
        store.set("recovery,sleep,strain", forKey: "atria.today.ringOrder")
        XCTAssertEqual(AtriaOnboardingPersonalization.loadRingSlots(store: store),
                       [.recovery, .sleep, .strain])
    }

    func testAssignSwapsRatherThanDuplicatingAMetric() {
        // Putting recovery on the outer ring where sleep lived swaps the two,
        // never leaving one metric on two rings.
        let start: [AtriaTriRingSlot] = [.sleep, .recovery, .strain]
        let result = AtriaOnboardingPersonalization.assign(.recovery, toPosition: 0, in: start)
        XCTAssertEqual(result, [.recovery, .sleep, .strain])
    }

    // MARK: - Ring center metric (P2) -> AtriaHomeLayoutConfig JSON blob

    func testRingCenterMetricRoundTripsThroughRealLayoutConfig() {
        AtriaOnboardingPersonalization.persistRingCenterMetric(.strain, store: store)
        XCTAssertEqual(AtriaOnboardingPersonalization.loadRingCenterMetric(store: store), .strain)

        // Prove it landed inside the SAME AtriaHomeLayoutConfig blob the Today
        // screen and widget decode — not a separate onboarding-only key.
        let json = store.string(forKey: AtriaHomeLayoutConfig.storageKey)
        XCTAssertNotNil(json)
        let data = try! XCTUnwrap(json?.data(using: .utf8))
        let decoded = try! AtriaHomeLayoutConfig.decoded(from: data)
        XCTAssertEqual(decoded.ringCenterMetric, .strain)
    }

    func testRingCenterMetricPreservesOtherLayoutFields() {
        // Seed a customized layout, then change only the center metric: the rest
        // of the user's Today layout must survive untouched.
        var seeded = AtriaHomeLayoutConfig.default
        seeded.showAICoach = false
        seeded.glanceMetrics = ["hrv", "rhr"]
        let encoded = try! seeded.encodedData()
        store.set(String(data: encoded, encoding: .utf8), forKey: AtriaHomeLayoutConfig.storageKey)

        AtriaOnboardingPersonalization.persistRingCenterMetric(.sleep, store: store)

        let data = try! XCTUnwrap(store.string(forKey: AtriaHomeLayoutConfig.storageKey)?.data(using: .utf8))
        let decoded = try! AtriaHomeLayoutConfig.decoded(from: data)
        XCTAssertEqual(decoded.ringCenterMetric, .sleep)
        XCTAssertFalse(decoded.showAICoach)
        XCTAssertEqual(decoded.glanceMetrics, ["hrv", "rhr"])
    }

    func testLoadRingCenterMetricFallsBackToDefaultWhenUnset() {
        XCTAssertEqual(AtriaOnboardingPersonalization.loadRingCenterMetric(store: store),
                       AtriaHomeLayoutConfig.default.ringCenterMetric)
    }

    // MARK: - Cycle tracking (P3) -> the real AtriaCycleTracking flag, default OFF

    func testCycleTrackingDefaultsOffAndTheOnboardingToggleFlipsTheRealFlag() {
        let key = AtriaCycleTracking.enabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        // Default OFF matches the product decision (sensitive health data is
        // never enabled silently).
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(AtriaCycleTracking.isEnabled)

        // The cycle page's toggle writes through this exact canonical path.
        AtriaCycleTracking.setEnabled(true)
        XCTAssertTrue(AtriaCycleTracking.isEnabled)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        AtriaCycleTracking.setEnabled(false)
        XCTAssertFalse(AtriaCycleTracking.isEnabled)
    }

    // MARK: - Research sharing (P4) default stance (post-flow consent step)

    func testResearchSharingDefaultsOptOutFalseUntilConsentGranted() {
        // P4 is presented ON by default but only ever becomes real through the
        // inspector-gated consent step; the underlying flag stays false until
        // grantConsent runs. This locks the honest default so the onboarding
        // slice never fakes an opted-in state.
        let key = AtriaResearchSharing.optInKey
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(AtriaResearchSharing.isOptedIn)
    }
}
