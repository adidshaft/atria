import XCTest
@testable import Atria

/// The pill's wear/charge attribution: every claim is evidence-backed, and
/// ambiguity keeps the existing copy (returns .none). Device-measured shape
/// 2026-08-28: off-wrist charging strap streamed HR==0 frames (state .live,
/// no pulse) alternating with >120 s silences (.silentUnknown) all night.
final class AtriaStrapWearAttributionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func classify(
        state: AtriaBLEManager.StrapStreamState,
        freshPulse: Bool = false,
        acceptedAgo: TimeInterval? = nil,
        charging: Bool = false,
        dropping: Bool = false
    ) -> AtriaStrapWearAttribution {
        AtriaStrapWearAttribution.classify(
            streamState: state,
            hasFreshPulse: freshPulse,
            lastAcceptedPulseAt: acceptedAgo.map { now.addingTimeInterval(-$0) },
            chargingProven: charging,
            batteryRecentlyDropping: dropping,
            now: now)
    }

    // MARK: - The measured night

    func testPulselessStreamClaimsOffWrist() {
        XCTAssertEqual(classify(state: .live, acceptedAgo: 10 * 60), .offWrist)
    }

    func testPulselessStreamWithProvenChargingSaysCharging() {
        XCTAssertEqual(classify(state: .live, acceptedAgo: 10 * 60,
                                charging: true), .charging)
    }

    func testSilentStreamWithProvenChargingSaysCharging() {
        XCTAssertEqual(classify(state: .silentUnknown, acceptedAgo: 20 * 60,
                                charging: true), .charging)
    }

    // MARK: - Ambiguity keeps the honest copy

    func testSilentStreamAloneClaimsNothing() {
        XCTAssertEqual(classify(state: .silentUnknown, acceptedAgo: 20 * 60),
                       .none,
                       "a stopped stream carries no wear evidence of its own")
    }

    func testBriefZeroRunNeverClaims() {
        XCTAssertEqual(classify(state: .live, acceptedAgo: 3 * 60 + 59), .none,
                       "hysteresis: a fit adjustment must not flap the pill")
        XCTAssertEqual(classify(state: .live, acceptedAgo: 4 * 60), .offWrist)
    }

    func testASessionThatNeverAcceptedStaysUnclaimed() {
        XCTAssertEqual(classify(state: .live, acceptedAgo: nil), .none,
                       "no accepted sample means no measured zero-run start")
    }

    // MARK: - Contradictions and stronger truths win

    func testAFreshPulseAlwaysWins() {
        XCTAssertEqual(classify(state: .live, freshPulse: true,
                                acceptedAgo: 10 * 60, charging: true), .none)
    }

    func testADroppingBatteryRefutesCharging() {
        XCTAssertEqual(classify(state: .live, acceptedAgo: 10 * 60,
                                charging: true, dropping: true), .offWrist,
                       "a falling level contradicts the charging story; the "
                           + "off-wrist evidence stands on its own")
        XCTAssertEqual(classify(state: .silentUnknown, acceptedAgo: 20 * 60,
                                charging: true, dropping: true), .none)
    }

    func testLowBatteryStatesKeepTheirOwnAttribution() {
        XCTAssertEqual(classify(state: .lowBatteryShutoff, acceptedAgo: 10 * 60,
                                charging: true), .none)
        XCTAssertEqual(classify(state: .lowBatteryReducedDetail,
                                acceptedAgo: 10 * 60, charging: true), .none)
    }

    func testWarmingAndUnknownClaimNothing() {
        XCTAssertEqual(classify(state: .warming, acceptedAgo: 10 * 60,
                                charging: true), .none)
        XCTAssertEqual(classify(state: .unknown, acceptedAgo: 10 * 60,
                                charging: true), .none)
    }
}
