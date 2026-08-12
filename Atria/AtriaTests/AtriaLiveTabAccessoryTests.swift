import XCTest
import SwiftUI
@testable import Atria

final class AtriaLiveTabAccessoryTests: XCTestCase {
    func testWorkoutWithUnavailableHeartRateDoesNotSpeakZeroBPM() {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: 0,
                                                             strainText: "6.4")

        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live workout minimized. Tap to return. Heart rate unavailable, workout strain 6.4.")
        XCTAssertFalse(presentation.accessibilityLabel.contains("0"))
    }

    func testWorkoutWithHeartRateSpeaksBPM() {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: 128,
                                                             strainText: "9.1")

        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live workout minimized. Tap to return. Heart rate 128 beats per minute, workout strain 9.1.")
    }

    func testWorkoutWithoutStrainEvidenceSpeaksHonestPlaceholder() {
        let presentation = AtriaLiveTabAccessoryPresentation(heartRate: 92,
                                                             strainText: "--")

        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live workout minimized. Tap to return. Heart rate 92 beats per minute, workout strain not yet available.")
    }

    // 2026-08-13 physical report: the minimized-workout pill rendered the DAY
    // strain (3.2) beside the workout timer while the workout screen said
    // 1.5. The pill must carry the workout projection, never the hero ring's
    // day total.
    func testMinimizedWorkoutPillCarriesWorkoutStrainNotDayStrain() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let hostStart = try XCTUnwrap(source.range(
            of: "private struct AtriaLiveTabAccessoryHost: View {"
        )?.lowerBound)
        let hostEnd = try XCTUnwrap(source.range(
            of: "private struct AtriaLiveTabAccessory: View {",
            range: hostStart..<source.endIndex
        )?.lowerBound)
        let host = String(source[hostStart..<hostEnd])
        XCTAssertTrue(host.contains("metricStore.state.strainHUDText"),
                      "the pill must render the workout projection's strain")
        XCTAssertFalse(host.contains("heroStore"),
                       "the pill must not read the hero ring's day strain")
    }

    func testBottomAccessoryIsReservedForARealMinimizedWorkout() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains("return workoutSession != nil && liveWorkoutMinimized"))
        XCTAssertTrue(source.contains(".tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory)"))
        XCTAssertFalse(source.contains("AtriaLiveStatusTabAccessory"))
    }

    func testNativeGlassTabBarHasNoOpaqueOrEmptyBottomShelf() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains(".toolbarBackground(.hidden, for: .tabBar)"))
        XCTAssertFalse(source.contains("scrollBottomSafeAreaInset"))
        XCTAssertFalse(source.contains(".safeAreaInset(edge: .bottom, spacing: 0)"),
                       "the native tab bar already owns its safe area; an extra clear inset becomes a black shelf")
    }

    func testHomeTabBarUsesNativeScrollDrivenSingleButtonTreatment() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let tabView = try XCTUnwrap(source.range(of: "TabView(selection: $selectedTab)"))
        let observers = try XCTUnwrap(source.range(of: "AtriaHomeObservers(",
                                                    range: tabView.upperBound..<source.endIndex))
        let shell = String(source[tabView.lowerBound..<observers.lowerBound])

        XCTAssertTrue(shell.contains(".tabBarMinimizeBehavior(.onScrollDown)"),
                      "an upward content swipe should return the native selected-tab-only glass treatment")
        XCTAssertEqual(shell.components(separatedBy: ".tabBarMinimizeBehavior(").count - 1, 1,
                       "the tab shell should have one scroll-minimization policy")
        XCTAssertFalse(shell.contains("DragGesture"),
                       "the native ScrollView/tab-bar relationship must remain the single gesture authority")
    }

    func testScrollMinimizationKeepsExpandedDestinationsAndAccessoryAdaptive() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let tabView = try XCTUnwrap(source.range(of: "TabView(selection: $selectedTab)"))
        let observers = try XCTUnwrap(source.range(of: "AtriaHomeObservers(",
                                                    range: tabView.upperBound..<source.endIndex))
        let shell = String(source[tabView.lowerBound..<observers.lowerBound])

        for destination in ["overview", "vitals", "journal", "plan"] {
            XCTAssertTrue(shell.contains("Tab(HomeTab.\(destination).title"),
                          "the native tab shell must declare the \(destination) destination with modern Tab")
            XCTAssertTrue(shell.contains("systemImage: HomeTab.\(destination).systemImage"),
                          "the modern \(destination) tab must preserve its system image")
            XCTAssertTrue(shell.contains("value: HomeTab.\(destination)"),
                          "the modern \(destination) tab must preserve its selection value")
        }
        XCTAssertEqual(shell.components(separatedBy: "value: HomeTab.").count - 1, 4,
                       "the native shell must contain exactly four modern tab values")
        XCTAssertFalse(shell.contains(".tabItem"),
                       "legacy tab-item bridging must not own the iOS 26 minimization path")
        XCTAssertFalse(shell.contains(".tag(HomeTab."),
                       "modern Tab values replace legacy tag-based selection")
        XCTAssertTrue(shell.contains(".tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory)"))
        XCTAssertTrue(source.contains("placement == .inline"),
                      "the minimized workout control must continue adapting to the native compact placement")

        let background = try XCTUnwrap(shell.range(of: ".toolbarBackground(.hidden, for: .tabBar)"))
        let minimize = try XCTUnwrap(shell.range(of: ".tabBarMinimizeBehavior(.onScrollDown)"))
        let accessory = try XCTUnwrap(shell.range(of: ".tabViewBottomAccessory(isEnabled: shouldShowLiveAccessory)"))
        XCTAssertLessThan(background.lowerBound, minimize.lowerBound)
        XCTAssertLessThan(minimize.lowerBound, accessory.lowerBound)
    }

    func testHomeChromeDefersWorkoutStatusToActivityKitAndStacksForLargeType() {
        XCTAssertTrue(AtriaHomeChromeLayout.showsHomeStatusChip(workoutIsActive: false))
        XCTAssertFalse(AtriaHomeChromeLayout.showsHomeStatusChip(workoutIsActive: true))
        XCTAssertFalse(AtriaHomeChromeLayout.stacksStatusAndActions(dynamicTypeSize: .large,
                                                                   workoutIsActive: false))
        XCTAssertTrue(AtriaHomeChromeLayout.stacksStatusAndActions(dynamicTypeSize: .accessibility1,
                                                                  workoutIsActive: false))
        XCTAssertFalse(AtriaHomeChromeLayout.stacksStatusAndActions(dynamicTypeSize: .accessibility1,
                                                                   workoutIsActive: true))
    }

    func testPinnedHomeMetricsRespectSafeAreaAndDoNotDuplicateAnActiveWorkout() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains(".safeAreaInset(edge: .top, spacing: 0)"))
        XCTAssertTrue(source.contains(".safeAreaPadding(.top, 8)"),
                      "Pinned metrics must consume scene safe-area geometry instead of using a cutout-blind offset")
        XCTAssertTrue(source.contains("!prefersLiveActivityStatus"))
        XCTAssertTrue(source.contains("prefersLiveActivityStatus: workoutSession != nil"))
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize) private var dynamicTypeSize"))
    }

    func testDynamicIslandUsesStateDrivenNativeTransitionsWithReduceMotionFallback() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityValueTransition"))
        let end = try XCTUnwrap(source.range(of: "private func liveActivityBatteryAvailability",
                                             range: start.upperBound..<source.endIndex))
        let island = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertTrue(island.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
        XCTAssertTrue(island.contains("if reduceMotion"))
        XCTAssertTrue(island.contains(".contentTransition(.numericText())"))
        XCTAssertTrue(island.contains(".animation(.snappy(duration: 0.22), value: value)"))
        XCTAssertTrue(island.contains(".atriaLiveActivityValueTransition(isLive ? heartRate : -1)"))
        XCTAssertTrue(island.contains(".symbolEffect(.bounce, options: .nonRepeating, value: isPaused)"))
        XCTAssertTrue(island.contains("AtriaDynamicIslandCompactHeartRate"))
        XCTAssertFalse(island.contains("Timer."))
        XCTAssertFalse(island.contains("Task.sleep"))
    }

    func testUnknownBatteryIsNotDrawnAsZeroPercent() throws {
        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                              encoding: .utf8)
        let widget = try String(contentsOf: sourceRoot.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
                                encoding: .utf8)

        XCTAssertTrue(home.contains("guard batteryLevel >= 0 else { return \"questionmark.circle\" }"))
        XCTAssertTrue(widget.contains("guard state.batteryLevel >= 0 else { return \"questionmark.circle\" }"))
        XCTAssertTrue(widget.contains("if showsBattery, batteryAvailability == .live"),
                      "Live Activity must render battery only after the freshness helper validates a nonnegative level")
    }

    func testConnectivityPillUsesBatteryPacketAgeWhenShowingPercentage() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(
            AtriaHomeModel.CoreLiveState.connectivityFreshnessText(
                batteryLevel: 81,
                batteryVerifiedAt: now.addingTimeInterval(-(32 * 60)),
                heartRateReadingAt: now,
                now: now
            ),
            "32m ago",
            "fresh HR must not relabel a 32-minute-old battery packet as just updated"
        )
        XCTAssertEqual(
            AtriaHomeModel.CoreLiveState.connectivityFreshnessText(
                batteryLevel: -1,
                batteryVerifiedAt: nil,
                heartRateReadingAt: now.addingTimeInterval(-1),
                now: now
            ),
            "just now"
        )
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

        // 2026-08-08: an unconfirmed percentage no longer shouts "Battery
        // pending ?" on a healthy live strap (change-driven 2A19 means a
        // stable level legitimately ages out). The pill states collection
        // state; the percentage lives in Strap/Battery detail.
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: fresh, now: now),
                       AtriaTopStatusPresentation(label: "Live",
                                                  symbol: "bolt.heart.fill",
                                                  tone: .cyan,
                                                  isConnected: true,
                                                  accessibilityLabel: "Live strap, battery percentage not yet confirmed"))
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
                       AtriaTopStatusPresentation(label: "Live",
                                                  symbol: "bolt.heart.fill",
                                                  tone: .cyan,
                                                  isConnected: true,
                                                  accessibilityLabel: "Live strap, battery percentage not yet confirmed"))
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
                                      batteryChargeLastVerifiedAt: now,
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
                       "43%")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: normal, now: now).tone,
                       .green)
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: normal, now: now).accessibilityLabel,
                       "Live strap, 43%, charger status unavailable")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: normal, now: now).symbol,
                       "battery.50percent")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).label,
                       "43%")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).symbol,
                       "battery.50percent")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).accessorySymbol,
                       "bolt.fill")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: charging, now: now).accessibilityLabel,
                       "Live strap, 43%, Charging")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: low, now: now).label,
                       "10% · Low")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: pending, now: now).label,
                       "Live")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: recent, now: now),
                       AtriaTopStatusPresentation(label: "30%",
                                                  symbol: "battery.25percent",
                                                  tone: .green,
                                                  isConnected: true,
                                                  accessibilityLabel: "Live strap, 30%, charger status unavailable"))
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: freshCachedLow, now: now),
                       AtriaTopStatusPresentation(label: "14% · Low",
                                                  symbol: "battery.25percent",
                                                  tone: .orange,
                                                  isConnected: true,
                                                  accessibilityLabel: "Live strap, 14%, charger status unavailable"))
    }

    func testPersistedChargerEventCannotRestoreChargingAfterLiveStateIsUnknown() {
        let now = Date()
        let projection = AtriaHomeModel.resolvedBatteryChargeProjection(
            liveStatus: .levelOnly,
            liveIsCharging: false,
            batteryRecentlyDropping: false,
            persistedStatus: .charging,
            persistedAge: 90
        )
        let input = topStatusInput(status: .connected,
                                   hasRecentHeartRateSample: true,
                                   lastReadingAt: Date(),
                                   batteryLevel: 17,
                                   batteryShowsPowered: projection.isCharging,
                                   batteryChargeStatus: projection.status,
                                   batteryChargeLastVerifiedAt: now,
                                   hasEverConnected: true)

        XCTAssertEqual(projection,
                       AtriaHomeModel.BatteryChargeProjection(status: .levelOnly,
                                                              isCharging: false))
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: input, now: now).label,
                       "17% · Low")
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: input, now: now).symbol,
                       "battery.25percent")
        XCTAssertNil(AtriaTopStatusProjection.presentation(input: input, now: now).accessorySymbol)
        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: input, now: now).accessibilityLabel,
                       "Live strap, 17%, charger status unavailable")
    }

    func testRestoredChargingBoltExpiresWithoutAnotherCoreEvent() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let chargeVerifiedAt = now.addingTimeInterval(
            -(AtriaHomeModel.freshChargerEvidenceInterval - 5)
        )
        let input = topStatusInput(
            status: .connected,
            hasRecentHeartRateSample: false,
            batteryLevel: 17,
            batteryShowsPowered: true,
            batteryChargeStatus: .charging,
            batteryLastVerifiedAt: now.addingTimeInterval(-30 * 60),
            batteryChargeLastVerifiedAt: chargeVerifiedAt,
            hasEverConnected: true
        )

        XCTAssertEqual(AtriaTopStatusProjection.presentation(input: input, now: now).accessorySymbol,
                       "bolt.fill")
        XCTAssertEqual(AtriaTopStatusProjection.nextSemanticDeadline(input: input, now: now),
                       chargeVerifiedAt.addingTimeInterval(AtriaHomeModel.freshChargerEvidenceInterval))

        let expired = now.addingTimeInterval(6)
        let presentation = AtriaTopStatusProjection.presentation(input: input, now: expired)
        XCTAssertNil(presentation.accessorySymbol)
        XCTAssertEqual(presentation.label, "17% · Low")
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live strap, 17%, charger status unavailable")
    }

    func testChargerRemovedWithoutFollowUpPacketCannotShowChargingAtTwoMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let input = topStatusInput(
            status: .connected,
            hasRecentHeartRateSample: true,
            lastReadingAt: now,
            batteryLevel: 35,
            batteryShowsPowered: true,
            batteryChargeStatus: .charging,
            batteryChargeLastVerifiedAt: now.addingTimeInterval(-120),
            hasEverConnected: true
        )

        let presentation = AtriaTopStatusProjection.presentation(input: input, now: now)
        XCTAssertNil(presentation.accessorySymbol)
        XCTAssertEqual(presentation.label, "35%")
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live strap, 35%, charger status unavailable")
    }

    func testFullBatteryDoesNotInventExternalPower() {
        let input = topStatusInput(status: .connected,
                                   hasRecentHeartRateSample: true,
                                   lastReadingAt: Date(),
                                   batteryLevel: 100,
                                   batteryChargeStatus: .full,
                                   hasEverConnected: true)
        let presentation = AtriaTopStatusProjection.presentation(input: input, now: Date())

        XCTAssertEqual(presentation.label, "100% · Full")
        XCTAssertEqual(presentation.symbol, "battery.100percent")
        XCTAssertNil(presentation.accessorySymbol)
        XCTAssertEqual(presentation.accessibilityLabel, "Live strap, 100%, Full")
    }

    func testHeaderBatterySnapshotFailsClosedOnContradictoryChargingFields() {
        let snapshot = AtriaHeaderBatterySnapshot(
            level: 43,
            showsPowered: false,
            chargeStatus: .charging,
            isRecentBaseline: false,
            verifiedAt: Date()
        )

        XCTAssertEqual(snapshot.level, 43)
        XCTAssertEqual(snapshot.powerState, .unknown)

        let input = topStatusInput(status: .connected,
                                   hasRecentHeartRateSample: true,
                                   lastReadingAt: Date(),
                                   batteryLevel: 43,
                                   batteryShowsPowered: false,
                                   batteryChargeStatus: .charging,
                                   hasEverConnected: true)
        let presentation = AtriaTopStatusProjection.presentation(input: input, now: Date())
        XCTAssertEqual(presentation.label, "43%")
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live strap, 43%, charger status unavailable")
        XCTAssertNil(presentation.accessorySymbol)
    }

    func testHeaderBatterySnapshotDropsStatusAndTimestampWhenLevelIsUnavailable() {
        let snapshot = AtriaHeaderBatterySnapshot(
            level: -1,
            showsPowered: true,
            chargeStatus: .charging,
            isRecentBaseline: true,
            verifiedAt: Date()
        )

        XCTAssertNil(snapshot.level)
        XCTAssertEqual(snapshot.powerState, .none)
        XCTAssertFalse(snapshot.isRecentBaseline)
        XCTAssertNil(snapshot.verifiedAt)
    }

    func testPullToRefreshFeedbackDoesNotDuplicateBatterySnapshot() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private var connectivityPillText"))
        let end = try XCTUnwrap(source.range(of: "private func handleConnectivityRefresh",
                                              range: start.upperBound..<source.endIndex))
        let feedback = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(feedback.contains("batteryText"))
        XCTAssertFalse(feedback.contains("batteryLevel"))
        XCTAssertFalse(feedback.contains("connectivityFreshnessText"))
        XCTAssertTrue(feedback.contains("Refreshing strap…"))
    }

    func testAtAGlanceStatusDefersBatteryToTheHeader() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaTodayScreen.swift"),
                                encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct AtriaTodayLiveStatusStrip"))
        let end = try XCTUnwrap(source.range(of: "private struct AtriaTodayLivePill",
                                             range: start.upperBound..<source.endIndex))
        let strip = String(source[start.lowerBound..<end.lowerBound])

        XCTAssertFalse(strip.contains("Battery"),
                       "The top-left connection pill is the single battery source on Today.")

        let home = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(home.contains("if batteryShowsPowered || batteryChargeStatus == .full"))
        XCTAssertTrue(home.contains("return \"battery.100percent.bolt\""))
    }

    func testStaleChargerEventCannotClaimCharging() {
        let projection = AtriaHomeModel.resolvedBatteryChargeProjection(
            liveStatus: .levelOnly,
            liveIsCharging: false,
            batteryRecentlyDropping: false,
            persistedStatus: .charging,
            persistedAge: AtriaHomeModel.freshChargerEvidenceInterval + 1
        )

        XCTAssertEqual(projection,
                       AtriaHomeModel.BatteryChargeProjection(status: .levelOnly,
                                                              isCharging: false))
    }

    func testRepeatedSameStateChargerEventRenewsTheHeaderEvidenceClock() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let projection = AtriaHomeModel.BatteryChargeProjection(status: .charging,
                                                                isCharging: true)
        let repeatedLiveEvent = now.addingTimeInterval(-2)

        XCTAssertEqual(
            AtriaHomeModel.resolvedBatteryChargeVerifiedAt(
                projection: projection,
                liveVerifiedAt: repeatedLiveEvent,
                persistedStatus: .charging,
                persistedAge: AtriaHomeModel.freshChargerEvidenceInterval - 1,
                now: now
            ),
            repeatedLiveEvent,
            "the latest autonomous charger event must renew the pill even when the enum stays charging"
        )
    }

    func testChargingPresentationFailsClosedWhenEveryEvidenceClockIsStale() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let projection = AtriaHomeModel.BatteryChargeProjection(status: .charging,
                                                                isCharging: true)

        XCTAssertNil(AtriaHomeModel.resolvedBatteryChargeVerifiedAt(
            projection: projection,
            liveVerifiedAt: now.addingTimeInterval(
                -(AtriaHomeModel.freshChargerEvidenceInterval + 1)
            ),
            persistedStatus: .charging,
            persistedAge: AtriaHomeModel.freshChargerEvidenceInterval + 1,
            now: now
        ))

        let input = topStatusInput(
            status: .connected,
            hasRecentHeartRateSample: true,
            lastReadingAt: now,
            batteryLevel: 43,
            batteryShowsPowered: true,
            batteryChargeStatus: .charging,
            batteryChargeLastVerifiedAt: nil,
            hasEverConnected: true
        )
        let presentation = AtriaTopStatusProjection.presentation(input: input, now: now)
        XCTAssertEqual(presentation.label, "43%")
        XCTAssertNil(presentation.accessorySymbol)
        XCTAssertEqual(presentation.accessibilityLabel,
                       "Live strap, 43%, charger status unavailable")
    }

    @MainActor
    func testPostUnplugPercentageTrajectoryCannotAuthorizePersistedCharging() throws {
        let suiteName = "AtriaLiveTabAccessoryTests.charge-source.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        defaults.set(35, forKey: "atria.battery.level")
        defaults.set(now.timeIntervalSince1970, forKey: "atria.battery.at")
        defaults.set("live_2A19", forKey: "atria.battery.source")
        defaults.set(AtriaBLEManager.BatteryChargeStatus.charging.rawValue,
                     forKey: "atria.battery.chargeStatus")
        defaults.set(now.timeIntervalSince1970, forKey: "atria.battery.chargeAt")
        defaults.set("live_2A19_charge_trajectory",
                     forKey: "atria.battery.chargeSource")

        let cached = AtriaBLEManager.cachedBattery(defaults: defaults, now: now)
        XCTAssertTrue(cached.usable)
        XCTAssertEqual(cached.level, 35)
        XCTAssertEqual(cached.chargeStatus, .levelOnly,
                       "continued SOC rise after unplug is level evidence only")
        XCTAssertFalse(AtriaBLEManager.batteryChargeSourceCanAuthorizeCharging(
            "live_2A19_charge_trajectory"
        ))
        XCTAssertFalse(AtriaBLEManager.batteryChargeSourceCanAuthorizeCharging(
            "live_battery_event"
        ))
        XCTAssertFalse(AtriaBLEManager.batteryChargeSourceCanAuthorizeCharging(
            "live_2A1B"
        ))
        XCTAssertEqual(AtriaBLEManager.acceptedBatteryEventChargeStatus(
            reportedIsCharging: true,
            batteryLevel: 41
        ), .levelOnly)
    }

    func testPercentageOnlyEvidenceCannotOriginateCharging() {
        let projection = AtriaHomeModel.resolvedBatteryChargeProjection(
            liveStatus: .levelOnly,
            liveIsCharging: false,
            batteryRecentlyDropping: false,
            persistedStatus: .levelOnly,
            persistedAge: 0
        )

        XCTAssertFalse(projection.isCharging)
        XCTAssertEqual(projection.status, .levelOnly)
    }

    func testLiveNotChargingEvidenceOutranksPersistedChargerEvent() {
        let projection = AtriaHomeModel.resolvedBatteryChargeProjection(
            liveStatus: .notCharging,
            liveIsCharging: false,
            batteryRecentlyDropping: false,
            persistedStatus: .charging,
            persistedAge: 5
        )

        XCTAssertEqual(projection,
                       AtriaHomeModel.BatteryChargeProjection(status: .notCharging,
                                                              isCharging: false))
    }

    func testFallingBatteryRevokesFreshChargerEvent() {
        let projection = AtriaHomeModel.resolvedBatteryChargeProjection(
            liveStatus: .charging,
            liveIsCharging: true,
            batteryRecentlyDropping: true,
            persistedStatus: .charging,
            persistedAge: 5
        )

        XCTAssertEqual(projection,
                       AtriaHomeModel.BatteryChargeProjection(status: .levelOnly,
                                                              isCharging: false))
    }

    func testBatteryTruthRevisionInvalidatesHomeAndWidgetProjections() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        XCTAssertTrue(source.contains("ble.$batteryProjectionRevision.removeDuplicates().map { _ in () }"))
        XCTAssertTrue(source.contains("ble.$batteryReadingIsRecentBaseline.removeDuplicates().map { _ in () }"))
        XCTAssertTrue(source.contains("ble.$batteryChargeLastVerifiedAt.removeDuplicates().map { _ in () }"),
                      "same-state charge events must invalidate the header and widget projections")

        let manager = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaBLEManager.swift"),
                                 encoding: .utf8)
        XCTAssertTrue(manager.contains("@Published private(set) var batteryChargeLastVerifiedAt: Date?"))
        XCTAssertTrue(manager.contains("assignIfChanged(\\.batteryChargeLastVerifiedAt, observedAt)"),
                      "every accepted charger event must publish its own evidence time")
        XCTAssertTrue(manager.contains("source: \"live_2A19_charge_trajectory\""),
                      "only the bounded live trajectory proof may persist the short charging lease")
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

    func testTopChromeGlassPlusOffersExactlyStartAndAddActivity() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)
        let chromeStart = try XCTUnwrap(source.range(of: "private struct AtriaHomeTopChrome: View"))
        let chromeEnd = try XCTUnwrap(source.range(of: "private enum AtriaHeaderControlMetrics",
                                                   range: chromeStart.upperBound..<source.endIndex))
        let chrome = String(source[chromeStart.lowerBound..<chromeEnd.lowerBound])
        let actionsStart = try XCTUnwrap(chrome.range(of: "private var actionButtons: some View"))
        let menuStart = try XCTUnwrap(chrome.range(of: "Menu {", range: actionsStart.upperBound..<chrome.endIndex))
        let menuEnd = try XCTUnwrap(chrome.range(of: "} label: {", range: menuStart.upperBound..<chrome.endIndex))
        let menuActions = String(chrome[menuStart.lowerBound..<menuEnd.lowerBound])

        XCTAssertEqual(menuActions.components(separatedBy: "Button(action:").count - 1, 2)
        XCTAssertTrue(menuActions.contains("Button(action: onStartActivity)"))
        XCTAssertTrue(menuActions.contains("Label(\"Start Activity\", systemImage: \"figure.run\")"))
        XCTAssertTrue(menuActions.contains("Button(action: onAddActivity)"))
        XCTAssertTrue(menuActions.contains("Label(\"Add Activity\", systemImage: \"calendar.badge.plus\")"))
        XCTAssertTrue(chrome.contains("AtriaToolbarIcon(symbol: \"plus\")"))
        XCTAssertTrue(chrome.contains(".buttonStyle(AtriaHeaderActionButtonStyle())"))
        XCTAssertTrue(chrome.contains(".accessibilityLabel(\"Activity shortcuts\")"))
        XCTAssertTrue(chrome.contains(".accessibilityHint(\"Start a live activity or add a past activity.\")"))
        XCTAssertFalse(chrome.contains("bubble.left.and.bubble.right.fill"))
        XCTAssertFalse(chrome.contains("onShowAssistant"))
        XCTAssertTrue(source.contains("static let height: CGFloat = 44"),
                      "the glass plus must keep the existing HIG-sized header target")
    }

    func testTopChromeActivityShortcutReusesExistingStartAndManualAddFlows() throws {
        let source = try String(contentsOf: sourceRoot.appendingPathComponent("Atria/AtriaHomeView.swift"),
                                encoding: .utf8)

        XCTAssertTrue(source.contains("@State private var showWorkoutStartSheet = false"))
        XCTAssertTrue(source.contains("@State private var showAddActivitySheet = false"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $showWorkoutStartSheet)"))
        XCTAssertTrue(source.contains("AtriaWorkoutStartSheet(initial: AtriaWorkoutStartConfiguration("))
        XCTAssertTrue(source.contains(".sheet(isPresented: $showAddActivitySheet)"))
        XCTAssertTrue(source.contains("AtriaAddWorkoutSheet(store: store)"))
        XCTAssertTrue(source.contains(
            "onStartActivity: {\n                               guard workoutSession == nil, !isSecuringWorkoutStart else { return }\n                               showWorkoutStartSheet = true"
        ))
        XCTAssertTrue(source.contains(
            "onAddActivity: {\n                               showAddActivitySheet = true"
        ))
        XCTAssertTrue(source.contains(
            "onStartWorkout: {\n                                 showWorkoutStartSheet = true"
        ), "the existing in-page Today shortcut must remain intact")
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
        batteryChargeLastVerifiedAt: Date? = nil,
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
                                      battery: AtriaHeaderBatterySnapshot(
                                        level: batteryLevel,
                                        showsPowered: batteryShowsPowered,
                                        chargeStatus: batteryChargeStatus,
                                        isRecentBaseline: batteryReadingIsRecentBaseline,
                                        verifiedAt: batteryLastVerifiedAt,
                                        chargeVerifiedAt: batteryChargeLastVerifiedAt
                                      ))
    }

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 2026-08-08: a provisional recovery (RHR-only, 41%) rendered in the
    /// separate ring layout exactly like a validated one (67%), so the number
    /// visibly "jumped" as better evidence landed with nothing on screen
    /// saying the first value was an upgrading estimate.
    func testSeparateRingLayoutMarksProvisionalMetricsAndStaysQuietWhenSettled() {
        func marker(_ detail: String) -> String? {
            AtriaTriRing.confidenceMarker(for: AtriaTriRingMetric(
                title: "Recovery",
                value: "41%",
                detail: detail,
                systemImage: "heart.fill",
                tint: .green,
                fill: 0.41))
        }
        XCTAssertEqual(marker("Limited confidence · sleep and HRV unavailable · from resting HR only"),
                       "estimate")
        XCTAssertEqual(marker("Still learning your typical day"), "learning")
        XCTAssertEqual(marker("≥ 9.1 lower bound"), "partial")
        XCTAssertEqual(marker("Needs motion data"), "no data")
        // A settled metric must stay clean — never invent a caveat.
        XCTAssertNil(marker("Flat vs yesterday"))
        XCTAssertNil(marker(""))
    }
}
