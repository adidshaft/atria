import XCTest
@testable import Atria

@MainActor
final class AtriaLiveActivityActionTests: XCTestCase {
    func testDynamicIslandCompactControlsUseIconsWithExplicitAccessibilityLabels() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: widgetSourceURL, encoding: .utf8)
        let controlsStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityControls: View"))
        let controlsEnd = try XCTUnwrap(source.range(of: "struct AtriaStartCaptureControl: ControlWidget",
                                                    range: controlsStart.upperBound..<source.endIndex))
        let controls = String(source[controlsStart.lowerBound..<controlsEnd.lowerBound])

        XCTAssertFalse(controls.contains("if compact"),
                       "every ActivityKit layout should share the same compact icon controls")
        XCTAssertTrue(controls.contains("Image(systemName: (state.isPaused ?? false) ? \"play.fill\" : \"pause.fill\")"))
        XCTAssertTrue(controls.contains("Image(systemName: \"stop.fill\")"))
        XCTAssertEqual(controls.components(separatedBy: ".buttonStyle(.glassProminent)").count - 1, 2,
                       "both essential actions need visible native contrast on the light Activity surface")
        XCTAssertEqual(controls.components(separatedBy: ".frame(width: 44, height: 44)").count - 1, 2,
                       "each styled control—not an inset label—must own exactly one 44pt hit target")
        XCTAssertEqual(controls.components(separatedBy: ".foregroundStyle(.white)").count - 1, 2,
                       "control symbols must not disappear into their tinted glass backgrounds")
        XCTAssertFalse(controls.contains("minHeight: 44"),
                       "button-style insets around a 44pt label make the Live Activity clip vertically")
        XCTAssertFalse(controls.contains(".buttonStyle(.glass)"),
                       "regular glass is effectively invisible on the Lock Screen's light system background")
        XCTAssertFalse(controls.contains(".buttonStyle(.borderedProminent)"))
        XCTAssertTrue(controls.contains(".buttonBorderShape(.circle)"))
        XCTAssertTrue(controls.contains(".accessibilityLabel((state.isPaused ?? false) ? \"Resume workout\" : \"Pause workout\")"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(\"End workout\")"))
        XCTAssertTrue(controls.contains("Resumes workout time and route tracking"))
        XCTAssertTrue(controls.contains("Pauses workout time and route tracking"))
        XCTAssertTrue(controls.contains("Ends the active workout"))
    }

    func testLiveActivityMetricsStaySingleLineWithThreeDigitHeartRate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        let islandStart = try XCTUnwrap(source.range(of: "struct AtriaLiveActivityWidget: Widget"))
        let lockScreenStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityLockScreenView"))
        let compactHeartStart = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandCompactHeartRate"))
        let compactHeartEnd = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandActivityGlyph",
                                                        range: compactHeartStart.upperBound..<source.endIndex))
        let island = String(source[islandStart.lowerBound..<lockScreenStart.lowerBound])
        let compactHeart = String(source[compactHeartStart.lowerBound..<compactHeartEnd.lowerBound])
        let lockScreen = String(source[lockScreenStart.lowerBound...])

        XCTAssertTrue(island.contains("expandedMetricRail(showsSupportingFacts: true)"))
        XCTAssertTrue(island.contains("expandedMetricRail(showsSupportingFacts: false)"),
                      "the action and BPM hero need a terminal narrow-width rail")
        XCTAssertTrue(island.contains("Text(signalFresh ? \"\\(state.heartRate)\" : \"--\")"))
        XCTAssertTrue(island.contains("size: 27"))
        XCTAssertTrue(island.contains("Text(\"BPM\")"),
                      "the unit must stay attached to the dominant heart-rate value")
        XCTAssertTrue(island.contains(".lineLimit(1)"))
        XCTAssertTrue(island.contains(".minimumScaleFactor(0.82)"))
        XCTAssertTrue(island.contains(".allowsTightening(true)"))
        XCTAssertTrue(island.contains("AtriaDynamicIslandCompactHeartRate(heartRate: context.state.heartRate"))
        XCTAssertTrue(compactHeart.contains("Text(isLive ? \"\\(heartRate)\" : \"--\")"),
                      "the compact island must show the live numeric HR without an overflowing suffix")
        XCTAssertTrue(compactHeart.contains("size: 15"))
        XCTAssertTrue(compactHeart.contains(".lineLimit(1)"))
        XCTAssertTrue(compactHeart.contains(".minimumScaleFactor(0.82)"))
        XCTAssertTrue(compactHeart.contains("Heart rate \\(heartRate) beats per minute"))

        XCTAssertTrue(lockScreen.contains("size: 29"),
                      "the Lock Screen heart-rate hero must fit a three-digit value inline with BPM")
        XCTAssertTrue(lockScreen.contains("Text(\"T \\(target)\")"),
                      "the current and target zones must remain attached in one compact group")
        XCTAssertEqual(lockScreen.components(separatedBy: ".frame(width: 74, alignment: .trailing)").count - 1, 2,
                       "live timers must be bounded in regular and terminal layouts so they cannot consume HR")
        XCTAssertFalse(lockScreen.contains(".frame(minWidth: 70, alignment: .trailing)"),
                       "a timer minimum still allows the live style to expand across the primary row")
        XCTAssertEqual(lockScreen.components(separatedBy: ".frame(width: 112, alignment: .leading)").count - 1, 2,
                       "the primary and terminal layouts must reserve enough width for a three-digit HR value")
        XCTAssertFalse(lockScreen.contains("Text(\"Duration\")"))
        XCTAssertFalse(lockScreen.contains("private func lockScreenMetric"))
        XCTAssertEqual(lockScreen.components(separatedBy: ".frame(width: 96, height: 44)").count - 1, 2,
                       "both Lock Screen variants must reserve visible action geometry")
        XCTAssertTrue(lockScreen.contains("lockScreenHeartRateHero"))
        XCTAssertTrue(lockScreen.contains("lockScreenZoneSummary"))
        XCTAssertTrue(lockScreen.contains(".lineLimit(1)"))
        XCTAssertTrue(lockScreen.contains("ViewThatFits(in: .vertical)"),
                      "regular widths must also have a terminal two-row height fallback")
    }

    func testLiveActivityExposesTruthfulBatteryAndSensorStatus() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("Label(\"\\(context.state.batteryLevel)%\""),
                      "the Lock Screen must show the strap percentage instead of hiding the title")
        XCTAssertTrue(source.contains("\"\\(state.batteryLevel)% · Charging\""))
        XCTAssertTrue(source.contains("\"\\(state.batteryLevel)% · Low\""))
        XCTAssertTrue(source.contains("state.batteryLevel <= 20 ? .red : .secondary"))
        XCTAssertTrue(source.contains("liveActivitySourceFreshnessText("),
                      "the truth helper must retain exact last-seen sensor evidence for diagnostics")
        XCTAssertTrue(source.contains("guard heartRateAvailability == .live else { return \"Heart rate zone unavailable\" }"),
                      "nonnominal sensor states must not be repeated as a fake zone value")
        XCTAssertTrue(source.contains(".accessibilityLabel(\"\\(context.state.activityName ?? \"Workout\") workout\")"),
                      "compact and minimal island presentations need a meaningful activity label")
        XCTAssertTrue(source.contains(".accessibilityLabel(lockScreenStatusAccessibilityLabel(showsBattery: showsBattery))"),
                      "the combined Lock Screen status element must preserve any visible battery evidence")
        XCTAssertTrue(source.contains("guard showsBattery, batteryAvailability == .live else"))
        XCTAssertTrue(source.contains("liveActivityBatteryText(for: context.state,"),
                      "a live battery value and state must be spoken when the header displays it")
    }

    func testLiveActivityAccessibilityIncludesTruthfulElapsedDuration() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertFalse(source.contains(".accessibilityLabel(\"Workout duration\")"),
                       "a label without the elapsed value discards the timer's useful VoiceOver semantics")
        XCTAssertEqual(source.components(separatedBy: ".accessibilityLabel(liveActivityDurationAccessibilityText(").count - 1, 3,
                       "expanded, regular Lock Screen, and terminal Lock Screen timers must speak elapsed time")
        XCTAssertTrue(source.contains("let isFrozen = (state.isPaused ?? false) || (state.isEnding ?? false)"),
                      "paused and ending states must freeze at their authoritative elapsed duration")
        XCTAssertTrue(source.contains("if isFrozen, let elapsedDuration = state.elapsedDuration"))
        XCTAssertTrue(source.contains("let anchor = state.timerAnchor ?? startedAt"),
                      "a live timer must use the same pause-adjusted anchor as its visible timer")
        XCTAssertTrue(source.contains("let endpoint = isFrozen ? state.updatedAt : now"))
        XCTAssertTrue(source.contains("return \"Workout duration \\(hours)"),
                      "VoiceOver output must include human-readable hours, minutes, and seconds")
        XCTAssertTrue(source.contains("let duration = liveActivityDurationAccessibilityText("),
                      "the grouped Lock Screen hero must not hide the timer's elapsed value")
        XCTAssertTrue(source.contains("return \"\\(heart). \\(zoneAccessibilityLabel). \\(duration).\""))
    }

    func testLiveActivityFullChargeStatusExpiresOnItsIndependentClock() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let chargeStart = try XCTUnwrap(source.range(of: "private func liveActivityChargeStatusIsFresh"))
        let chargeEnd = try XCTUnwrap(source.range(of: "private func liveActivityHeartRateAvailability",
                                                  range: chargeStart.upperBound..<source.endIndex))
        let chargePresentation = String(source[chargeStart.lowerBound..<chargeEnd.lowerBound])

        XCTAssertTrue(chargePresentation.contains("state.batteryChargeStatus == \"charging\""))
        XCTAssertTrue(chargePresentation.contains("|| state.batteryChargeStatus == \"full\""))
        XCTAssertTrue(chargePresentation.contains("age <= atriaBatteryChargeFreshness"))
        XCTAssertTrue(chargePresentation.contains("if liveActivityChargeStatusIsFresh"))
        XCTAssertFalse(chargePresentation.contains("if state.batteryChargeStatus == \"full\""),
                       "full must not bypass its independent evidence clock")
        XCTAssertFalse(chargePresentation.contains("case \"full\": return .green"),
                       "an expired full status must fall back to the level tint")
    }

    func testLiveActivityHierarchyIsMinimalTruthfulAndPreviewable() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let islandStart = try XCTUnwrap(source.range(of: "struct AtriaLiveActivityWidget: Widget"))
        let islandEnd = try XCTUnwrap(source.range(of: "private func liveActivityBatteryAvailability",
                                                   range: islandStart.upperBound..<source.endIndex))
        let island = String(source[islandStart.lowerBound..<islandEnd.lowerBound])

        XCTAssertEqual(island.components(separatedBy: "liveActivityTimer(state:").count - 1, 1)
        XCTAssertFalse(island.contains("DynamicIslandExpandedRegion(.center)"))
        XCTAssertFalse(island.contains("liveActivityCaloriesText(for: context.state)"))
        XCTAssertFalse(island.contains("liveActivityDailyStepGoalPresentation(for: context.state)"))
        XCTAssertTrue(island.contains("ViewThatFits(in: .horizontal)"))
        XCTAssertTrue(island.contains("expandedMetricRail(showsSupportingFacts: true)"))
        XCTAssertTrue(island.contains("expandedMetricRail(showsSupportingFacts: false)"))
        XCTAssertFalse(island.contains("if showsZoneBar"),
                       "the decorative zone bar must yield to the bounded metric and action rows")
        XCTAssertFalse(island.contains("compactControls"))
        XCTAssertFalse(island.contains("liveActivitySensorStatusText("),
                       "status belongs once in the header; the metric rail should fail closed to dashes")
        XCTAssertTrue(island.contains("AtriaDynamicIslandExpandedHeader"))
        XCTAssertTrue(island.contains("let activityIsStale = context.isStale"))
        XCTAssertTrue(island.contains("activityIsStale ? Date.distantFuture : Date()"),
                      "ActivityKit's stale transition must fail every transient sensor value closed")
        XCTAssertTrue(source.contains("case .reconnecting:"))
        XCTAssertTrue(source.contains("case .stale:"))
        XCTAssertTrue(source.contains("case .unavailable:"))
        XCTAssertTrue(island.contains(".widgetURL(atriaVitalsURL)"))
        XCTAssertTrue(island.contains(".keylineTint(nominalState"))

        for previewKind in [
            "as: .content",
            "as: .dynamicIsland(.expanded)",
            "as: .dynamicIsland(.compact)",
            "as: .dynamicIsland(.minimal)"
        ] {
            XCTAssertTrue(source.contains(previewKind), "missing preview for \(previewKind)")
        }
        for fixture in ["live", "aboveTarget", "paused", "reconnecting", "stale", "unavailable", "ending"] {
            XCTAssertTrue(source.contains("AtriaLiveActivityPreviewFixture.\(fixture)"))
        }

        let lockStart = try XCTUnwrap(source.range(of: "private struct AtriaLiveActivityLockScreenView"))
        let lockEnd = try XCTUnwrap(source.range(of: "#if DEBUG",
                                                range: lockStart.upperBound..<source.endIndex))
        let lockScreen = String(source[lockStart.lowerBound..<lockEnd.lowerBound])
        XCTAssertTrue(lockScreen.contains(".accessibilityLabel(\"Workout strain "))
        XCTAssertTrue(lockScreen.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(lockScreen.contains("ViewThatFits(in: .vertical)"))
        XCTAssertTrue(lockScreen.contains("compactLockScreenContent"),
                      "Accessibility sizes need a terminal two-row layout under ActivityKit's height cap")
        XCTAssertTrue(lockScreen.contains("context.isStale ? .distantFuture : Date()"))
        XCTAssertFalse(lockScreen.contains(".frame(width: 108)\n            }\n            .accessibilityElement(children: .ignore)"),
                       "the parent must not suppress the Pause and End buttons")
    }

    func testDynamicIslandCoexistencePrioritizesCurrentWorkoutTruthWithoutOwningNowPlaying() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let islandStart = try XCTUnwrap(source.range(of: "struct AtriaLiveActivityWidget: Widget"))
        let islandEnd = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandExpandedBottom",
                                                  range: islandStart.upperBound..<source.endIndex))
        let island = String(source[islandStart.lowerBound..<islandEnd.lowerBound])
        let minimalStart = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandMinimalHeartRate"))
        let minimalEnd = try XCTUnwrap(source.range(of: "private struct AtriaDynamicIslandActivityGlyph",
                                                   range: minimalStart.upperBound..<source.endIndex))
        let minimalHeartRate = String(source[minimalStart.lowerBound..<minimalEnd.lowerBound])

        XCTAssertTrue(island.contains("liveActivityTargetZoneLabel(for: context.state)"),
                      "compact leading should retain the prescribed zone target")
        XCTAssertTrue(island.contains("AtriaDynamicIslandCompactHeartRate(heartRate: context.state.heartRate"),
                      "compact trailing should retain the current measured heart rate")
        XCTAssertTrue(island.contains("AtriaDynamicIslandMinimalHeartRate("),
                      "minimal coexistence should prefer updated workout information over a static glyph")
        XCTAssertTrue(island.contains("if nominalState"))
        XCTAssertTrue(island.contains("Image(systemName: status.systemImage)"),
                      "paused, ending, reconnecting, and stale truth must override the live metric")
        XCTAssertFalse(minimalHeartRate.contains("Image(systemName: \"heart.fill\")"),
                       "minimal must spend its narrow slot on the legible three-digit value")
        XCTAssertTrue(minimalHeartRate.contains("Text(\"\\(heartRate)\")"))
        XCTAssertTrue(minimalHeartRate.contains("size: 14"))
        XCTAssertTrue(minimalHeartRate.contains(".minimumScaleFactor(0.85)"))
        XCTAssertTrue(minimalHeartRate.contains("live heart rate \\(heartRate) beats per minute, \\(zoneLabel)"),
                      "VoiceOver should identify the workout, current metric, and color-coded zone")
        XCTAssertTrue(island.contains("zoneLabel: liveActivityZoneLabel(for: context.state"))
        XCTAssertFalse(island.contains("NowPlaying"))
        XCTAssertFalse(island.contains("mediaController"))

        XCTAssertEqual(source.components(separatedBy: "AtriaLiveActivityPreviewFixture.aboveTarget").count - 1, 4,
                       "the long-name, hour-plus, three-digit stress case belongs in every presentation")
        XCTAssertTrue(source.contains("state.heartRate = 178"))
        XCTAssertTrue(source.contains("state.heartRateZoneIndex = 5"))
    }

    func testActionStoreConsumesRecentSessionMatchedCommandQueueOnceInTapOrder() throws {
        let suite = "AtriaLiveActivityActionTests.recent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: start,
                                                  issuedAt: now.addingTimeInterval(-4))
        let end = AtriaPendingLiveWorkoutAction(action: .end,
                                                workoutStartedAt: start,
                                                issuedAt: now.addingTimeInterval(-2))
        // Store them out of order to prove foreground processing follows the
        // extension's durable tap timestamps rather than encoder order.
        defaults.set(try JSONEncoder().encode([end, pause]),
                     forKey: AtriaLiveWorkoutActionStore.key)

        let consumed = AtriaLiveWorkoutActionStore.consumeAll(now: now,
                                                               defaults: defaults)
        XCTAssertEqual(consumed, [pause, end])
        XCTAssertTrue(AtriaLiveWorkoutActionStore.matches(pause,
                                                          workoutStartedAt: start.addingTimeInterval(0.5)))
        XCTAssertFalse(AtriaLiveWorkoutActionStore.matches(pause,
                                                           workoutStartedAt: start.addingTimeInterval(2)))
        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults).isEmpty)
    }

    func testActionStoreStillDecodesLegacySingleCommandAndClampsActionTime() throws {
        let suite = "AtriaLiveActivityActionTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let pending = AtriaPendingLiveWorkoutAction(action: .end,
                                                    workoutStartedAt: start,
                                                    issuedAt: now.addingTimeInterval(-3))
        defaults.set(try JSONEncoder().encode(pending),
                     forKey: AtriaLiveWorkoutActionStore.key)

        XCTAssertEqual(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults),
                       [pending])
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(pending,
                                                               workoutStartedAt: start,
                                                               now: now),
                       pending.issuedAt)

        let beforeStart = AtriaPendingLiveWorkoutAction(action: .pause,
                                                        workoutStartedAt: start,
                                                        issuedAt: start.addingTimeInterval(-30))
        let future = AtriaPendingLiveWorkoutAction(action: .end,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(3))
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(beforeStart,
                                                               workoutStartedAt: start,
                                                               now: now), start)
        XCTAssertEqual(AtriaLiveWorkoutActionStore.actionDate(future,
                                                               workoutStartedAt: start,
                                                               now: now), now)
    }

    func testActionStoreRejectsAndRemovesStaleCommand() throws {
        let suite = "AtriaLiveActivityActionTests.stale.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let pending = AtriaPendingLiveWorkoutAction(action: .end,
                                                    workoutStartedAt: now.addingTimeInterval(-3_600),
                                                    issuedAt: now.addingTimeInterval(-301))
        defaults.set(try JSONEncoder().encode(pending),
                     forKey: AtriaLiveWorkoutActionStore.key)

        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(now: now, defaults: defaults).isEmpty)
        XCTAssertNil(defaults.data(forKey: AtriaLiveWorkoutActionStore.key))
    }

    func testActionFileQueueClaimsSortsAndAcknowledgesEveryTap() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-1_200)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionQueueTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: start,
                                                  issuedAt: now.addingTimeInterval(-4))
        let resume = AtriaPendingLiveWorkoutAction(action: .resume,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(-3))
        let end = AtriaPendingLiveWorkoutAction(action: .end,
                                                workoutStartedAt: start,
                                                issuedAt: now.addingTimeInterval(-2))
        // Unique files model three extension processes racing to append. File
        // enumeration order must not determine application order.
        try writeAction(end, to: queue, name: "pending-c.json")
        try writeAction(pause, to: queue, name: "pending-a.json")
        try writeAction(resume, to: queue, name: "pending-b.json")

        let consumed = AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        )

        XCTAssertEqual(consumed, [pause, resume, end])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: queue.path).count, 3,
                       "claims must survive until the workout owner applies them")
        consumed.forEach {
            AtriaLiveWorkoutActionStore.acknowledge($0, queueDirectoryURL: queue)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty,
                      "claimed command files should be acknowledged exactly once")
        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).isEmpty)
    }

    func testActionFileQueueDropsMalformedStaleAndFutureCommands() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionValidationTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let stale = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: now.addingTimeInterval(-800),
                                                  issuedAt: now.addingTimeInterval(-301))
        let future = AtriaPendingLiveWorkoutAction(action: .end,
                                                   workoutStartedAt: now,
                                                   issuedAt: now.addingTimeInterval(6))
        try writeAction(stale, to: queue, name: "pending-stale.json")
        try writeAction(future, to: queue, name: "pending-future.json")
        try Data("not-json".utf8).write(to: queue.appendingPathComponent("pending-bad.json"))

        XCTAssertTrue(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty,
                      "invalid commands must be acknowledged rather than replayed")
    }

    func testActionFileQueueRecoversOnlyExpiredClaims() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let start = now.addingTimeInterval(-100)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionClaimTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }

        let expired = AtriaPendingLiveWorkoutAction(action: .pause,
                                                    workoutStartedAt: start,
                                                    issuedAt: now.addingTimeInterval(-4))
        let active = AtriaPendingLiveWorkoutAction(action: .resume,
                                                   workoutStartedAt: start,
                                                   issuedAt: now.addingTimeInterval(-3))
        let expiredURL = try writeAction(expired, to: queue, name: "claimed-old.json")
        let activeURL = try writeAction(active, to: queue, name: "claimed-active.json")
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-31)],
                                              ofItemAtPath: expiredURL.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)],
                                              ofItemAtPath: activeURL.path)

        XCTAssertEqual(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ), [expired])
        XCTAssertTrue(FileManager.default.fileExists(atPath: activeURL.path),
                      "a live consumer's claim must not be stolen")
    }

    func testActionFileQueueReleaseMakesSessionRestorationRetryImmediate() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let queue = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaLiveActionReleaseTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: queue,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: queue) }
        let pause = AtriaPendingLiveWorkoutAction(action: .pause,
                                                  workoutStartedAt: now.addingTimeInterval(-60),
                                                  issuedAt: now.addingTimeInterval(-1))
        try writeAction(pause, to: queue, name: "pending-pause.json")

        let firstClaim = try XCTUnwrap(AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        ).first)
        AtriaLiveWorkoutActionStore.release(firstClaim, queueDirectoryURL: queue)
        let retry = AtriaLiveWorkoutActionStore.consumeAll(
            now: now,
            defaults: nil,
            queueDirectoryURL: queue
        )

        XCTAssertEqual(retry, [pause])
        retry.forEach {
            AtriaLiveWorkoutActionStore.acknowledge($0, queueDirectoryURL: queue)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: queue.path).isEmpty)
    }

    func testElapsedTimerTicksAloneDoNotScheduleActivityKitWrites() {
        let first = liveSnapshot(elapsed: 100, heartRate: 122)
        let timerTick = liveSnapshot(elapsed: 101, heartRate: 122)
        let newHeartRate = liveSnapshot(elapsed: 101, heartRate: 126)

        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: first,
            current: timerTick
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: timerTick,
            current: newHeartRate
        ))
    }

    @discardableResult
    private func writeAction(_ action: AtriaPendingLiveWorkoutAction,
                             to directory: URL,
                             name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try JSONEncoder().encode(action).write(to: url, options: .atomic)
        return url
    }

    func testExistingLiveActivityIsAdoptedOnlyForTheSameWorkout() {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertTrue(AtriaLiveActivityCoordinator.activityBelongsToWorkout(
            activityStartedAt: start,
            workoutStartedAt: start.addingTimeInterval(0.5)
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.activityBelongsToWorkout(
            activityStartedAt: start,
            workoutStartedAt: start.addingTimeInterval(60)
        ))
    }

    func testPendingWorkoutDefersTransientIdleActivityReconciliation() {
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: false,
            pendingWorkoutIsActive: true
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: true,
            pendingWorkoutIsActive: true
        ))
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldDeferExistingActivityReconciliation(
            snapshotIsRecording: false,
            pendingWorkoutIsActive: false
        ))
    }

    func testSlowActivityKitWriterKeepsOnlyNewestSuccessorAndBackgroundProtection() {
        let first = liveSnapshot(elapsed: 100, heartRate: 120)
        var newer = first
        newer.heartRate = 126
        newer.elapsedDuration = 104
        var newest = newer
        newest.heartRate = 131
        newest.heartRateZoneIndex = 4
        newest.heartRateZoneName = "Anaerobic"

        let queued = AtriaLiveActivityCoordinator.coalescedActivityUpdate(
            existing: nil,
            incoming: newer,
            protectsBackgroundWrite: true
        )
        let replaced = AtriaLiveActivityCoordinator.coalescedActivityUpdate(
            existing: queued,
            incoming: newest,
            protectsBackgroundWrite: false
        )

        XCTAssertEqual(replaced.snapshot, newest)
        XCTAssertTrue(replaced.protectsBackgroundWrite,
                      "replacing a queued metric pulse must retain the background-boundary assertion")
    }

    func testSensorFreshnessChangesScheduleLiveActivityUpdate() {
        let live = liveSnapshot(elapsed: 100, heartRate: 122)
        var disconnected = live
        disconnected.sensorHasContact = false
        var newerSample = live
        newerSample.heartRateCapturedAt = live.heartRateCapturedAt?.addingTimeInterval(5)

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: live,
            current: disconnected
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldEnqueueActivityUpdate(
            previous: live,
            current: newerSample
        ))
    }

    func testLiveMetricsUseFiveSecondCadenceButCriticalTransitionsBypassIt() {
        let baseline = liveSnapshot(elapsed: 100, heartRate: 122)

        var oneMoreStep = baseline
        oneMoreStep.steps = 251
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: oneMoreStep,
            elapsedSinceLastWrite: 4.9
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: oneMoreStep,
            elapsedSinceLastWrite: 5
        ))

        var moreCalories = baseline
        moreCalories.activeEnergyKilocalories = 81
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: moreCalories,
            elapsedSinceLastWrite: 4.9
        ))
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: moreCalories,
            elapsedSinceLastWrite: 5
        ))

        var caloriesUnavailable = baseline
        caloriesUnavailable.activeEnergyKilocalories = nil
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: caloriesUnavailable,
            elapsedSinceLastWrite: 0.1
        ), "calorie availability must update immediately rather than leave a prior estimate visible")

        var staleSteps = baseline
        staleSteps.steps = nil
        staleSteps.stepsCapturedAt = nil
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: staleSteps,
            elapsedSinceLastWrite: 0.1
        ), "A frozen step value must clear without waiting for the cadence gate")

        var lostContact = baseline
        lostContact.sensorHasContact = false
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: lostContact,
            elapsedSinceLastWrite: 0.1
        ))

        var changedZone = baseline
        changedZone.heartRateZoneIndex = 4
        changedZone.heartRateZoneName = "Anaerobic"
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: changedZone,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testReachingWorkoutStrainGoalPublishesImmediately() {
        var below = liveSnapshot(elapsed: 100, heartRate: 122)
        below.strain = 4
        below.workoutStrain = 9.9
        below.targetWorkoutStrain = 10
        var reached = below
        reached.workoutStrain = 10

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testDailyStrainCannotFalselyCompleteWorkoutGoal() {
        var baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        baseline.strain = 9.9
        baseline.workoutStrain = 8
        baseline.targetWorkoutStrain = 10
        var dailyStrainCrossed = baseline
        dailyStrainCrossed.strain = 10

        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: dailyStrainCrossed,
            elapsedSinceLastWrite: 0.1
        ), "a workout goal must never be marked reached by the unrelated day numerator")
    }

    func testSensorAvailabilityTransitionsBypassFiveSecondCadence() {
        let baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        var reconnecting = baseline
        reconnecting.heartRateAvailability = .reconnecting
        reconnecting.stepsAvailability = .reconnecting

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: reconnecting,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testPauseResumeAndSourceRecoveryTransitionsBypassCadence() {
        let running = liveSnapshot(elapsed: 100, heartRate: 122)
        var paused = running
        paused.isPaused = true
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: running,
            current: paused,
            elapsedSinceLastWrite: 0.1
        ))

        var resumed = paused
        resumed.isPaused = false
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: paused,
            current: resumed,
            elapsedSinceLastWrite: 0.1
        ))

        var stale = resumed
        stale.heartRateAvailability = .stale
        stale.stepsAvailability = .stale
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: resumed,
            current: stale,
            elapsedSinceLastWrite: 0.1
        ))

        var recovered = stale
        recovered.heartRateAvailability = .live
        recovered.stepsAvailability = .live
        recovered.heartRateCapturedAt = recovered.heartRateCapturedAt?.addingTimeInterval(1)
        recovered.stepsCapturedAt = recovered.stepsCapturedAt?.addingTimeInterval(1)
        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: stale,
            current: recovered,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testExactDailyStepGoalCrossingPublishesImmediatelyButEstimateDoesNotClaimIt() {
        var below = liveSnapshot(elapsed: 100, heartRate: 122)
        below.dailySteps = 7_999
        below.dailyStepsAreEstimated = false
        below.dailyStepGoal = 8_000
        var reached = below
        reached.dailySteps = 8_000

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ))

        below.dailyStepsAreEstimated = true
        reached.dailyStepsAreEstimated = true
        XCTAssertFalse(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: below,
            current: reached,
            elapsedSinceLastWrite: 0.1
        ), "a preliminary step estimate must not publish a validated goal-reaching transition")
    }

    func testTargetChangeAndGoalCrossingBypassFiveSecondCadence() {
        var baseline = liveSnapshot(elapsed: 100, heartRate: 122)
        baseline.strain = 8
        baseline.targetWorkoutStrain = 10
        var changedTarget = baseline
        changedTarget.targetWorkoutStrain = 8

        XCTAssertTrue(AtriaLiveActivityCoordinator.shouldSendActivityUpdateImmediately(
            previous: baseline,
            current: changedTarget,
            elapsedSinceLastWrite: 0.1
        ))
    }

    func testActivityStaleDeadlineRedrawsAtFirstIndependentSensorExpiry() {
        let fallback = Date(timeIntervalSince1970: 2_000_000_000)
        let oldHeartRate = fallback.addingTimeInterval(-70)
        let reconnectedMotion = fallback.addingTimeInterval(-2)

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: oldHeartRate,
            stepsCapturedAt: reconnectedMotion,
            fallback: fallback
        ), reconnectedMotion.addingTimeInterval(15))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: fallback,
            stepsCapturedAt: reconnectedMotion,
            fallback: fallback
        ), reconnectedMotion.addingTimeInterval(15))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            fallback: fallback
        ), fallback.addingTimeInterval(6))
    }

    func testExpiredOrUnavailableSourceCannotKeepFreshWorkoutContentGloballyStale() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let freshHeartRate = now.addingTimeInterval(-2)
        let expiredMotion = now.addingTimeInterval(-20)

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: freshHeartRate,
            stepsCapturedAt: expiredMotion,
            fallback: now,
            heartRateAvailability: .live,
            stepsAvailability: .stale,
            sensorHasContact: true
        ), freshHeartRate.addingTimeInterval(6),
        "stale steps stay labelled stale, but must not mark current HR and workout metrics globally stale")

        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: freshHeartRate,
            stepsCapturedAt: now,
            fallback: now,
            heartRateAvailability: .reconnecting,
            stepsAvailability: .unavailable,
            sensorHasContact: false
        ), now,
        "without a live source, ActivityKit should consider the content stale immediately")
    }

    func testBackgroundEdgeForcesLatestLiveActivityWrite() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("updateLiveActivity(forceActivityWrite: true)"))
        XCTAssertTrue(home.contains("forceActivityWrite: forceActivityWrite"))

        let coordinator = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaLiveActivityCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(coordinator.contains("withName: \"Atria live workout snapshot\""))
        XCTAssertTrue(coordinator.contains("endActiveActivityWriteBackgroundTaskIfNeeded()"))
        XCTAssertTrue(coordinator.contains("endQueuedActivityBackgroundTaskIfNeeded()"))
    }

    func testCanonicalTerminalTransitionUpdatesThenDismissesLiveActivityPromptly() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent().appendingPathComponent("Atria")
        let home = try String(contentsOf: appDirectory.appendingPathComponent("AtriaHomeView.swift"),
                              encoding: .utf8)
        let syncStart = try XCTUnwrap(home.range(of: "private func synchronizeWorkoutUIWithCanonicalIntent"))
        let syncEnd = try XCTUnwrap(home.range(of: "private func restoreOrFinalizePendingWorkoutIntent",
                                              range: syncStart.upperBound..<home.endIndex))
        let terminalSync = String(home[syncStart.lowerBound..<syncEnd.lowerBound])
        XCTAssertTrue(terminalSync.contains("updateLiveActivity(forceActivityWrite: true)"))

        let coordinator = try String(contentsOf: appDirectory
            .appendingPathComponent("AtriaLiveActivityCoordinator.swift"), encoding: .utf8)
        let endStart = try XCTUnwrap(coordinator.range(of: "private func endActivity(with snapshot"))
        let endFinish = try XCTUnwrap(coordinator.range(of: "private func contentState",
                                                       range: endStart.upperBound..<coordinator.endIndex))
        let terminal = String(coordinator[endStart.lowerBound..<endFinish.lowerBound])
        let update = try XCTUnwrap(terminal.range(of: "await activity.update(terminalContent)"))
        let end = try XCTUnwrap(terminal.range(of: "await activity.end(terminalContent"))
        XCTAssertLessThan(update.lowerBound, end.lowerBound)
        XCTAssertTrue(terminal.contains("contentState(from: snapshot, isEnding: true)"))
        XCTAssertTrue(terminal.contains("addingTimeInterval(2)"))
        XCTAssertTrue(coordinator.contains("beginBackgroundTask(\n                withName: \"Atria live workout terminal\""))
    }

    func testForegroundResumeRefreshesWorkoutMetricsAfterFirstFrame() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        let activeStart = try XCTUnwrap(home.range(
            of: "foregroundResumeTask = Task { @MainActor in"
        ))
        let activeEnd = try XCTUnwrap(home.range(
            of: "private func flushWorkoutRouteAtBackgroundBoundary()",
            range: activeStart.upperBound..<home.endIndex
        ))
        let resume = String(home[activeStart.lowerBound..<activeEnd.lowerBound])

        let firstFrameYield = try XCTUnwrap(resume.range(of: "await Task.yield()"))
        let liveRefresh = try XCTUnwrap(resume.range(
            of: "updateLiveActivity(forceActivityWrite: true)"
        ))
        let sleepSettlement = try XCTUnwrap(resume.range(
            of: "store.autoConfirmSleepOnForegroundIfUseful"
        ))
        XCTAssertLessThan(firstFrameYield.lowerBound, liveRefresh.lowerBound)
        XCTAssertLessThan(liveRefresh.lowerBound, sleepSettlement.lowerBound)
        XCTAssertGreaterThanOrEqual(
            resume.components(separatedBy: ".environmentIsAuthorized(").count - 1,
            2,
            "both deferred phases must recheck live lifecycle authority"
        )
        XCTAssertTrue(resume.contains("UIApplication.shared.applicationState == .active"))
        XCTAssertTrue(resume.contains("AtriaHistoricalProjectionForegroundGate.isBackgrounded"))
        XCTAssertTrue(resume.contains("foregroundResumeAuthority.isCurrent(ticket)"))
        XCTAssertTrue(resume.contains("executionShouldContinue:"),
                      "sleep settlement must retain process suspension authority")
    }

    func testForegroundSleepSettlementRetiresRevokedGenerationAndCarriesAuthorityIntoRetry() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sessions = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Sessions.swift"), encoding: .utf8)
        let retryStart = try XCTUnwrap(sessions.range(
            of: "private func scheduleSleepSettlementRetry"
        ))
        let retryEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static func sleepSettlementRetryDelay",
            range: retryStart.upperBound..<sessions.endIndex
        ))
        let retry = String(sessions[retryStart.lowerBound..<retryEnd.lowerBound])
        XCTAssertTrue(retry.contains("executionShouldContinue:"))
        XCTAssertTrue(retry.contains("guard executionShouldContinue() else"))
        XCTAssertTrue(retry.contains("lastForegroundSleepAutoConfirmAt = nil"),
                      "revocation must not retain the 30-minute cadence stamp")
        XCTAssertTrue(retry.contains("executionShouldContinue: executionShouldContinue"),
                      "the delayed retry must not fall back to unconditional authority")
        XCTAssertTrue(retry.contains("settlementAuthority: settlementAuthority"),
                      "a retry must retain the exact monotonic owner identity")

        let cleanupStart = try XCTUnwrap(sessions.range(
            of: "private func retireForegroundSleepSettlementAfterAuthorityLoss"
        ))
        let cleanupEnd = try XCTUnwrap(sessions.range(
            of: "nonisolated static let foregroundSleepEvaluationLookbackDays",
            range: cleanupStart.upperBound..<sessions.endIndex
        ))
        let cleanup = String(sessions[cleanupStart.lowerBound..<cleanupEnd.lowerBound])
        XCTAssertTrue(cleanup.contains("foregroundSleepSettlementWorkerIsCurrent(generation)"),
                      "a stale cleanup may not cancel a replacement settlement")
        XCTAssertTrue(cleanup.contains("pendingForegroundSleepSettlementWorkItem = nil"))
        XCTAssertTrue(cleanup.contains("pendingForegroundSleepSettlementOwner = nil"))
        XCTAssertTrue(cleanup.contains("lastForegroundSleepAutoConfirmAt = nil"))
        XCTAssertTrue(cleanup.contains("drainForegroundSleepSettlementCompletions(succeeded: false)"))

        let workerStart = try XCTUnwrap(sessions.range(
            of: "let workItem = DispatchWorkItem { [weak self] in",
            range: cleanupEnd.upperBound..<sessions.endIndex
        ))
        let workerEnd = try XCTUnwrap(sessions.range(
            of: "pendingForegroundSleepSettlementWorkItem = workItem",
            range: workerStart.upperBound..<sessions.endIndex
        ))
        let worker = String(sessions[workerStart.lowerBound..<workerEnd.lowerBound])
        XCTAssertTrue(worker.contains("retireForegroundSleepSettlementAfterAuthorityLoss"),
                      "every cooperative authority exit must release the exact worker sentinel")
    }

    func testLockScreenActionPreservesIndependentSensorFreshness() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaShared/AtriaLiveWorkoutControlIntent.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("state.heartRateCapturedAt?.addingTimeInterval(6)"))
        XCTAssertTrue(source.contains("state.stepsCapturedAt?.addingTimeInterval(15)"))
        XCTAssertTrue(source.contains("state.batteryCapturedAt?.addingTimeInterval(10 * 60)"))
        XCTAssertTrue(source.contains("expiry > canonicalState.appliedAt"),
                      "an already-expired source must not keep a fresh source globally stale")
        XCTAssertTrue(source.contains("let staleDate = sourceExpiries.min()"),
                      "a Lock Screen command should advance to the next live source expiry")
    }

    func testAppAndWidgetLiveActivitySchemasStayEncodingCompatible() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let app = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let widget = try String(contentsOf: projectDirectory
            .appendingPathComponent("AtriaWidget/AtriaLiveActivityAttributes.swift"), encoding: .utf8)

        func normalizedSchema(_ source: String) -> String {
            source.split(whereSeparator: \.isNewline)
                .map { line in line.split(separator: "//", maxSplits: 1).first.map(String.init) ?? "" }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        XCTAssertEqual(normalizedSchema(app), normalizedSchema(widget))
    }

    func testLiveActivityPayloadExcludesUnrenderedNowPlayingStateAndStaysBounded() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let schema = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let home = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)

        for unrenderedField in ["mediaTitle", "mediaArtist", "mediaIsPlaying", "mediaHasNowPlayingInfo"] {
            XCTAssertFalse(schema.contains(unrenderedField))
        }
        let publisherStart = try XCTUnwrap(home.range(of: "private var liveActivityUpdates"))
        let publisherEnd = try XCTUnwrap(home.range(of: "private var hapticUpdates",
                                                    range: publisherStart.upperBound..<home.endIndex))
        XCTAssertFalse(home[publisherStart.lowerBound..<publisherEnd.lowerBound]
            .contains("mediaController.$state"),
            "Now Playing changes must not force an ActivityKit write for UI that never renders media")

        let state = AtriaLiveActivityAttributes.ContentState(
            heartRate: 188,
            strain: 20.9,
            batteryLevel: 100,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging",
            batteryCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            batteryChargeCapturedAt: nil,
            batteryAvailability: .live,
            readingCount: .max,
            updatedAt: Date(timeIntervalSince1970: 2_000_000_000),
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sensorHasContact: true,
            heartRateAvailability: .live,
            activityName: String(repeating: "W", count: 64),
            activitySystemImage: "figure.run",
            heartRateZoneIndex: 5,
            heartRateZoneName: String(repeating: "Z", count: 64),
            steps: .max,
            stepsAreEstimated: false,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            stepsAvailability: .live,
            dailySteps: .max,
            dailyStepsAreEstimated: false,
            dailyStepGoal: .max,
            workoutStrain: 20.9,
            targetWorkoutStrain: 21,
            activeEnergyKilocalories: 99_999,
            targetLowerHeartRateZone: 1,
            targetUpperHeartRateZone: 5,
            isPaused: false,
            isEnding: false,
            timerAnchor: Date(timeIntervalSince1970: 2_000_000_000),
            elapsedDuration: 86_400
        )
        let encoded = try JSONEncoder().encode(state)
        XCTAssertLessThan(encoded.count, 4_096,
                          "ActivityKit rejects dynamic content whose encoded state exceeds 4 KB")

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded)
            as? [String: Any])
        legacyObject["mediaTitle"] = "Previously playing"
        legacyObject["mediaArtist"] = "Legacy artist"
        legacyObject["mediaIsPlaying"] = true
        legacyObject["mediaHasNowPlayingInfo"] = true
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(try JSONDecoder().decode(AtriaLiveActivityAttributes.ContentState.self,
                                                from: legacyData),
                       state,
                       "Removing unrendered keys must continue decoding an in-flight activity from the previous build")
    }

    func testWidgetFailsClosedAndDistinguishesLiveReconnectStaleUnavailable() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSourceURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: widgetSourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("state.sensorHasContact != false"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= atriaLiveHeartRateFreshness"))
        XCTAssertFalse(source.contains("state.heartRateCapturedAt ?? state.updatedAt"),
                       "unrelated activity updates must not make a legacy HR reading fresh")
        XCTAssertTrue(source.contains("guard let capturedAt = state.heartRateCapturedAt"),
                      "HR without its independent source timestamp must fail closed")
        XCTAssertTrue(source.contains("case .reconnecting: return \"Reconnecting\""))
        XCTAssertTrue(source.contains("case .stale: return \"HR stale\""))
        XCTAssertTrue(source.contains("case .unavailable: return \"Unavailable\""))
        XCTAssertTrue(source.contains("state.stepsAreEstimated != false"),
                      "missing workout-step provenance must fail closed as estimated")
        XCTAssertTrue(source.contains("let capturedAt = state.stepsCapturedAt"))
        XCTAssertTrue(source.contains("now.timeIntervalSince(capturedAt) <= atriaStepFreshness"))
        XCTAssertTrue(source.contains("labelText: \"Steps reconnecting\""))
        XCTAssertTrue(source.contains("labelText: \"Steps stale\""))
        XCTAssertTrue(source.contains("labelText: \"Steps unavailable\""))
        XCTAssertTrue(source.contains("strap-derived workout steps"))
        XCTAssertTrue(source.contains("liveActivityStrainProgressText(for: state, now: now)"))
        XCTAssertTrue(source.contains("String(format: \"%.1f / %.1f\", strain, target)"))
        XCTAssertTrue(source.contains("String(format: \"Goal ✓ · %.1f\", strain)"))
        XCTAssertTrue(source.contains("let strain = state.workoutStrain else { return nil }"),
                      "workout goals must use the canonical workout-only strain projection")
        XCTAssertTrue(source.contains("guard state.workoutStrainAvailability == .live"),
                      "stale or disconnected strain must fail closed instead of retaining a numeric goal")
        XCTAssertTrue(source.contains("let capturedAt = state.batteryCapturedAt"),
                      "Lock Screen battery must have its own level-bearing evidence clock")
        XCTAssertTrue(source.contains("let capturedAt = state.batteryChargeCapturedAt"),
                      "the charging bolt must expire independently from the percentage")
        XCTAssertTrue(source.contains("age > atriaBatteryFreshness"))
        XCTAssertFalse(source.contains("state.batteryCapturedAt ?? state.updatedAt"),
                       "timer and HR writes must not renew battery evidence")
        XCTAssertTrue(source.contains("state.dailyStepsAreEstimated != false"),
                      "missing daily-step provenance must fail closed as estimated")
        XCTAssertTrue(source.contains("state.dailyStepsIsLowerBound != false"),
                      "missing daily-step completeness must fail closed as a lower bound")
        XCTAssertTrue(source.contains("let capturedAt = state.dailyStepsCapturedAt"),
                      "daily goal freshness must use the durable daily receipt clock")
        XCTAssertFalse(source.contains("let capturedAt = state.stepsCapturedAt,\n          capturedAt <= now"),
                       "workout-local motion must not renew the daily step goal")
        XCTAssertTrue(source.contains("reached && exact"),
                      "estimated or lower-bound steps must never claim goal completion")
        XCTAssertTrue(source.contains("liveActivitySensorStatusText"))
        XCTAssertTrue(source.contains("return statuses.isEmpty ? nil"),
                      "healthy live sources must not waste Lock Screen space on a redundant status row")
        XCTAssertTrue(source.contains("\\(label) last \\(atriaCaptureTimeText($0))"),
                      "stale sensor values must reveal their actual capture time")
        XCTAssertTrue(source.contains("text: \"Step goal stale\""),
                      "stale daily-goal evidence must keep its fail-closed presentation branch")
        XCTAssertTrue(source.contains("text: \"Step goal --\""),
                      "missing daily-goal evidence must keep its fail-closed presentation branch")
        XCTAssertTrue(source.contains("Approximately \\(Int(calories.rounded())) active calories"))
        XCTAssertTrue(source.contains("guard let calories = state.activeEnergyKilocalories"))
        XCTAssertTrue(source.contains("calories.isFinite"))
        XCTAssertTrue(source.contains("calories >= 0 else { return \"-- kcal\" }"),
                      "invalid or missing energy evidence must never be rendered as a fabricated calorie value")
        XCTAssertTrue(source.contains(".disabled(state.isEnding ?? false)"),
                      "controls must lock after End is accepted to prevent duplicate commands")

        let home = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)
        XCTAssertTrue(home.contains("steps: metricProjection.steps.count"))
        XCTAssertTrue(home.contains("activeEnergyKilocalories: metricProjection.loadIsComplete"))
        XCTAssertTrue(home.contains("? metricProjection.activeCalories : nil"),
                      "incomplete rolled or retroactively paused load must not publish precise calories")
        XCTAssertTrue(home.contains("stepsCapturedAt: metricProjection.steps.capturedAt"),
                      "A stale transition must retain its real source time for the Lock Screen's last-seen label")
        XCTAssertFalse(home.contains("stepsCapturedAt: metricProjection.steps.liveCapturedAt"))
    }

    func testWorkoutTargetZonesFlowIntoBackwardCompatibleLiveActivityUI() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent()
        let appSchema = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaLiveActivityAttributes.swift"), encoding: .utf8)
        let widgetSource = try String(contentsOf: projectDirectory
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let homeSource = try String(contentsOf: projectDirectory
            .appendingPathComponent("Atria/AtriaHomeView.swift"), encoding: .utf8)

        XCTAssertTrue(appSchema.contains("var targetLowerHeartRateZone: Int? = nil"))
        XCTAssertTrue(appSchema.contains("var targetUpperHeartRateZone: Int? = nil"))
        XCTAssertTrue(homeSource.contains("targetLowerHeartRateZone: session?.lowerTargetZone"))
        XCTAssertTrue(homeSource.contains("targetUpperHeartRateZone: session?.upperTargetZone"))
        XCTAssertTrue(widgetSource.contains("return lower == upper ? \"Z\\(lower)\" : \"Z\\(lower)–Z\\(upper)\""))
        XCTAssertTrue(widgetSource.contains("compactLeading:"))
        XCTAssertTrue(widgetSource.contains("Text(\"T \\(target)\")"),
                      "current target zones should keep an explicit T prefix in compact layouts")
        XCTAssertTrue(widgetSource.contains("accessibilityLabel(\"Target heart rate \\(target)\")"),
                      "the target zone must stay an accessible element wherever the layout renders it")
    }

    private func liveSnapshot(elapsed: TimeInterval,
                              heartRate: Int) -> AtriaLiveActivityCoordinator.Snapshot {
        AtriaLiveActivityCoordinator.Snapshot(
            isRecording: true,
            heartRate: heartRate,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            sensorHasContact: true,
            heartRateAvailability: .live,
            strain: 5.4,
            batteryLevel: 53,
            batteryCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            batteryChargeCapturedAt: nil,
            batteryAvailability: .live,
            batteryChargeStatus: .levelOnly,
            readingCount: 100,
            startedAt: Date(timeIntervalSince1970: 2_000_000_000),
            activityName: "Strength",
            activitySystemImage: "dumbbell.fill",
            heartRateZoneIndex: 3,
            heartRateZoneName: "Aerobic",
            steps: 250,
            stepsAreEstimated: true,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_000_000_000),
            stepsAvailability: .live,
            dailySteps: 4_250,
            dailyStepsAreEstimated: true,
            dailyStepGoal: 8_000,
            workoutStrain: 5.4,
            targetWorkoutStrain: 10,
            activeEnergyKilocalories: 80,
            isPaused: false,
            elapsedDuration: elapsed
        )
    }

    func testWorkoutStrainClockParticipatesInLiveActivityStaleness() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            strainCapturedAt: now,
            fallback: now,
            heartRateFreshnessWindow: 90,
            strainAvailability: .live
        ), now.addingTimeInterval(90))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            strainCapturedAt: now,
            fallback: now,
            strainAvailability: .stale
        ), now)
    }

    func testLiveActivityUsesCanonicalPulseZoneAndSixSecondFreshness() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let home = try String(
            contentsOf: root.appendingPathComponent("Atria/AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(home.range(
            of: "private func updateLiveActivity(forceActivityWrite: Bool = false)"
        ))
        let end = try XCTUnwrap(home.range(
            of: "private func liveWorkoutHeartRateAvailability",
            range: start.upperBound..<home.endIndex
        ))
        let body = String(home[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(body.contains("let pulse = model.pulseLiveStore.state"))
        XCTAssertTrue(body.contains("heartRateZoneIndex: zone?.index"))
        XCTAssertTrue(body.contains("heartRateZoneName: zone?.name"))
        XCTAssertFalse(body.contains("store.baseline.restingInt ?? 60"))

        let sample = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: sample,
            stepsCapturedAt: nil,
            fallback: sample,
            heartRateAvailability: .live,
            sensorHasContact: true
        ), sample.addingTimeInterval(6))
    }

    func testBatteryClockParticipatesInLiveActivityStalenessWithoutRenewingHR() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            batteryCapturedAt: now,
            fallback: now,
            batteryFreshnessWindow: 600,
            batteryAvailability: .live
        ), now.addingTimeInterval(600))
        XCTAssertEqual(AtriaLiveActivityCoordinator.sensorStaleDate(
            heartRateCapturedAt: nil,
            stepsCapturedAt: nil,
            batteryCapturedAt: now,
            fallback: now,
            batteryAvailability: .stale
        ), now)
    }

    func testLegacyLiveActivityStateDecodesWithoutBatteryFreshness() throws {
        let encoded = try JSONEncoder().encode(AtriaLiveActivityAttributes.ContentState(
            heartRate: 80, strain: 3.2, batteryLevel: 50,
            batteryChargeStatus: "levelOnly", batteryChargeText: "Unavailable",
            batteryCapturedAt: Date(), batteryChargeCapturedAt: Date(), batteryAvailability: .live,
            readingCount: 10, updatedAt: Date()
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "batteryCapturedAt")
        object.removeValue(forKey: "batteryChargeCapturedAt")
        object.removeValue(forKey: "batteryAvailability")
        let decoded = try JSONDecoder().decode(
            AtriaLiveActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.batteryCapturedAt)
        XCTAssertNil(decoded.batteryChargeCapturedAt)
        XCTAssertNil(decoded.batteryAvailability)
    }

    func testLegacyLiveActivityStateDecodesWithoutStrainFreshness() throws {
        let legacy = try JSONEncoder().encode(AtriaLiveActivityAttributes.ContentState(
            heartRate: 80, strain: 3.2, batteryLevel: 50,
            batteryChargeStatus: "levelOnly", batteryChargeText: "Unavailable",
            readingCount: 10, updatedAt: Date()
        ))
        var object = try JSONSerialization.jsonObject(with: legacy) as! [String: Any]
        object.removeValue(forKey: "workoutStrainCapturedAt")
        object.removeValue(forKey: "workoutStrainAvailability")
        let decoded = try JSONDecoder().decode(
            AtriaLiveActivityAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(decoded.workoutStrainCapturedAt)
        XCTAssertNil(decoded.workoutStrainAvailability)
    }
}
