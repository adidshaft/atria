import XCTest
@testable import Atria

/// Every surface that renders the strap connection must render it the SAME
/// way at the same instant. Before the 2026-08-28 uniformity pass the Home
/// pill, the Strap screen and the Overview/Today card each carried their own
/// rule: with a fresh pulse and a lagging stream the pill said "Live" while
/// the Overview card said "Waiting" and the Strap screen said "No signal" —
/// the Strap screen having just promoted its own status to "connected"
/// *because* that pulse existed.
final class AtriaConnectionSurfaceAgreementTests: XCTestCase {

    private let allStates: [AtriaBLEManager.StrapStreamState] = [
        .live, .warming, .silentUnknown, .unknown,
        .lowBatteryShutoff, .lowBatteryReducedDetail,
    ]

    // MARK: - The shared rule

    func testLaggingStreamStatesAreOverriddenByAFreshPulse() {
        for state in [AtriaBLEManager.StrapStreamState.warming, .silentUnknown, .unknown] {
            XCTAssertTrue(
                AtriaLiveSignalTruth.freshPulseOverridesLaggingStream(
                    hasPulseSignal: true, streamState: state),
                "a live BPM outranks a lagging \(state) projection")
        }
    }

    func testLowBatteryOutranksTheOverride() {
        for state in [AtriaBLEManager.StrapStreamState.lowBatteryShutoff,
                      .lowBatteryReducedDetail] {
            XCTAssertFalse(
                AtriaLiveSignalTruth.freshPulseOverridesLaggingStream(
                    hasPulseSignal: true, streamState: state),
                "\(state) tells the wearer something the pulse cannot")
        }
    }

    func testNoPulseNeverOverridesAnything() {
        for state in allStates {
            XCTAssertFalse(
                AtriaLiveSignalTruth.freshPulseOverridesLaggingStream(
                    hasPulseSignal: false, streamState: state))
        }
    }

    // MARK: - Surface agreement

    /// The pill and the shared truth helper must agree on "is this Live" for
    /// every reachable state.
    ///
    /// Compared via the pill's TONE, not its text: when the strap is live the
    /// pill deliberately spends its label on the battery percentage
    /// (`freshPulse || streamState == .live` at the battery branch), so green
    /// is where the pill states liveness. A first version of this test
    /// compared labels and "failed" on the pill's intended design — the code
    /// was right and the test was wrong.
    func testPillAndSharedTruthAgreeOnLiveForEveryState() {
        for state in allStates {
            let presentation = AtriaTopStatusProjection.presentation(
                input: input(streamState: state, hasPulse: true),
                now: now)
            let truthSaysLive = AtriaLiveSignalTruth.isLive(
                status: .connected,
                streamState: state,
                hasRecentHeartRate: true)
            XCTAssertEqual(
                presentation.tone == .green, truthSaysLive,
                "pill and Overview disagree for \(state) with a live pulse")
        }
    }

    /// Without a pulse neither surface may claim live.
    func testNeitherSurfaceClaimsLiveWithoutAPulse() {
        for state in allStates where state != .live {
            let presentation = AtriaTopStatusProjection.presentation(
                input: input(streamState: state, hasPulse: false),
                now: now)
            XCTAssertNotEqual(presentation.tone, .green,
                              "\(state) without a pulse is not live")
            XCTAssertFalse(AtriaLiveSignalTruth.isLive(
                status: .connected, streamState: state,
                hasRecentHeartRate: false))
        }
    }

    /// Source pin: the Strap screen must not carry a private copy of the rule,
    /// and its detail line must key off the same rule as its label.
    func testStrapScreenUsesTheSharedRuleForLabelAndDetail() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaStrapScreen.swift"),
            encoding: .utf8)
        let uses = source.components(
            separatedBy: "AtriaLiveSignalTruth.freshPulseOverridesLaggingStream").count - 1
        XCTAssertEqual(uses, 2,
                       "both primaryState and connectionDetail must read the "
                           + "shared rule, or the label and the line under it "
                           + "can contradict each other")
    }

    // MARK: - Fixtures

    private let now = Date(timeIntervalSince1970: 1_787_000_000)

    private func input(streamState: AtriaBLEManager.StrapStreamState,
                       hasPulse: Bool) -> AtriaTopStatusProjectionInput {
        AtriaTopStatusProjectionInput(
            status: .connected,
            bluetoothPermissionDenied: false,
            isBluetoothReady: true,
            hasPulseSignal: hasPulse,
            hasRecentHeartRateSample: hasPulse,
            lastReadingAt: hasPulse ? now.addingTimeInterval(-2) : nil,
            displayDeviceName: "Strap",
            strapStreamState: streamState,
            strapStreamConnectionLabel: label(for: streamState),
            strapStreamConnectionSymbol: "bolt.heart.fill",
            lastScanRequestedAt: nil,
            lastScanMatchAt: nil,
            pendingKnownReconnectStartedAt: nil,
            rangeLossBackfillPending: false,
            hasEverConnected: true,
            battery: AtriaHeaderBatterySnapshot(
                // Must agree with the stream state: the same battery level
                // feeds both, so a fixture claiming lowBatteryShutoff at 80%
                // is physically impossible — and the pill (correctly) tints
                // by the level, which read as a false disagreement.
                level: batteryLevel(for: streamState),
                showsPowered: false,
                chargeStatus: .levelOnly,
                isRecentBaseline: true,
                verifiedAt: now,
                chargeVerifiedAt: nil))
    }

    private func batteryLevel(for state: AtriaBLEManager.StrapStreamState) -> Int {
        switch state {
        case .lowBatteryShutoff: return 4        // <= 5 is what produces it
        case .lowBatteryReducedDetail: return 18 // <= 25 is what produces it
        case .live, .warming, .silentUnknown, .unknown: return 80
        }
    }

    private func label(for state: AtriaBLEManager.StrapStreamState) -> String {
        switch state {
        case .live: return "Live"
        case .warming: return "Waiting"
        case .silentUnknown: return "No signal"
        case .unknown: return "Pending"
        case .lowBatteryShutoff: return "Charge strap"
        case .lowBatteryReducedDetail: return "Low battery"
        }
    }
}
