import XCTest
@testable import Atria

@MainActor
final class AtriaWidgetBatteryInvalidationTests: XCTestCase {
    func testDisputedBatteryIsRemovedWithoutWaitingForSessionLoad() throws {
        let suite = "AtriaWidgetBatteryInvalidationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: Date(),
                                      recoveryPercent: 61,
                                      recoveryConfidence: "personal_baseline",
                                      recoveryDetail: "Saved",
                                      strain: 4.2,
                                      restingHR: 59,
                                      hrvRMSSD: 48,
                                      hrvState: "personal_baseline",
                                      maxHR: 190,
                                      sleepHours: 7.5,
                                      steps: nil,
                                      stepsCapturedAt: nil,
                                      dailyStepGoal: 8_000,
                                      heartRate: 72,
                                      heartRateCapturedAt: Date(timeIntervalSince1970: 1_500),
                                      heartRateZoneIndex: 1,
                                      heartRateZoneName: "Warm-up",
                                      batteryLevel: 10,
                                      batteryChargeStatus: "notCharging",
                                      batteryChargeText: "Not charging",
                                      layoutGlanceMetrics: nil,
                                      layoutRingCenterMetric: nil,
                                      layoutLegendStatStyle: nil,
                                      layoutAccent: nil,
                                      storage: "test",
                                      appGroupEnabled: false,
                                      widgetTargetPresent: true,
                                      complicationTargetPresent: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot), forKey: "atria.widgetSnapshot.v1")

        WidgetSnapshotPublisher.invalidateBatteryProjection(defaults: defaults)

        let data = try XCTUnwrap(defaults.data(forKey: "atria.widgetSnapshot.v1"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sanitized = try decoder.decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(sanitized.batteryLevel)
        XCTAssertEqual(sanitized.batteryChargeStatus, "levelOnly")
        XCTAssertEqual(sanitized.batteryChargeText, "Unavailable")
        XCTAssertEqual(sanitized.recoveryPercent, 61)
        XCTAssertEqual(sanitized.strain, 4.2)
        XCTAssertEqual(sanitized.heartRate, 72)
        XCTAssertEqual(sanitized.heartRateCapturedAt, snapshot.heartRateCapturedAt)
        XCTAssertEqual(sanitized.heartRateZoneIndex, 1)
        XCTAssertEqual(sanitized.dailyStepGoal, 8_000)
    }

    func testLiveWorkoutPatchChangesOnlyLiveWidgetFields() {
        let createdAt = Date(timeIntervalSince1970: 2_000)
        let current = WidgetSnapshot(schema: 4,
                                     createdAt: Date(timeIntervalSince1970: 1_000),
                                     recoveryPercent: 61,
                                     recoveryConfidence: "personal_baseline",
                                     recoveryDetail: "Saved morning recovery",
                                     strain: 4.2,
                                     restingHR: 59,
                                     hrvRMSSD: 48,
                                     hrvState: "personal_baseline",
                                     maxHR: 190,
                                     sleepHours: 7.5,
                                     steps: 1_000,
                                     stepsCapturedAt: Date(timeIntervalSince1970: 990),
                                     dailyStepGoal: 8_000,
                                     heartRate: 72,
                                     heartRateCapturedAt: Date(timeIntervalSince1970: 995),
                                     heartRateZoneIndex: 1,
                                     heartRateZoneName: "Warm-up",
                                     batteryLevel: nil,
                                     batteryChargeStatus: "levelOnly",
                                     batteryChargeText: "Pending",
                                     layoutGlanceMetrics: ["recovery", "strain", "sleep"],
                                     layoutRingCenterMetric: "recovery",
                                     layoutLegendStatStyle: "value",
                                     layoutAccent: "mint",
                                     storage: "test",
                                     appGroupEnabled: false,
                                     widgetTargetPresent: true,
                                     complicationTargetPresent: true)

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: createdAt,
            heartRate: 151,
            heartRateCapturedAt: Date(timeIntervalSince1970: 1_999),
            steps: 1_120,
            stepsAreEstimated: true,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_998),
            strain: 6.8,
            batteryLevel: 43,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.createdAt, createdAt)
        XCTAssertEqual(patched.heartRate, 151)
        XCTAssertEqual(patched.heartRateCapturedAt, Date(timeIntervalSince1970: 1_999))
        XCTAssertEqual(patched.heartRateZoneIndex, 3)
        XCTAssertEqual(patched.heartRateZoneName, "Aerobic")
        XCTAssertEqual(patched.steps, 1_120)
        XCTAssertEqual(patched.stepsAreEstimated, true)
        XCTAssertEqual(patched.stepsCapturedAt, Date(timeIntervalSince1970: 1_998))
        XCTAssertEqual(patched.dailyStepGoal, 8_000)
        XCTAssertEqual(patched.strain, 6.8)
        XCTAssertEqual(patched.batteryLevel, 43)
        XCTAssertEqual(patched.recoveryPercent, current.recoveryPercent)
        XCTAssertEqual(patched.recoveryDetail, current.recoveryDetail)
        XCTAssertEqual(patched.hrvRMSSD, current.hrvRMSSD)
        XCTAssertEqual(patched.sleepHours, current.sleepHours)
        XCTAssertEqual(patched.layoutGlanceMetrics, current.layoutGlanceMetrics)
    }

    func testLegacySnapshotWithoutIndependentSensorDatesStillDecodes() throws {
        let legacyJSON = """
        {
          "schema": 4,
          "createdAt": "2026-07-13T06:00:00Z",
          "recoveryPercent": 61,
          "recoveryConfidence": "personal_baseline",
          "recoveryDetail": "Saved",
          "strain": 4.2,
          "restingHR": 59,
          "hrvRMSSD": 48,
          "hrvState": "personal_baseline",
          "maxHR": 190,
          "sleepHours": 7.5,
          "steps": 1000,
          "heartRate": 72,
          "storage": "test",
          "appGroupEnabled": false,
          "widgetTargetPresent": true,
          "complicationTargetPresent": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(decoded.steps, 1_000)
        XCTAssertEqual(decoded.heartRate, 72)
        XCTAssertNil(decoded.stepsCapturedAt)
        XCTAssertNil(decoded.stepsAreEstimated)
        XCTAssertNil(decoded.heartRateCapturedAt)
        XCTAssertNil(decoded.dailyStepGoal)
        XCTAssertNil(decoded.heartRateZoneIndex)
        XCTAssertNil(decoded.heartRateZoneName)
    }

    func testStaticWidgetPinsSensorValuesToIndependentFreshnessClocks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("let stepsCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("var stepsAreEstimated: Bool? = nil"))
        XCTAssertTrue(widgetSource.contains("let heartRateCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("var dailyStepGoal: Int? = nil"))
        XCTAssertTrue(widgetSource.contains("var heartRateZoneIndex: Int? = nil"))
        XCTAssertTrue(widgetSource.contains("var heartRateZoneName: String? = nil"))
        XCTAssertTrue(widgetSource.contains("private let atriaStaticSensorFreshness: TimeInterval = 90"))
        XCTAssertTrue(widgetSource.contains("private let atriaHeartRateFreshness: TimeInterval = 90"))
        XCTAssertTrue(widgetSource.contains("private let atriaStaticStepFreshness: TimeInterval = 90"))
        XCTAssertTrue(widgetSource.contains("private let atriaLiveActivityStepFreshness: TimeInterval = 15"))
        XCTAssertTrue(widgetSource.contains("age <= freshness"))
        XCTAssertTrue(widgetSource.contains("capturedAt: s.stepsCapturedAt"))
        XCTAssertTrue(widgetSource.contains("freshness: atriaStaticStepFreshness"))
        XCTAssertTrue(widgetSource.contains("capturedAt: s.heartRateCapturedAt"))
        XCTAssertTrue(widgetSource.contains("freshness: atriaHeartRateFreshness"))
        XCTAssertTrue(widgetSource.contains("(snapshot?.heartRateCapturedAt, atriaHeartRateFreshness)"))
        XCTAssertTrue(widgetSource.contains("(snapshot?.stepsCapturedAt, atriaStaticStepFreshness)"))
        XCTAssertTrue(widgetSource.contains("capturedAt.addingTimeInterval(freshness + 0.001)"),
                      "The timeline must clear each sensor at its exact expiry boundary")
        XCTAssertFalse(widgetSource.contains("case .bpm:\n            return s.heartRate.map(String.init)"))
        XCTAssertTrue(widgetSource.contains("return \"HR stale · last \\(atriaCaptureTimeText(capturedAt))\""))
        XCTAssertTrue(widgetSource.contains("return \"\\(zone) · \\(atriaCaptureTimeText(capturedAt))\""))
    }

    func testPreliminaryStrapStepsRemainPublishableButNeverValidated() {
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_preliminary"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_preliminary"))
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_validated"))
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_validated"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_calibrating"))
    }

    func testStaticStepsWidgetMarksPreliminaryCountsAsEstimated() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("return s.stepsAreEstimated == true ? \"~\\(value)\" : value"))
        XCTAssertTrue(widgetSource.contains("let accuracy = snapshot.stepsAreEstimated == true ? \"Estimated\" : \"Confirmed\""))
        XCTAssertTrue(widgetSource.contains("return \"Goal ✓ · confirmed · \\(captured)\""))
        XCTAssertTrue(widgetSource.contains("return \"\\(accuracy) · \\(percent)% goal · \\(captured)\""))
    }

    func testSubHundredStepProgressGetsBoundedTrailingWidgetReload() {
        let reloadedAt = Date(timeIntervalSince1970: 10_000)
        let previous = deliverySnapshot(steps: 123,
                                        stepsCapturedAt: reloadedAt,
                                        heartRate: 82,
                                        heartRateCapturedAt: reloadedAt)
        let updated = deliverySnapshot(steps: 157,
                                       stepsCapturedAt: reloadedAt.addingTimeInterval(20),
                                       heartRate: 82,
                                       heartRateCapturedAt: reloadedAt.addingTimeInterval(20))

        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: reloadedAt,
            snapshot: updated,
            now: reloadedAt.addingTimeInterval(20)
        ), 40)
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: reloadedAt,
            snapshot: updated,
            now: reloadedAt.addingTimeInterval(60)
        ), 0)
    }

    func testCaptureClockRenewalIsDeliveredEvenWhenSensorValuesDoNotChange() {
        let reloadedAt = Date(timeIntervalSince1970: 20_000)
        let previous = deliverySnapshot(steps: 480,
                                        stepsCapturedAt: reloadedAt,
                                        heartRate: 84,
                                        heartRateCapturedAt: reloadedAt)
        let renewed = deliverySnapshot(steps: 480,
                                       stepsCapturedAt: reloadedAt.addingTimeInterval(5),
                                       heartRate: 84,
                                       heartRateCapturedAt: reloadedAt.addingTimeInterval(5))

        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: reloadedAt,
            snapshot: renewed,
            now: reloadedAt.addingTimeInterval(5)
        ), 55)
    }

    func testUnchangedSensorProjectionDoesNotCreateMinuteReloadLoop() {
        let reloadedAt = Date(timeIntervalSince1970: 30_000)
        let snapshot = deliverySnapshot(steps: 480,
                                        stepsCapturedAt: reloadedAt,
                                        heartRate: 84,
                                        heartRateCapturedAt: reloadedAt)

        XCTAssertNil(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: snapshot,
            lastReloadAt: reloadedAt,
            snapshot: snapshot,
            now: reloadedAt.addingTimeInterval(60)
        ))
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: snapshot,
            lastReloadAt: reloadedAt,
            snapshot: snapshot,
            now: reloadedAt.addingTimeInterval(15 * 60)
        ), 0)
    }

    func testSemanticWidgetTransitionStillReloadsImmediately() {
        let reloadedAt = Date(timeIntervalSince1970: 40_000)
        let previous = deliverySnapshot(steps: 7_990,
                                        stepsCapturedAt: reloadedAt,
                                        heartRate: 130,
                                        heartRateCapturedAt: reloadedAt,
                                        strain: 4.2)
        let goalReached = deliverySnapshot(steps: 8_010,
                                           stepsCapturedAt: reloadedAt.addingTimeInterval(2),
                                           heartRate: 130,
                                           heartRateCapturedAt: reloadedAt.addingTimeInterval(2),
                                           strain: 4.3)

        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: reloadedAt,
            snapshot: goalReached,
            now: reloadedAt.addingTimeInterval(2)
        ), 0)
    }

    private func deliverySnapshot(steps: Int?,
                                  stepsCapturedAt: Date?,
                                  heartRate: Int?,
                                  heartRateCapturedAt: Date?,
                                  strain: Double = 4.2) -> WidgetSnapshot {
        WidgetSnapshot(schema: 4,
                       createdAt: stepsCapturedAt ?? heartRateCapturedAt ?? Date(timeIntervalSince1970: 1),
                       recoveryPercent: 61,
                       recoveryConfidence: "personal_baseline",
                       recoveryDetail: "Saved",
                       strain: strain,
                       restingHR: 59,
                       hrvRMSSD: 48,
                       hrvState: "personal_baseline",
                       maxHR: 190,
                       sleepHours: 7.5,
                       steps: steps,
                       stepsAreEstimated: false,
                       stepsCapturedAt: stepsCapturedAt,
                       dailyStepGoal: 8_000,
                       heartRate: heartRate,
                       heartRateCapturedAt: heartRateCapturedAt,
                       heartRateZoneIndex: 2,
                       heartRateZoneName: "Fat burn",
                       batteryLevel: 43,
                       batteryChargeStatus: "notCharging",
                       batteryChargeText: "Not charging",
                       layoutGlanceMetrics: ["steps", "strain", "bpm"],
                       layoutRingCenterMetric: "recovery",
                       layoutLegendStatStyle: "value",
                       layoutAccent: "mint",
                       storage: "test",
                       appGroupEnabled: true,
                       widgetTargetPresent: true,
                       complicationTargetPresent: true)
    }
}
