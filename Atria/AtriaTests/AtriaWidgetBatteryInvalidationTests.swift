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
                                      heartRate: 72,
                                      heartRateCapturedAt: Date(timeIntervalSince1970: 1_500),
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
        XCTAssertEqual(sanitized.batteryChargeText, "Pending")
        XCTAssertEqual(sanitized.recoveryPercent, 61)
        XCTAssertEqual(sanitized.strain, 4.2)
        XCTAssertEqual(sanitized.heartRate, 72)
        XCTAssertEqual(sanitized.heartRateCapturedAt, snapshot.heartRateCapturedAt)
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
                                     heartRate: 72,
                                     heartRateCapturedAt: Date(timeIntervalSince1970: 995),
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
            stepsCapturedAt: Date(timeIntervalSince1970: 1_998),
            strain: 6.8,
            batteryLevel: 43,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.createdAt, createdAt)
        XCTAssertEqual(patched.heartRate, 151)
        XCTAssertEqual(patched.heartRateCapturedAt, Date(timeIntervalSince1970: 1_999))
        XCTAssertEqual(patched.steps, 1_120)
        XCTAssertEqual(patched.stepsCapturedAt, Date(timeIntervalSince1970: 1_998))
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
        XCTAssertNil(decoded.heartRateCapturedAt)
    }

    func testStaticWidgetPinsSensorValuesToIndependentFreshnessClocks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("let stepsCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("let heartRateCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("age <= atriaStaticSensorFreshness"))
        XCTAssertTrue(widgetSource.contains("capturedAt: s.stepsCapturedAt"))
        XCTAssertTrue(widgetSource.contains("capturedAt: s.heartRateCapturedAt"))
        XCTAssertTrue(widgetSource.contains("capturedAt.addingTimeInterval(atriaStaticSensorFreshness + 0.001)"),
                      "The timeline must clear values at 90 seconds, not wait for its 15-minute reload")
        XCTAssertFalse(widgetSource.contains("case .bpm:\n            return s.heartRate.map(String.init)"))
    }
}
