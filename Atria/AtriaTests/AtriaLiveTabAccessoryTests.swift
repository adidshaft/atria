import XCTest
@testable import Atria

final class AtriaLiveTabAccessoryTests: XCTestCase {
    func testWorkoutWithUnavailableHeartRateDoesNotSpeakZeroBPM() {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: 0,
                                                             strain: 6.4)

        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live workout minimized. Tap to return. Heart rate unavailable, strain 6.4.")
        XCTAssertFalse(presentation.accessibilityLabel.contains("0"))
    }

    func testWorkoutWithHeartRateSpeaksBPM() {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: 128,
                                                             strain: 9.1)

        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live workout minimized. Tap to return. Heart rate 128 beats per minute, strain 9.1.")
    }

    func testBottomAccessoryIsReservedForARealMinimizedWorkout() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains("return workoutSession != nil && liveWorkoutMinimized"))
        XCTAssertTrue(source.contains(".tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory)"))
        XCTAssertFalse(source.contains("AtriaLiveStatusTabAccessory"))
    }

    func testUnknownBatteryIsNotDrawnAsZeroPercent() throws {
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                              encoding: .utf8)
        let widget = try String(contentsOf: sourceRoot.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
                                encoding: .utf8)

        XCTAssertTrue(home.contains("guard batteryLevel >= 0 else { return \"questionmark.circle\" }"))
        XCTAssertTrue(widget.contains("guard state.batteryLevel >= 0 else { return \"questionmark.circle\" }"))
        XCTAssertTrue(widget.contains("if context.state.batteryLevel >= 0"))
    }

    func testTopStatusPresentationEqualityExcludesRawPulsePayloads() {
        let presentation = AtriaTopStatusPresentation(label: "Live",
                                                      symbol: "bolt.heart.fill",
                                                      tone: .green,
                                                      isConnected: true)
        XCTAssertEqual(presentation,
                       AtriaTopStatusPresentation(label: "Live",
                                                  symbol: "bolt.heart.fill",
                                                  tone: .green,
                                                  isConnected: true))
        XCTAssertNotEqual(presentation,
                          AtriaTopStatusPresentation(label: "No signal",
                                                     symbol: "heart.slash",
                                                     tone: .orange,
                                                     isConnected: false))
    }

    func testTopStatusPulseTriggerContainsOnlySemanticSignalState() {
        XCTAssertEqual(AtriaTopStatusPulseTrigger(hasPulseSignal: true),
                       AtriaTopStatusPulseTrigger(hasPulseSignal: true))
        XCTAssertNotEqual(AtriaTopStatusPulseTrigger(hasPulseSignal: true),
                          AtriaTopStatusPulseTrigger(hasPulseSignal: false))
    }

    func testFreshPulseCanHealDisconnectedStatusButExpiresHonestly() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let fresh = topStatusInput(status: .disconnected,
                                   hasPulseSignal: true,
                                   lastReadingAt: now.addingTimeInterval(-10),
                                   hasEverConnected: true)
        let stale = topStatusInput(status: .disconnected,
                                   hasPulseSignal: true,
                                   lastReadingAt: now.addingTimeInterval(-16),
                                   hasEverConnected: true)

        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: fresh, now: now),
                       AtriaTopStatusPresentation(label: "Live · Battery pending",
                                                  symbol: "questionmark.circle",
                                                  tone: .cyan,
                                                  isConnected: true))
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: stale, now: now),
                       AtriaTopStatusPresentation(label: "Reconnecting…",
                                                  symbol: "bolt.horizontal.circle",
                                                  tone: .yellow,
                                                  isConnected: false))
    }

    func testFreshPulseOverridesLaggingWarmingProjection() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let input = topStatusInput(status: .connected,
                                   hasRecentHeartRateSample: true,
                                   lastReadingAt: now,
                                   strapStreamState: .warming,
                                   strapStreamConnectionLabel: "Waiting",
                                   strapStreamConnectionSymbol: "waveform.path.ecg",
                                   hasEverConnected: true)

        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: input, now: now),
                       AtriaTopStatusPresentation(label: "Live · Battery pending",
                                                  symbol: "questionmark.circle",
                                                  tone: .cyan,
                                                  isConnected: true))
    }

    func testTopStatusUsesFreshBatteryTruthAndPreservesPendingState() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let normal = topStatusInput(status: .connected,
                                    hasRecentHeartRateSample: true,
                                    lastReadingAt: now,
                                    batteryLevel: 43,
                                    hasEverConnected: true)
        let charging = topStatusInput(status: .connected,
                                      hasRecentHeartRateSample: true,
                                      lastReadingAt: now,
                                      batteryLevel: 43,
                                      batteryShowsPowered: true,
                                      batteryChargeStatus: .charging,
                                      hasEverConnected: true)
        let low = topStatusInput(status: .connected,
                                 hasRecentHeartRateSample: true,
                                 lastReadingAt: now,
                                 batteryLevel: 10,
                                 batteryChargeStatus: .notCharging,
                                 hasEverConnected: true)
        let pending = topStatusInput(status: .connected,
                                     hasRecentHeartRateSample: true,
                                     lastReadingAt: now,
                                     hasEverConnected: true)
        let recent = topStatusInput(status: .connected,
                                    hasRecentHeartRateSample: true,
                                    lastReadingAt: now,
                                    batteryLevel: 30,
                                    batteryReadingIsRecentBaseline: true,
                                    batteryLastVerifiedAt: now.addingTimeInterval(-75 * 60),
                                    hasEverConnected: true)
        let freshCachedLow = topStatusInput(status: .connected,
                                            hasRecentHeartRateSample: true,
                                            lastReadingAt: now,
                                            batteryLevel: 14,
                                            batteryReadingIsRecentBaseline: true,
                                            batteryLastVerifiedAt: now.addingTimeInterval(-30),
                                            hasEverConnected: true)

        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: normal, now: now).label,
                       "43% · Live")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: normal, now: now).symbol,
                       "battery.50percent")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).label,
                       "43% · Charging")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).symbol,
                       "battery.100percent.bolt")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: low, now: now).label,
                       "10% · Low")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: pending, now: now).label,
                       "Live · Battery pending")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: recent, now: now),
                       AtriaTopStatusPresentation(label: "30% · 1h ago",
                                                  symbol: "battery.25percent",
                                                  tone: .cyan,
                                                  isConnected: true))
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: freshCachedLow, now: now),
                       AtriaTopStatusPresentation(label: "14% · Low",
                                                  symbol: "battery.25percent",
                                                  tone: .orange,
                                                  isConnected: true))
    }

    func testBatteryTruthRevisionInvalidatesHomeAndWidgetProjections() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("ble.$batteryProjectionRevision.removeDuplicates().map { _ in () }"))
        XCTAssertTrue(source.contains("ble.$batteryReadingIsRecentBaseline.removeDuplicates().map { _ in () }"))
    }

    func testTopStatusPillOwnsStrapNavigationWithoutRedundantHeaderButton() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let chromeStart = try XCTUnwrap(source.range(of: "private struct AtriaHomeTopChrome: View"))
        let chromeEnd = try XCTUnwrap(source.range(of: "private enum AtriaHeaderControlMetrics",
                                                   range: chromeStart.upperBound..<source.endIndex))
        let chrome = String(source[chromeStart.lowerBound..<chromeEnd.lowerBound])

        XCTAssertTrue(chrome.contains("onTapWhenConnected: onShowStrap"))
        XCTAssertFalse(chrome.contains("Button(action: onShowStrap)"))
    }

    func testNeverConnectedAndPendingReconnectLabelsRemainDistinct() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let neverConnected = topStatusInput(status: .disconnected,
                                            hasEverConnected: false)
        let linking = topStatusInput(status: .disconnected,
                                     pendingKnownReconnectStartedAt: now.addingTimeInterval(-5),
                                     hasEverConnected: true)

        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: neverConnected, now: now),
                       AtriaTopStatusPresentation(label: "Disconnected",
                                                  symbol: "bolt.horizontal.circle",
                                                  tone: .secondary,
                                                  isConnected: false))
        // An active reconnect is represented as recovery first, matching the
        // prior chip's "Reading…" state while its live-signal grace is active.
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: linking, now: now).label,
                       "Reading…")
    }

    func testProjectionSchedulesSemanticExpiryWithoutRenderTimeClockReads() {
        let now = Date(timeIntervalSince1970: 1_800_200_000)
        let input = topStatusInput(status: .disconnected,
                                   hasPulseSignal: true,
                                   lastReadingAt: now.addingTimeInterval(-10),
                                   hasEverConnected: true)

        XCTAssertEqual(AtriaTopStatusProjection.nextSemanticDeadline(input: input, now: now),
                       now.addingTimeInterval(5))
    }

    private func topStatusInput(
        status: AtriaBLEManager.Status,
        bluetoothPermissionDenied: Bool = false,
        isBluetoothReady: Bool = true,
        hasPulseSignal: Bool = false,
        hasRecentHeartRateSample: Bool = false,
        lastReadingAt: Date? = nil,
        displayDeviceName: String = "WHOOP",
        strapStreamState: AtriaBLEManager.StrapStreamState = .live,
        strapStreamConnectionLabel: String = "Live",
        strapStreamConnectionSymbol: String = "bolt.heart.fill",
        lastScanRequestedAt: Date? = nil,
        lastScanMatchAt: Date? = nil,
        pendingKnownReconnectStartedAt: Date? = nil,
        rangeLossBackfillPending: Bool = false,
        batteryLevel: Int = -1,
        batteryShowsPowered: Bool = false,
        batteryChargeStatus: AtriaBLEManager.BatteryChargeStatus = .levelOnly,
        batteryReadingIsRecentBaseline: Bool = false,
        batteryLastVerifiedAt: Date? = nil,
        hasEverConnected: Bool
    ) -> AtriaTopStatusProjectionInput {
        AtriaTopStatusProjectionInput(status: status,
                                      bluetoothPermissionDenied: bluetoothPermissionDenied,
                                      isBluetoothReady: isBluetoothReady,
                                      hasPulseSignal: hasPulseSignal,
                                      hasRecentHeartRateSample: hasRecentHeartRateSample,
                                      lastReadingAt: lastReadingAt,
                                      displayDeviceName: displayDeviceName,
                                      strapStreamState: strapStreamState,
                                      strapStreamConnectionLabel: strapStreamConnectionLabel,
                                      strapStreamConnectionSymbol: strapStreamConnectionSymbol,
                                      lastScanRequestedAt: lastScanRequestedAt,
                                      lastScanMatchAt: lastScanMatchAt,
                                      pendingKnownReconnectStartedAt: pendingKnownReconnectStartedAt,
                                      rangeLossBackfillPending: rangeLossBackfillPending,
                                      hasEverConnected: hasEverConnected,
                                      batteryLevel: batteryLevel,
                                      batteryShowsPowered: batteryShowsPowered,
                                      batteryChargeStatus: batteryChargeStatus,
                                      batteryReadingIsRecentBaseline: batteryReadingIsRecentBaseline,
                                      batteryLastVerifiedAt: batteryLastVerifiedAt)
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
