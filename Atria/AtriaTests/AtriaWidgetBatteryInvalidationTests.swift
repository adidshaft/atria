import XCTest
@testable import Atria

@MainActor
final class AtriaWidgetBatteryInvalidationTests: XCTestCase {
    func testDisputedBatteryIsRemovedWithoutWaitingForSessionLoad() throws {
        let suite = "AtriaWidgetBatteryInvalidationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var snapshot = WidgetSnapshot(schema: 4,
                                      createdAt: Date(),
                                      recoveryPercent: 61,
                                      recoveryConfidence: "personal_baseline",
                                      recoveryDetail: "Saved",
                                      strain: 4.2,
                                      strainCapturedAt: Date(timeIntervalSince1970: 1_400),
                                      strainCycleStart: Date(timeIntervalSince1970: 1_000),
                                      strainCycleExpiresAt: Date(timeIntervalSince1970: 87_400),
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
                                      batteryCapturedAt: Date(timeIntervalSince1970: 1_490),
                                      batteryCorroboratedAt: Date(timeIntervalSince1970: 1_499),
                                      batteryChargeCapturedAt: Date(timeIntervalSince1970: 1_498),
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
        snapshot.displayCivilDay = Date(timeIntervalSince1970: 1_000)
        snapshot.displayCivilDayKey = "1970-01-01"
        snapshot.displayTimeZoneIdentifier = "Etc/UTC"
        snapshot.recoveryValueState = "currentCycle"
        snapshot.recoveryExpiresAt = Date(timeIntervalSince1970: 87_400)
        snapshot.sleepExpiresAt = Date(timeIntervalSince1970: 87_400)
        snapshot.whiteboardRows = [
            WidgetWhiteboardRow(id: "hrv", symbol: "waveform.path.ecg",
                                value: "48 ms", sentence: "Personal baseline",
                                tone: "supportive")
        ]
        snapshot.whiteboardExpiresAt = Date(timeIntervalSince1970: 87_400)
        snapshot.sleepNeedHours = 8.25
        snapshot.sleepFillFraction = 0.91
        snapshot.sleepFillAuthority = "nightlyNeed"
        snapshot.recoveryZone = "yellow"
        snapshot.hrvCapturedAt = Date(timeIntervalSince1970: 1_350)
        snapshot.biomarkerExpiresAt = Date(timeIntervalSince1970: 87_400)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        defaults.set(try encoder.encode(snapshot), forKey: "atria.widgetSnapshot.v1")

        WidgetSnapshotPublisher.invalidateBatteryProjection(defaults: defaults)

        let data = try XCTUnwrap(defaults.data(forKey: "atria.widgetSnapshot.v1"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sanitized = try decoder.decode(WidgetSnapshot.self, from: data)
        XCTAssertNil(sanitized.batteryLevel)
        XCTAssertNil(sanitized.batteryCapturedAt)
        XCTAssertNil(sanitized.batteryCorroboratedAt)
        XCTAssertNil(sanitized.batteryChargeCapturedAt)
        XCTAssertEqual(sanitized.batteryChargeStatus, "levelOnly")
        XCTAssertEqual(sanitized.batteryChargeText, "Unavailable")
        XCTAssertEqual(sanitized.recoveryPercent, 61)
        XCTAssertEqual(sanitized.strain, 4.2)
        XCTAssertEqual(sanitized.strainCapturedAt, snapshot.strainCapturedAt)
        XCTAssertEqual(sanitized.strainCycleStart, snapshot.strainCycleStart)
        XCTAssertEqual(sanitized.strainCycleExpiresAt, snapshot.strainCycleExpiresAt)
        XCTAssertEqual(sanitized.heartRate, 72)
        XCTAssertEqual(sanitized.heartRateCapturedAt, snapshot.heartRateCapturedAt)
        XCTAssertEqual(sanitized.heartRateZoneIndex, 1)
        XCTAssertEqual(sanitized.dailyStepGoal, 8_000)
        XCTAssertEqual(sanitized.displayCivilDay, snapshot.displayCivilDay)
        XCTAssertEqual(sanitized.displayCivilDayKey, snapshot.displayCivilDayKey)
        XCTAssertEqual(sanitized.displayTimeZoneIdentifier,
                       snapshot.displayTimeZoneIdentifier)
        XCTAssertEqual(sanitized.recoveryValueState, snapshot.recoveryValueState)
        XCTAssertEqual(sanitized.recoveryExpiresAt, snapshot.recoveryExpiresAt)
        XCTAssertEqual(sanitized.sleepExpiresAt, snapshot.sleepExpiresAt)
        XCTAssertEqual(sanitized.whiteboardRows, snapshot.whiteboardRows)
        XCTAssertEqual(sanitized.whiteboardExpiresAt, snapshot.whiteboardExpiresAt)
        XCTAssertEqual(sanitized.sleepNeedHours, snapshot.sleepNeedHours)
        XCTAssertEqual(sanitized.sleepFillFraction, snapshot.sleepFillFraction)
        XCTAssertEqual(sanitized.sleepFillAuthority, snapshot.sleepFillAuthority)
        XCTAssertEqual(sanitized.recoveryZone, snapshot.recoveryZone)
        XCTAssertEqual(sanitized.hrvCapturedAt, snapshot.hrvCapturedAt)
        XCTAssertEqual(sanitized.biomarkerExpiresAt, snapshot.biomarkerExpiresAt)
    }

    func testLiveWorkoutPatchChangesOnlyLiveWidgetFields() {
        let createdAt = Date(timeIntervalSince1970: 2_000)
        var current = WidgetSnapshot(schema: 4,
                                     createdAt: Date(timeIntervalSince1970: 1_000),
                                     recoveryPercent: 61,
                                     recoveryConfidence: "personal_baseline",
                                     recoveryDetail: "Saved morning recovery",
                                     strain: 4.2,
                                     strainDetail: "Partial · sparse HR",
                                     strainCapturedAt: Date(timeIntervalSince1970: 900),
                                     strainCycleStart: Date(timeIntervalSince1970: 500),
                                     strainCycleExpiresAt: Date(timeIntervalSince1970: 86_900),
                                     restingHR: 59,
                                     hrvRMSSD: 48,
                                     hrvState: "personal_baseline",
                                     maxHR: 190,
                                     sleepHours: 7.5,
                                     sleepDetail: "Review sleep",
                                     steps: 1_000,
                                     stepsCapturedAt: Date(timeIntervalSince1970: 990),
                                     stepsSource: "verifiedCanonical",
                                     stepsCompleteness: "partial",
                                     stepsCoverageFraction: 0.75,
                                     stepsCycleStart: Date(timeIntervalSince1970: 500),
                                     stepsCycleExpiresAt: Date(timeIntervalSince1970: 86_900),
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
        current.displayCivilDay = Date(timeIntervalSince1970: 500)
        current.displayCivilDayKey = "1970-01-01"
        current.displayTimeZoneIdentifier = "Etc/UTC"
        current.recoveryValueState = "currentCycle"
        current.recoveryExpiresAt = Date(timeIntervalSince1970: 86_900)
        current.sleepExpiresAt = Date(timeIntervalSince1970: 86_900)
        current.whiteboardRows = [
            WidgetWhiteboardRow(id: "hrv", symbol: "waveform.path.ecg",
                                value: "48 ms", sentence: "Personal baseline",
                                tone: "supportive")
        ]
        current.whiteboardExpiresAt = Date(timeIntervalSince1970: 86_900)
        current.sleepNeedHours = 8
        current.sleepFillFraction = 0.94
        current.sleepFillAuthority = "nightlyNeed"
        current.recoveryZone = "yellow"
        current.hrvCapturedAt = Date(timeIntervalSince1970: 800)
        current.biomarkerExpiresAt = Date(timeIntervalSince1970: 86_900)

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: createdAt,
            heartRate: 151,
            heartRateCapturedAt: Date(timeIntervalSince1970: 1_999),
            heartRateZoneIndex: 3,
            heartRateZoneName: "Aerobic",
            steps: 1_120,
            stepsAreEstimated: true,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_998),
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "partial",
            stepsCoverageFraction: 0.8,
            stepsAuthorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            strain: 6.8,
            batteryLevel: 43,
            batteryCapturedAt: Date(timeIntervalSince1970: 1_900),
            batteryCorroboratedAt: Date(timeIntervalSince1970: 1_997),
            batteryChargeCapturedAt: Date(timeIntervalSince1970: 1_996),
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
        XCTAssertEqual(patched.stepsSource, "verifiedCanonical")
        XCTAssertEqual(patched.stepsCompleteness, "partial")
        XCTAssertEqual(patched.stepsCoverageFraction, 0.8)
        XCTAssertEqual(
            patched.stepsAuthorityVersion,
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        )
        XCTAssertEqual(patched.stepsCycleStart, current.stepsCycleStart)
        XCTAssertEqual(patched.stepsCycleExpiresAt, current.stepsCycleExpiresAt)
        XCTAssertEqual(patched.dailyStepGoal, 8_000)
        XCTAssertEqual(patched.strain, 6.8)
        XCTAssertNil(patched.strainCapturedAt,
                     "a changed aggregate without explicit load evidence must fail closed")
        XCTAssertEqual(patched.strainCycleStart, current.strainCycleStart)
        XCTAssertEqual(patched.strainCycleExpiresAt, current.strainCycleExpiresAt)
        XCTAssertEqual(patched.batteryLevel, 43)
        XCTAssertEqual(patched.batteryCapturedAt, Date(timeIntervalSince1970: 1_900))
        XCTAssertEqual(patched.batteryCorroboratedAt, Date(timeIntervalSince1970: 1_997))
        XCTAssertEqual(patched.batteryChargeCapturedAt, Date(timeIntervalSince1970: 1_996))
        XCTAssertEqual(patched.recoveryPercent, current.recoveryPercent)
        XCTAssertEqual(patched.recoveryDetail, current.recoveryDetail)
        XCTAssertEqual(patched.strainDetail, current.strainDetail)
        XCTAssertEqual(patched.sleepDetail, current.sleepDetail)
        XCTAssertEqual(patched.hrvRMSSD, current.hrvRMSSD)
        XCTAssertEqual(patched.sleepHours, current.sleepHours)
        XCTAssertEqual(patched.layoutGlanceMetrics, current.layoutGlanceMetrics)
        XCTAssertEqual(patched.displayCivilDay, current.displayCivilDay)
        XCTAssertEqual(patched.displayCivilDayKey, current.displayCivilDayKey)
        XCTAssertEqual(patched.displayTimeZoneIdentifier,
                       current.displayTimeZoneIdentifier)
        XCTAssertEqual(patched.recoveryValueState, current.recoveryValueState)
        XCTAssertEqual(patched.recoveryExpiresAt, current.recoveryExpiresAt)
        XCTAssertEqual(patched.sleepExpiresAt, current.sleepExpiresAt)
        XCTAssertEqual(patched.whiteboardRows, current.whiteboardRows)
        XCTAssertEqual(patched.whiteboardExpiresAt, current.whiteboardExpiresAt)
        XCTAssertEqual(patched.sleepNeedHours, current.sleepNeedHours)
        XCTAssertEqual(patched.sleepFillFraction, current.sleepFillFraction)
        XCTAssertEqual(patched.sleepFillAuthority, current.sleepFillAuthority)
        XCTAssertEqual(patched.recoveryZone, current.recoveryZone)
        XCTAssertEqual(patched.hrvCapturedAt, current.hrvCapturedAt)
        XCTAssertEqual(patched.biomarkerExpiresAt, current.biomarkerExpiresAt)
    }

    func testDurableStepPatchAdvancesSameCountReceiptWithoutTouchingOtherMetrics()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let olderCapture = Date(timeIntervalSince1970: 1_800)
        let newerCapture = Date(timeIntervalSince1970: 2_100)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: olderCapture,
            heartRate: 151,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_050),
            strain: 8.4
        )
        current.strainDetail = "Partial · sparse HR"
        current.strainCapturedAt = Date(timeIntervalSince1970: 2_000)
        current.strainCycleStart = cycleStart
        current.strainCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.72
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = olderCapture
        current.batteryCapturedAt = Date(timeIntervalSince1970: 2_040)
        current.batteryCorroboratedAt = Date(timeIntervalSince1970: 2_045)
        current.batteryChargeCapturedAt = Date(timeIntervalSince1970: 2_030)

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: newerCapture,
                    steps: 1_976,
                    coverage: 0.81
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 1_976)
        XCTAssertEqual(patched.stepsCapturedAt, newerCapture)
        XCTAssertEqual(patched.stepsReceiptCapturedAt, newerCapture)
        XCTAssertEqual(patched.stepsCoverageFraction, 0.81)
        XCTAssertEqual(patched.heartRate, current.heartRate)
        XCTAssertEqual(
            patched.heartRateCapturedAt,
            current.heartRateCapturedAt
        )
        XCTAssertEqual(patched.recoveryPercent, current.recoveryPercent)
        XCTAssertEqual(patched.recoveryDetail, current.recoveryDetail)
        XCTAssertEqual(patched.strain, current.strain)
        XCTAssertEqual(patched.strainDetail, current.strainDetail)
        XCTAssertEqual(patched.strainCapturedAt, current.strainCapturedAt)
        XCTAssertEqual(patched.batteryLevel, current.batteryLevel)
        XCTAssertEqual(patched.batteryCapturedAt, current.batteryCapturedAt)
        XCTAssertEqual(
            patched.batteryCorroboratedAt,
            current.batteryCorroboratedAt
        )
        XCTAssertEqual(
            patched.layoutGlanceMetrics,
            current.layoutGlanceMetrics
        )
        XCTAssertEqual(
            patched.layoutRingCenterMetric,
            current.layoutRingCenterMetric
        )
    }

    func testDurableStepPatchRejectsOlderSameSourceReceipt() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_100),
            heartRate: 88,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_100)
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 2_100)

        XCTAssertNil(WidgetSnapshotPublisher.durableStepPatchedSnapshot(
            current: current,
            projection: durableProjection(
                source: source,
                cycleStart: cycleStart,
                receiptCapturedAt: Date(timeIntervalSince1970: 2_000),
                steps: 1_900
            ),
            currentPersistedSourceIdentifier: source,
            deliveredAt: Date(timeIntervalSince1970: 2_200)
        ))
    }

    func testDurableStepPatchRejectsOlderCycleEvenWithLaterClock() {
        let source = UUID().uuidString
        let currentCycle = Date(timeIntervalSince1970: 2_000)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_400),
            heartRate: 88,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_400)
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = currentCycle
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 2_400)

        XCTAssertNil(WidgetSnapshotPublisher.durableStepPatchedSnapshot(
            current: current,
            projection: durableProjection(
                source: source,
                cycleStart: Date(timeIntervalSince1970: 1_000),
                receiptCapturedAt: Date(timeIntervalSince1970: 2_600),
                steps: 2_100
            ),
            currentPersistedSourceIdentifier: source,
            deliveredAt: Date(timeIntervalSince1970: 2_700)
        ))
    }

    func testNewCycleWithoutReceiptClearsFormerCycleSteps() throws {
        let source = UUID().uuidString
        let oldCycle = Date(timeIntervalSince1970: 1_000)
        let newCycle = Date(timeIntervalSince1970: 86_400)
        var current = deliverySnapshot(
            steps: 3_200,
            stepsCapturedAt: Date(timeIntervalSince1970: 80_000),
            heartRate: 88,
            heartRateCapturedAt: Date(timeIntervalSince1970: 86_450)
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = oldCycle
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 80_000)

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: newCycle,
                    receiptCapturedAt: nil,
                    steps: nil
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 86_500)
            )
        )

        XCTAssertNil(patched.steps)
        XCTAssertEqual(patched.stepsReceiptCycleStart, newCycle)
        XCTAssertNil(patched.stepsReceiptCapturedAt)
        XCTAssertEqual(patched.heartRate, current.heartRate)
        XCTAssertEqual(
            patched.heartRateCapturedAt,
            current.heartRateCapturedAt
        )
    }

    func testDurableStepPatchRejectsDelayedFormerSource() {
        let currentSource = UUID().uuidString
        let formerSource = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let current = deliverySnapshot(
            steps: 700,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_800),
            heartRate: 80,
            heartRateCapturedAt: Date(timeIntervalSince1970: 1_800)
        )

        XCTAssertNil(WidgetSnapshotPublisher.durableStepPatchedSnapshot(
            current: current,
            projection: durableProjection(
                source: formerSource,
                cycleStart: cycleStart,
                receiptCapturedAt: Date(timeIntervalSince1970: 2_000),
                steps: 900
            ),
            currentPersistedSourceIdentifier: currentSource,
            deliveredAt: Date(timeIntervalSince1970: 2_100)
        ))
    }

    func testDurableStepPatchLetsCurrentReplacementSourceSupersedeOldClock()
        throws {
        let formerSource = UUID().uuidString
        let replacementSource = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        var current = deliverySnapshot(
            steps: 4_000,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_500),
            heartRate: 80,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_500)
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = formerSource
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 2_500)

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: replacementSource,
                    cycleStart: cycleStart,
                    receiptCapturedAt: Date(timeIntervalSince1970: 2_000),
                    steps: 300
                ),
                currentPersistedSourceIdentifier: replacementSource,
                deliveredAt: Date(timeIntervalSince1970: 2_600)
            )
        )

        XCTAssertEqual(patched.steps, 300)
        XCTAssertEqual(
            patched.stepsReceiptSourceIdentifier,
            replacementSource
        )
        XCTAssertEqual(
            patched.stepsReceiptCapturedAt,
            Date(timeIntervalSince1970: 2_000)
        )
    }

    func testLegacyExactStepsAreNotPreservedUnderReplacementReceiptSource()
        throws {
        let replacementSource = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        var legacyExact = deliverySnapshot(
            steps: 4_000,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_800),
            heartRate: 80,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_050)
        )
        legacyExact.stepsSource = "verifiedCanonical"
        legacyExact.stepsCompleteness = "complete"
        legacyExact.stepsCoverageFraction = 1
        legacyExact.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        legacyExact.stepsCycleStart = cycleStart
        legacyExact.stepsCycleExpiresAt =
            cycleStart.addingTimeInterval(86_400)
        XCTAssertNil(legacyExact.stepsReceiptSourceIdentifier)

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: legacyExact,
                projection: durableProjection(
                    source: replacementSource,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptAt,
                    steps: 300
                ),
                currentPersistedSourceIdentifier: replacementSource,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 300)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(
            patched.stepsReceiptSourceIdentifier,
            replacementSource
        )
        XCTAssertEqual(patched.stepsReceiptCapturedAt, receiptAt)
    }

    func testNewerUnresolvedDurableReceiptClearsOnlyOldStepProjection()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        var current = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_800),
            heartRate: 96,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_050),
            strain: 6.2
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 1_800)
        let newerReceipt = Date(timeIntervalSince1970: 2_100)

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: newerReceipt,
                    steps: nil
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertNil(patched.steps)
        XCTAssertNil(patched.stepsCapturedAt)
        XCTAssertNil(patched.stepsSource)
        XCTAssertNil(patched.stepsAuthorityVersion)
        XCTAssertEqual(patched.stepsReceiptCapturedAt, newerReceipt)
        XCTAssertEqual(patched.heartRate, current.heartRate)
        XCTAssertEqual(
            patched.heartRateCapturedAt,
            current.heartRateCapturedAt
        )
        XCTAssertEqual(patched.strain, current.strain)
        XCTAssertEqual(patched.batteryLevel, current.batteryLevel)
    }

    func testUnresolvedReceiptCannotOverrideExactCanonicalSteps() throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let exactCapturedAt = Date(timeIntervalSince1970: 1_800)
        let receiptCapturedAt = Date(timeIntervalSince1970: 2_100)
        var current = deliverySnapshot(
            steps: 2_450,
            stepsCapturedAt: exactCapturedAt,
            heartRate: 96,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_050)
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "complete"
        current.stepsCoverageFraction = 1
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = exactCapturedAt

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptCapturedAt,
                    steps: nil,
                    receiptInvalidatesIndependentPartial: true
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 2_450)
        XCTAssertEqual(patched.stepsCapturedAt, exactCapturedAt)
        XCTAssertEqual(patched.stepsCompleteness, "complete")
        XCTAssertEqual(patched.stepsCoverageFraction, 1)
        XCTAssertEqual(patched.stepsReceiptCapturedAt, receiptCapturedAt)
        XCTAssertNil(patched.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(
            patched.stepsReceiptContentRevision,
            String(repeating: "a", count: 64)
        )
        XCTAssertEqual(
            patched.stepsReceiptInvalidatesIndependentPartial,
            true
        )
    }

    func testOlderObservedMotionReceiptInvalidatesIndependentPartial()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_000)
        let currentAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 300,
            stepsCapturedAt: currentAt,
            heartRate: 96,
            heartRateCapturedAt: currentAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.8
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = currentAt
        current.stepsReceiptContentRevision = oldRevision
        current.stepsDisplayedReceiptContentRevision = nil

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptAt,
                    steps: nil,
                    receiptContentRevision: newRevision,
                    receiptInvalidatesIndependentPartial: true
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertNil(patched.steps)
        XCTAssertNil(patched.stepsCapturedAt)
        XCTAssertNil(patched.stepsCompleteness)
        XCTAssertNil(patched.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(patched.stepsReceiptContentRevision, newRevision)
        XCTAssertEqual(
            patched.stepsReceiptInvalidatesIndependentPartial,
            true
        )
        XCTAssertEqual(patched.heartRate, current.heartRate)
        XCTAssertEqual(patched.strain, current.strain)
        XCTAssertEqual(patched.batteryLevel, current.batteryLevel)
    }

    func testUnresolvedNewReceiptClearsOlderReceiptOwnedExactCount() throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 96,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "complete"
        current.stepsCoverageFraction = 1
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = oldRevision
        current.stepsDisplayedReceiptContentRevision = oldRevision

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptAt,
                    steps: nil,
                    receiptContentRevision: newRevision
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertNil(patched.steps)
        XCTAssertNil(patched.stepsCapturedAt)
        XCTAssertNil(patched.stepsCompleteness)
        XCTAssertNil(patched.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(patched.stepsReceiptContentRevision, newRevision)
    }

    func testLaterWeakerReceiptCannotOverrideIndependentPartialCount()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let currentAt = Date(timeIntervalSince1970: 2_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 300,
            stepsCapturedAt: currentAt,
            heartRate: 96,
            heartRateCapturedAt: currentAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.8
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = currentAt
        current.stepsReceiptContentRevision = String(
            repeating: "a",
            count: 64
        )
        current.stepsDisplayedReceiptContentRevision = nil

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptAt,
                    steps: 268,
                    coverage: 0.5,
                    receiptContentRevision: newRevision
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 300)
        XCTAssertEqual(patched.stepsCoverageFraction, 0.8)
        XCTAssertNil(patched.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(patched.stepsReceiptContentRevision, newRevision)
    }

    func testOlderStrongerReceiptReplacesIndependentPartialCount() throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_000)
        let currentAt = Date(timeIntervalSince1970: 2_100)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 268,
            stepsCapturedAt: currentAt,
            heartRate: 96,
            heartRateCapturedAt: currentAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.5
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = currentAt
        current.stepsReceiptContentRevision = String(
            repeating: "a",
            count: 64
        )
        current.stepsDisplayedReceiptContentRevision = nil

        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: durableProjection(
                    source: source,
                    cycleStart: cycleStart,
                    receiptCapturedAt: receiptAt,
                    steps: 300,
                    coverage: 0.8,
                    receiptContentRevision: newRevision
                ),
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 300)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(patched.stepsCoverageFraction, 0.8)
        XCTAssertEqual(
            patched.stepsDisplayedReceiptContentRevision,
            newRevision
        )
        XCTAssertEqual(patched.stepsReceiptContentRevision, newRevision)
    }

    func testCorrectedCompleteReceiptReplacesOlderExactCanonicalCount()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let correctedRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "complete"
        current.stepsCoverageFraction = 1
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = oldRevision
        current.stepsDisplayedReceiptContentRevision = oldRevision

        let corrected = WidgetSnapshotPublisher.DurableStepProjection(
            authorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            sourceIdentifier: source,
            cycleStart: cycleStart,
            cycleExpiresAt: cycleStart.addingTimeInterval(86_400),
            receiptCapturedAt: receiptAt,
            receiptContentRevision: correctedRevision,
            displayedReceiptContentRevision: correctedRevision,
            receiptInvalidatesIndependentPartial: false,
            steps: 1_976,
            stepsAreEstimated: false,
            stepsCapturedAt: receiptAt,
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "complete",
            stepsCoverageFraction: 1,
            priorCycleSteps: nil,
            priorCycleEndedAt: nil
        )
        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: corrected,
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 1_976)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(patched.stepsCompleteness, "complete")
        XCTAssertEqual(patched.stepsCoverageFraction, 1)
        XCTAssertEqual(
            patched.stepsReceiptContentRevision,
            correctedRevision
        )
        XCTAssertEqual(
            patched.stepsDisplayedReceiptContentRevision,
            correctedRevision
        )
    }

    func testCompleteReceiptCannotOverrideIndependentExactCanonicalCount()
        throws {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let correctedRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "complete"
        current.stepsCoverageFraction = 1
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsCycleExpiresAt = cycleStart.addingTimeInterval(86_400)
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = String(
            repeating: "a",
            count: 64
        )
        // Nil is the explicit provenance for an independently projected
        // canonical row rather than a displayed daily receipt.
        current.stepsDisplayedReceiptContentRevision = nil

        let receiptProjection = WidgetSnapshotPublisher.DurableStepProjection(
            authorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            sourceIdentifier: source,
            cycleStart: cycleStart,
            cycleExpiresAt: cycleStart.addingTimeInterval(86_400),
            receiptCapturedAt: receiptAt,
            receiptContentRevision: correctedRevision,
            displayedReceiptContentRevision: correctedRevision,
            receiptInvalidatesIndependentPartial: false,
            steps: 1_976,
            stepsAreEstimated: false,
            stepsCapturedAt: receiptAt,
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "complete",
            stepsCoverageFraction: 1,
            priorCycleSteps: nil,
            priorCycleEndedAt: nil
        )
        let patched = try XCTUnwrap(
            WidgetSnapshotPublisher.durableStepPatchedSnapshot(
                current: current,
                projection: receiptProjection,
                currentPersistedSourceIdentifier: source,
                deliveredAt: Date(timeIntervalSince1970: 2_200)
            )
        )

        XCTAssertEqual(patched.steps, 1_500)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(patched.stepsCompleteness, "complete")
        XCTAssertNil(patched.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(
            patched.stepsReceiptContentRevision,
            correctedRevision
        )
    }

    func testDelayedLivePatchCannotUndoNewerDurableReceipt() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: Date(timeIntervalSince1970: 2_200),
            heartRate: 112,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            steps: 1_500,
            stepsAreEstimated: false,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_000),
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "partial",
            stepsCoverageFraction: 0.7,
            stepsAuthorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            strain: current.strain,
            batteryLevel: current.batteryLevel,
            batteryChargeStatus: current.batteryChargeStatus ?? "levelOnly",
            batteryChargeText: current.batteryChargeText ?? "Unavailable"
        )

        XCTAssertEqual(patched.steps, 1_976)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(patched.stepsReceiptCapturedAt, receiptAt)
        XCTAssertEqual(patched.heartRate, 112)
    }

    func testLaterBroadPublishPreservesAlreadyDeliveredFresherSteps() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: Date(timeIntervalSince1970: 2_100),
            heartRate: 90,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_100)
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = Date(timeIntervalSince1970: 2_100)
        var staleBroad = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: Date(timeIntervalSince1970: 1_900),
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        staleBroad.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        staleBroad.stepsReceiptSourceIdentifier = source
        staleBroad.stepsReceiptCycleStart = cycleStart
        staleBroad.stepsReceiptCapturedAt =
            Date(timeIntervalSince1970: 1_900)

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: staleBroad,
                current: current
            )

        XCTAssertEqual(merged.steps, 1_976)
        XCTAssertEqual(
            merged.stepsReceiptCapturedAt,
            Date(timeIntervalSince1970: 2_100)
        )
        XCTAssertEqual(merged.heartRate, staleBroad.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            staleBroad.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, staleBroad.strain)
        XCTAssertEqual(merged.recoveryPercent, staleBroad.recoveryPercent)
        XCTAssertEqual(merged.batteryLevel, staleBroad.batteryLevel)
        XCTAssertEqual(
            merged.layoutGlanceMetrics,
            staleBroad.layoutGlanceMetrics
        )
    }

    func testCorrectedSameClockReceiptSurvivesDelayedBroadPublish() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let staleRevision = String(repeating: "a", count: 64)
        let correctedRevision = String(repeating: "b", count: 64)
        var corrected = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        corrected.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        corrected.stepsReceiptSourceIdentifier = source
        corrected.stepsReceiptCycleStart = cycleStart
        corrected.stepsReceiptCapturedAt = receiptAt
        corrected.stepsReceiptContentRevision = correctedRevision
        var staleBroad = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        staleBroad.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        staleBroad.stepsReceiptSourceIdentifier = source
        staleBroad.stepsReceiptCycleStart = cycleStart
        staleBroad.stepsReceiptCapturedAt = receiptAt
        staleBroad.stepsReceiptContentRevision = staleRevision

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: staleBroad,
                current: corrected,
                authoritativeReceiptContentRevision: correctedRevision
            )

        XCTAssertEqual(merged.steps, 1_976)
        XCTAssertEqual(merged.stepsCapturedAt, receiptAt)
        XCTAssertEqual(
            merged.stepsReceiptContentRevision,
            correctedRevision
        )
        XCTAssertEqual(merged.heartRate, staleBroad.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            staleBroad.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, staleBroad.strain)
    }

    func testNewDurableRevisionPreservesCurrentStepsWhenBothSnapshotsAreOld() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = oldRevision
        var staleBroad = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        staleBroad.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        staleBroad.stepsReceiptSourceIdentifier = source
        staleBroad.stepsReceiptCycleStart = cycleStart
        staleBroad.stepsReceiptCapturedAt = receiptAt
        staleBroad.stepsReceiptContentRevision = oldRevision

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: staleBroad,
                current: current,
                authoritativeReceiptContentRevision: newRevision
            )

        XCTAssertEqual(merged.steps, current.steps)
        XCTAssertEqual(merged.stepsCapturedAt, current.stepsCapturedAt)
        XCTAssertEqual(merged.stepsReceiptContentRevision, oldRevision)
        XCTAssertEqual(merged.heartRate, staleBroad.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            staleBroad.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, staleBroad.strain)
        XCTAssertEqual(merged.recoveryPercent, staleBroad.recoveryPercent)
        XCTAssertEqual(merged.batteryLevel, staleBroad.batteryLevel)
    }

    func testIndependentExactBroadRowSurvivesConcurrentReceiptCorrection() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var currentReceiptOwned = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        currentReceiptOwned.stepsSource = "verifiedCanonical"
        currentReceiptOwned.stepsCompleteness = "complete"
        currentReceiptOwned.stepsCoverageFraction = 1
        currentReceiptOwned.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentReceiptOwned.stepsCycleStart = cycleStart
        currentReceiptOwned.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentReceiptOwned.stepsReceiptSourceIdentifier = source
        currentReceiptOwned.stepsReceiptCycleStart = cycleStart
        currentReceiptOwned.stepsReceiptCapturedAt = receiptAt
        currentReceiptOwned.stepsReceiptContentRevision = oldRevision
        currentReceiptOwned.stepsDisplayedReceiptContentRevision = oldRevision

        var independentBroad = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        independentBroad.stepsSource = "verifiedCanonical"
        independentBroad.stepsCompleteness = "complete"
        independentBroad.stepsCoverageFraction = 1
        independentBroad.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        independentBroad.stepsCycleStart = cycleStart
        independentBroad.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        independentBroad.stepsReceiptSourceIdentifier = source
        independentBroad.stepsReceiptCycleStart = cycleStart
        independentBroad.stepsReceiptCapturedAt = receiptAt
        independentBroad.stepsReceiptContentRevision = oldRevision
        independentBroad.stepsDisplayedReceiptContentRevision = nil

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: independentBroad,
                current: currentReceiptOwned,
                authoritativeReceiptContentRevision: newRevision
            )

        XCTAssertEqual(merged.steps, 1_500)
        XCTAssertNil(merged.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(merged.heartRate, independentBroad.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            independentBroad.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, independentBroad.strain)
        XCTAssertEqual(
            merged.recoveryPercent,
            independentBroad.recoveryPercent
        )
        XCTAssertEqual(merged.batteryLevel, independentBroad.batteryLevel)
    }

    func testFreshIndependentExactBroadRowWinsWhenBothReceiptDigestsAreOld() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var currentIndependent = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        currentIndependent.stepsSource = "verifiedCanonical"
        currentIndependent.stepsCompleteness = "complete"
        currentIndependent.stepsCoverageFraction = 1
        currentIndependent.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentIndependent.stepsCycleStart = cycleStart
        currentIndependent.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentIndependent.stepsReceiptSourceIdentifier = source
        currentIndependent.stepsReceiptCycleStart = cycleStart
        currentIndependent.stepsReceiptCapturedAt = receiptAt
        currentIndependent.stepsReceiptContentRevision = oldRevision
        currentIndependent.stepsDisplayedReceiptContentRevision = nil

        var freshIndependent = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: receiptAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        freshIndependent.stepsSource = "verifiedCanonical"
        freshIndependent.stepsCompleteness = "complete"
        freshIndependent.stepsCoverageFraction = 1
        freshIndependent.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        freshIndependent.stepsCycleStart = cycleStart
        freshIndependent.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        freshIndependent.stepsReceiptSourceIdentifier = source
        freshIndependent.stepsReceiptCycleStart = cycleStart
        freshIndependent.stepsReceiptCapturedAt = receiptAt
        freshIndependent.stepsReceiptContentRevision = oldRevision
        freshIndependent.stepsDisplayedReceiptContentRevision = nil

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: freshIndependent,
                current: currentIndependent,
                authoritativeReceiptContentRevision: newRevision
            )

        XCTAssertEqual(merged.steps, 1_500)
        XCTAssertNil(merged.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(merged.heartRate, freshIndependent.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            freshIndependent.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, freshIndependent.strain)
        XCTAssertEqual(
            merged.recoveryPercent,
            freshIndependent.recoveryPercent
        )
        XCTAssertEqual(merged.batteryLevel, freshIndependent.batteryLevel)
    }

    func testOlderIndependentBroadRowCannotRegressNewerIndependentExact() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        let oldAt = Date(timeIntervalSince1970: 2_000)
        let newAt = Date(timeIntervalSince1970: 2_100)
        var currentIndependent = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: newAt,
            heartRate: 90,
            heartRateCapturedAt: newAt
        )
        currentIndependent.stepsSource = "verifiedCanonical"
        currentIndependent.stepsCompleteness = "complete"
        currentIndependent.stepsCoverageFraction = 1
        currentIndependent.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentIndependent.stepsCycleStart = cycleStart
        currentIndependent.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        currentIndependent.stepsReceiptSourceIdentifier = source
        currentIndependent.stepsReceiptCycleStart = cycleStart
        currentIndependent.stepsReceiptCapturedAt = newAt
        currentIndependent.stepsReceiptContentRevision = oldRevision
        currentIndependent.stepsDisplayedReceiptContentRevision = nil

        var olderIndependent = deliverySnapshot(
            steps: 1_500,
            stepsCapturedAt: oldAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        olderIndependent.stepsSource = "verifiedCanonical"
        olderIndependent.stepsCompleteness = "complete"
        olderIndependent.stepsCoverageFraction = 1
        olderIndependent.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        olderIndependent.stepsCycleStart = cycleStart
        olderIndependent.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        olderIndependent.stepsReceiptSourceIdentifier = source
        olderIndependent.stepsReceiptCycleStart = cycleStart
        olderIndependent.stepsReceiptCapturedAt = oldAt
        olderIndependent.stepsReceiptContentRevision = oldRevision
        olderIndependent.stepsDisplayedReceiptContentRevision = nil

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: olderIndependent,
                current: currentIndependent,
                authoritativeReceiptContentRevision: newRevision
            )

        XCTAssertEqual(merged.steps, 1_976)
        XCTAssertEqual(merged.stepsCapturedAt, newAt)
        XCTAssertNil(merged.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(merged.heartRate, olderIndependent.heartRate)
        XCTAssertEqual(
            merged.heartRateCapturedAt,
            olderIndependent.heartRateCapturedAt
        )
        XCTAssertEqual(merged.strain, olderIndependent.strain)
        XCTAssertEqual(
            merged.recoveryPercent,
            olderIndependent.recoveryPercent
        )
        XCTAssertEqual(merged.batteryLevel, olderIndependent.batteryLevel)
    }

    func testBroadIndependentPartialsPreferCoverageBeforeReceiptClock() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let revision = String(repeating: "b", count: 64)
        let olderAt = Date(timeIntervalSince1970: 2_000)
        let newerAt = Date(timeIntervalSince1970: 2_100)
        var current = deliverySnapshot(
            steps: 300,
            stepsCapturedAt: newerAt,
            heartRate: 90,
            heartRateCapturedAt: newerAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.8
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = newerAt
        current.stepsReceiptContentRevision = revision
        current.stepsDisplayedReceiptContentRevision = nil

        var candidate = deliverySnapshot(
            steps: 268,
            stepsCapturedAt: olderAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        candidate.stepsSource = "verifiedCanonical"
        candidate.stepsCompleteness = "partial"
        candidate.stepsCoverageFraction = 0.5
        candidate.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        candidate.stepsCycleStart = cycleStart
        candidate.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        candidate.stepsReceiptSourceIdentifier = source
        candidate.stepsReceiptCycleStart = cycleStart
        // Deliberately make the non-owning receipt metadata look newer than
        // the displayed candidate. It must not order independent partials.
        candidate.stepsReceiptCapturedAt = newerAt.addingTimeInterval(60)
        candidate.stepsReceiptContentRevision = revision
        candidate.stepsDisplayedReceiptContentRevision = nil

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: candidate,
                current: current,
                authoritativeReceiptContentRevision: revision
            )

        XCTAssertEqual(merged.steps, 300)
        XCTAssertEqual(merged.stepsCoverageFraction, 0.8)
        XCTAssertEqual(merged.stepsCapturedAt, newerAt)
        XCTAssertNil(merged.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(merged.heartRate, candidate.heartRate)
        XCTAssertEqual(merged.strain, candidate.strain)
        XCTAssertEqual(merged.recoveryPercent, candidate.recoveryPercent)
        XCTAssertEqual(merged.batteryLevel, candidate.batteryLevel)
    }

    func testEqualIndependentPartialAuthorityChoosesFreshBroadCandidate() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let revision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 300,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.8
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = revision
        current.stepsDisplayedReceiptContentRevision = nil

        var candidate = deliverySnapshot(
            steps: 301,
            stepsCapturedAt: receiptAt,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        candidate.stepsSource = "verifiedCanonical"
        candidate.stepsCompleteness = "partial"
        candidate.stepsCoverageFraction = 0.8
        candidate.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        candidate.stepsCycleStart = cycleStart
        candidate.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        candidate.stepsReceiptSourceIdentifier = source
        candidate.stepsReceiptCycleStart = cycleStart
        candidate.stepsReceiptCapturedAt = receiptAt
        candidate.stepsReceiptContentRevision = revision
        candidate.stepsDisplayedReceiptContentRevision = nil

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: candidate,
                current: current,
                authoritativeReceiptContentRevision: revision
            )

        XCTAssertEqual(merged.steps, 301)
        XCTAssertEqual(merged.stepsCoverageFraction, 0.8)
        XCTAssertNil(merged.stepsDisplayedReceiptContentRevision)
        XCTAssertEqual(merged.heartRate, candidate.heartRate)
        XCTAssertEqual(merged.strain, candidate.strain)
    }

    func testBroadUnresolvedMotionReceiptInvalidatesIndependentPartial() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let oldRevision = String(repeating: "a", count: 64)
        let newRevision = String(repeating: "b", count: 64)
        var current = deliverySnapshot(
            steps: 300,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        current.stepsSource = "verifiedCanonical"
        current.stepsCompleteness = "partial"
        current.stepsCoverageFraction = 0.8
        current.stepsAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsCycleStart = cycleStart
        current.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        current.stepsReceiptSourceIdentifier = source
        current.stepsReceiptCycleStart = cycleStart
        current.stepsReceiptCapturedAt = receiptAt
        current.stepsReceiptContentRevision = oldRevision
        current.stepsDisplayedReceiptContentRevision = nil

        var candidate = deliverySnapshot(
            steps: nil,
            stepsCapturedAt: nil,
            heartRate: 121,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            strain: 7.1
        )
        candidate.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        candidate.stepsReceiptSourceIdentifier = source
        candidate.stepsReceiptCycleStart = cycleStart
        candidate.stepsReceiptCapturedAt = receiptAt
        candidate.stepsReceiptContentRevision = newRevision
        candidate.stepsDisplayedReceiptContentRevision = nil
        candidate.stepsReceiptInvalidatesIndependentPartial = true

        let merged = WidgetSnapshotPublisher
            .snapshotPreservingFresherStepAuthority(
                candidate: candidate,
                current: current,
                authoritativeReceiptContentRevision: newRevision
            )

        XCTAssertNil(merged.steps)
        XCTAssertNil(merged.stepsCapturedAt)
        XCTAssertEqual(
            merged.stepsReceiptInvalidatesIndependentPartial,
            true
        )
        XCTAssertEqual(merged.heartRate, candidate.heartRate)
        XCTAssertEqual(merged.strain, candidate.strain)
        XCTAssertEqual(merged.recoveryPercent, candidate.recoveryPercent)
        XCTAssertEqual(merged.batteryLevel, candidate.batteryLevel)
    }

    func testCorrectedSameClockReceiptSurvivesDelayedLivePatchWhileHRAdvances() {
        let source = UUID().uuidString
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let receiptAt = Date(timeIntervalSince1970: 2_100)
        let correctedRevision = String(repeating: "b", count: 64)
        var corrected = deliverySnapshot(
            steps: 1_976,
            stepsCapturedAt: receiptAt,
            heartRate: 90,
            heartRateCapturedAt: receiptAt
        )
        corrected.stepsSource = "verifiedCanonical"
        corrected.stepsReceiptAuthorityVersion =
            WidgetSnapshotPublisher.qualifiedStepAuthorityVersion
        corrected.stepsReceiptSourceIdentifier = source
        corrected.stepsReceiptCycleStart = cycleStart
        corrected.stepsReceiptCapturedAt = receiptAt
        corrected.stepsReceiptContentRevision = correctedRevision

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: corrected,
            createdAt: Date(timeIntervalSince1970: 2_200),
            heartRate: 112,
            heartRateCapturedAt: Date(timeIntervalSince1970: 2_200),
            steps: 1_500,
            stepsAreEstimated: false,
            stepsCapturedAt: receiptAt,
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "partial",
            stepsCoverageFraction: 0.7,
            stepsAuthorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            strain: corrected.strain,
            batteryLevel: corrected.batteryLevel,
            batteryChargeStatus:
                corrected.batteryChargeStatus ?? "levelOnly",
            batteryChargeText:
                corrected.batteryChargeText ?? "Unavailable"
        )

        XCTAssertEqual(patched.steps, 1_976)
        XCTAssertEqual(patched.stepsCapturedAt, receiptAt)
        XCTAssertEqual(
            patched.stepsReceiptContentRevision,
            correctedRevision
        )
        XCTAssertEqual(patched.heartRate, 112)
        XCTAssertEqual(
            patched.heartRateCapturedAt,
            Date(timeIntervalSince1970: 2_200)
        )
    }

    func testAppLifetimeDependenciesOwnDurableStepReceiptPublication()
        throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Atria/AtriaApp.swift"),
            encoding: .utf8
        )
        let dependenciesStart = try XCTUnwrap(appSource.range(
            of: "private final class AtriaAppDependencies"
        ))
        let dependenciesEnd = try XCTUnwrap(appSource.range(
            of: "private final class AtriaBackgroundTaskCompletionGate",
            range: dependenciesStart.upperBound..<appSource.endIndex
        ))
        let dependencies = String(appSource[
            dependenciesStart.lowerBound..<dependenciesEnd.lowerBound
        ])

        XCTAssertTrue(dependencies.contains(
            "AtriaWhoop4MotionTickDailyStore.didSaveNotification"
        ))
        XCTAssertTrue(dependencies.contains(
            "WidgetSnapshotPublisher.scheduleDurableStepPatch("
        ))
        XCTAssertTrue(dependencies.contains(
            "NotificationCenter.default.removeObserver("
        ))
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
        XCTAssertNil(decoded.stepsSource)
        XCTAssertNil(decoded.stepsCompleteness)
        XCTAssertNil(decoded.stepsCoverageFraction)
        XCTAssertNil(
            decoded.stepsAuthorityVersion,
            "a pre-qualification widget payload must fail closed after update"
        )
        XCTAssertNil(decoded.stepsCycleStart)
        XCTAssertNil(decoded.stepsCycleExpiresAt)
        XCTAssertNil(decoded.stepsReceiptAuthorityVersion)
        XCTAssertNil(decoded.stepsReceiptSourceIdentifier)
        XCTAssertNil(decoded.stepsReceiptCycleStart)
        XCTAssertNil(decoded.stepsReceiptCapturedAt)
        XCTAssertNil(decoded.stepsReceiptContentRevision)
        XCTAssertNil(decoded.heartRateCapturedAt)
        XCTAssertNil(decoded.dailyStepGoal)
        XCTAssertNil(decoded.heartRateZoneIndex)
        XCTAssertNil(decoded.heartRateZoneName)
        XCTAssertNil(decoded.strainCapturedAt)
        XCTAssertNil(decoded.strainCycleStart)
        XCTAssertNil(decoded.strainCycleExpiresAt)
        XCTAssertNil(decoded.batteryChargeCapturedAt)
    }

    func testUnrelatedLivePatchPreservesCumulativeStrainClockAndCycle() {
        let capturedAt = Date(timeIntervalSince1970: 1_800)
        let cycleStart = Date(timeIntervalSince1970: 1_000)
        let cycleEnd = Date(timeIntervalSince1970: 87_400)
        var current = deliverySnapshot(steps: 100,
                                       stepsCapturedAt: capturedAt,
                                       heartRate: 70,
                                       heartRateCapturedAt: capturedAt,
                                       strain: 4.2)
        current.strainCapturedAt = capturedAt
        current.strainCycleStart = cycleStart
        current.strainCycleExpiresAt = cycleEnd

        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: capturedAt.addingTimeInterval(600),
            heartRate: 84,
            heartRateCapturedAt: capturedAt.addingTimeInterval(600),
            steps: 120,
            stepsAreEstimated: true,
            stepsCapturedAt: capturedAt.addingTimeInterval(600),
            strain: 4.2,
            batteryLevel: 40,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.strainCapturedAt, capturedAt)
        XCTAssertEqual(patched.strainCycleStart, cycleStart)
        XCTAssertEqual(patched.strainCycleExpiresAt, cycleEnd)
    }

    func testChangedCumulativeStrainUsesOnlyExplicitEvidenceClock() {
        let previousAt = Date(timeIntervalSince1970: 1_000)
        let evidenceAt = Date(timeIntervalSince1970: 1_500)
        XCTAssertEqual(WidgetSnapshotPublisher.cumulativeStrainCaptureDate(
            previousValue: 4.2,
            previousCapturedAt: previousAt,
            nextValue: 4.3,
            nextEvidenceAt: evidenceAt
        ), evidenceAt)
        XCTAssertNil(WidgetSnapshotPublisher.cumulativeStrainCaptureDate(
            previousValue: 4.2,
            previousCapturedAt: previousAt,
            nextValue: 4.3,
            nextEvidenceAt: nil
        ))
        XCTAssertEqual(WidgetSnapshotPublisher.cumulativeStrainCaptureDate(
            previousValue: 4.2,
            previousCapturedAt: previousAt,
            nextValue: 4.2,
            nextEvidenceAt: evidenceAt
        ), previousAt)
    }

    func testCumulativeStrainCycleCarriesBoundedCivilDayExpiry() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = calendar.date(from: DateComponents(year: 2026,
                                                       month: 11,
                                                       day: 1,
                                                       hour: 6))!
        let cycle = AtriaPhysiologicalCycle(start: start,
                                            boundaryKind: .initialFallback,
                                            anchorSleepID: nil,
                                            expectedInterval: 24 * 60 * 60)
        let expiry = WidgetSnapshotPublisher.cumulativeStrainCycleExpiration(
            cycle: cycle,
            confirmedSleeps: [],
            calendar: calendar
        )

        XCTAssertEqual(calendar.component(.hour, from: expiry), 6)
        XCTAssertEqual(calendar.dateComponents([.day], from: start, to: expiry).day, 1)
        XCTAssertGreaterThan(expiry, start)
        XCTAssertLessThanOrEqual(expiry.timeIntervalSince(start), 25 * 60 * 60)
    }

    func testStaticWidgetPinsSensorValuesToIndependentFreshnessClocks() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("var stepsCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("var stepsAreEstimated: Bool? = nil"))
        XCTAssertTrue(widgetSource.contains(
            "var stepsAuthorityVersion: String? = nil"
        ))
        XCTAssertTrue(widgetSource.contains(
            "snapshot.stepsAuthorityVersion"
        ))
        XCTAssertTrue(widgetSource.contains(
            "== atriaQualifiedStepAuthorityVersion"
        ))
        XCTAssertTrue(widgetSource.contains("let heartRateCapturedAt: Date?"))
        XCTAssertTrue(widgetSource.contains("var dailyStepGoal: Int? = nil"))
        XCTAssertTrue(widgetSource.contains("var heartRateZoneIndex: Int? = nil"))
        XCTAssertTrue(widgetSource.contains("var heartRateZoneName: String? = nil"))
        XCTAssertTrue(widgetSource.contains("var batteryCorroboratedAt: Date? = nil"))
        XCTAssertTrue(widgetSource.contains("var batteryChargeCapturedAt: Date? = nil"))
        XCTAssertTrue(widgetSource.contains("atriaBatteryEvidenceDate(snapshot)"))
        XCTAssertFalse(widgetSource.contains("private let atriaStaticSensorFreshness"),
                       "A generic 90-second cap must not shorten 10-minute battery truth")
        XCTAssertTrue(widgetSource.contains("private let atriaBatteryFreshness: TimeInterval = 10 * 60"))
        XCTAssertTrue(widgetSource.contains("private let atriaBatteryChargeFreshness: TimeInterval = 90"))
        XCTAssertTrue(widgetSource.contains("private let atriaStaticHeartRateFreshness: TimeInterval = 65"),
                      "Static Last HR must cover the bounded one-minute WidgetKit delivery cadence")
        XCTAssertTrue(widgetSource.contains("private let atriaLiveHeartRateFreshness: TimeInterval = 6"),
                      "Live Activity must retain the app's six-second HR authority")
        XCTAssertTrue(widgetSource.contains("private let atriaStaticStepFreshness: TimeInterval = 90"))
        XCTAssertTrue(widgetSource.contains("private let atriaLiveActivityStepFreshness: TimeInterval = 15"))
        XCTAssertTrue(widgetSource.contains("age <= freshness"))
        XCTAssertTrue(widgetSource.contains("atriaCurrentStepValue(s, now: now)"))
        XCTAssertTrue(widgetSource.contains("snapshot.stepsSource == \"verifiedCanonical\""))
        XCTAssertTrue(widgetSource.contains("freshness: atriaStaticStepFreshness"))
        XCTAssertTrue(widgetSource.contains("capturedAt: s.heartRateCapturedAt"))
        XCTAssertTrue(widgetSource.contains("freshness: atriaStaticHeartRateFreshness"))
        XCTAssertTrue(widgetSource.contains("(snapshot?.heartRateCapturedAt, atriaStaticHeartRateFreshness)"))
        XCTAssertTrue(widgetSource.contains(
            "expirySources.append((snapshot?.stepsCapturedAt, atriaStaticStepFreshness))"
        ))
        XCTAssertTrue(widgetSource.contains("(snapshot?.batteryChargeCapturedAt, atriaBatteryChargeFreshness)"))
        XCTAssertTrue(widgetSource.contains("capturedAt.addingTimeInterval(freshness + 0.001)"),
                      "The timeline must clear each sensor at its exact expiry boundary")
        XCTAssertFalse(widgetSource.contains("case .bpm:\n            return s.heartRate.map(String.init)"))
        XCTAssertTrue(widgetSource.contains("return \"HR stale · last \\(atriaCaptureTimeText(capturedAt))\""))
        XCTAssertTrue(widgetSource.contains("return \"Last reading · \\(zone) · \\(atriaCaptureTimeText(capturedAt))\""))
    }

    func testStaticCumulativeDayStrainDoesNotExpireWithLiveHeartRate() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains(
            "private let atriaCumulativeDayStrainFreshness: TimeInterval = 6 * 60 * 60"
        ))
        XCTAssertTrue(widgetSource.contains(
            "private let atriaActiveWorkoutStrainFreshness: TimeInterval = 90"
        ))
        XCTAssertTrue(widgetSource.contains(
            "guard atriaCumulativeDayStrainIsCurrent(s, now: now) else { return \"--\" }"
        ))
        XCTAssertTrue(widgetSource.contains(
            "let numeric = String(format: \"%.1f\", max(0, s.strain))"
        ))
        XCTAssertTrue(widgetSource.contains("? \"≥ \\(numeric)\""),
                      "partial cumulative strain must remain a visible lower bound")
        XCTAssertFalse(widgetSource.contains(
            "atriaFreshStaticSensorValue(s.strain"
        ), "an absent/stale live-HR clock must not blank cumulative day load")
        XCTAssertTrue(widgetSource.contains(
            "now.timeIntervalSince(capturedAt) <= atriaActiveWorkoutStrainFreshness"
        ), "active-workout strain must retain its strict sensor freshness gate")
        XCTAssertTrue(widgetSource.contains("let cycleStart = snapshot.strainCycleStart"))
        XCTAssertTrue(widgetSource.contains("let cycleExpiresAt = snapshot.strainCycleExpiresAt"))
        XCTAssertTrue(widgetSource.contains("now < cycleExpiresAt"))
        XCTAssertFalse(widgetSource.contains("snapshot.strainCapturedAt ?? snapshot.createdAt"))
    }

    func testEveryStaticWidgetStrainSurfaceUsesCycleAndEvidenceGate() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widgetSource = try String(contentsOf: root
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains(
            "if AtriaWidgetMetric.strain.value(entry.snapshot, now: entry.date) != \"--\""
        ), "system-small strain must use the cycle/timestamp gate")
        XCTAssertTrue(widgetSource.contains(
            "\"Strain \\(AtriaWidgetMetric.strain.value(entry.snapshot, now: entry.date))\""
        ), "accessory rectangular strain must use the same gate")
        // Migrated 2026-08-14 (§13.6): accessory inline no longer surfaces
        // strain — it speaks the whiteboard's HRV/RHR strings. The invariant
        // ("no ungated strain") holds vacuously there; pin the replacement so
        // a future strain re-introduction must come back through the gate.
        XCTAssertTrue(widgetSource.contains(
            "private var inlineText: String"
        ))
        let inlineStart = try XCTUnwrap(widgetSource.range(of: "private var inlineText: String"))
        let inlineEnd = try XCTUnwrap(widgetSource.range(of: "private var largeFooterText: String",
                                                          range: inlineStart.upperBound..<widgetSource.endIndex))
        let inlineBody = String(widgetSource[inlineStart.lowerBound..<inlineEnd.lowerBound])
        XCTAssertTrue(inlineBody.contains("whiteboardRowValue(\"hrv\")"),
                      "inline leads with the whiteboard's measured numbers")
        XCTAssertFalse(inlineBody.contains(".strain"),
                       "inline must not surface strain without the cycle/evidence gate")
        XCTAssertFalse(widgetSource.contains(
            "entry.snapshot.map { String(format: \"%.1f\", $0.strain) }"
        ))
        XCTAssertFalse(widgetSource.contains(
            "String(format: \"%.1f\", snapshot.strain)"
        ))
        XCTAssertTrue(widgetSource.contains("now < cycleExpiresAt"),
                      "all routed surfaces must expire at the physiological-cycle boundary")
    }

    func testStaticBatteryChargePresentationExpiresIndependently() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widgetSource = try String(contentsOf: root
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)
        let appSource = try String(contentsOf: root
            .appendingPathComponent("Atria/WidgetSnapshot.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("atriaFreshBatteryChargeStatus(snapshot, now: entry.date)"))
        XCTAssertTrue(widgetSource.contains("capturedAt: snapshot.batteryChargeCapturedAt"))
        XCTAssertFalse(widgetSource.contains("snapshot.batteryChargeStatus == \"charging\""))
        XCTAssertFalse(widgetSource.contains("snapshot.batteryChargeStatus == \"full\""))
        XCTAssertTrue(appSource.contains("var batteryChargeCapturedAt: Date? = nil"))
        XCTAssertTrue(appSource.contains(
            "previous.batteryChargeCapturedAt != snapshot.batteryChargeCapturedAt"
        ), "charge-clock changes need their own trailing widget reload")
    }

    func testPreliminaryStrapStepsRemainPublishableButNeverValidated() {
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_preliminary"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_preliminary"))
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_validated"))
        XCTAssertTrue(WidgetSnapshotPublisher.strapStepsAreValidated(state: "r10_live_validated"))
        XCTAssertFalse(WidgetSnapshotPublisher.strapStepsArePublishable(state: "r10_live_calibrating"))
    }

    func testWidgetDailyStepResolverUsesSameStrapOnlyPolicyAsHome() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let strapValue = WidgetSnapshotPublisher.resolvedDailySteps(
            day: now,
            now: now,
            liveCount: 612,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now,
            calendar: calendar
        )
        XCTAssertNil(strapValue.count)
        XCTAssertEqual(strapValue.source, .none)
        XCTAssertFalse(strapValue.isValidated)
        XCTAssertEqual(strapValue.detailText, "Strap motion is still validating")

        let strapWins = WidgetSnapshotPublisher.resolvedDailySteps(
            day: now,
            now: now,
            liveCount: 4_000,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now,
            calendar: calendar
        )
        XCTAssertNil(strapWins.count)
        XCTAssertEqual(strapWins.source, .none)
        XCTAssertFalse(strapWins.isValidated)
    }

    func testWidgetResolverUsesPartialCanonicalWhenLiveEvidenceIsStale() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let now = day.addingTimeInterval(3_600)
        let canonical = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-05-18",
            dayStart: calendar.startOfDay(for: day),
            dayEnd: now,
            state: .missing,
            stepCount: nil,
            knownStepDeltaSum: 2_345,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 2_700,
            missingCoverageSeconds: 900
        )

        let value = WidgetSnapshotPublisher.resolvedDailySteps(
            day: day,
            now: now,
            liveCount: 9_999,
            liveValidationState: "r10_live_preliminary",
            liveCapturedAt: now.addingTimeInterval(
                -AtriaDailyStepPresentation.liveEvidenceMaximumAge - 1
            ),
            canonicalDays: [canonical],
            calendar: calendar
        )

        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.completeness, .partial)
        // Pin migrated 2026-08-05: clean number per the 26057206 decision;
        // partiality is pinned by .partial + coverageFraction below.
        XCTAssertEqual(value.valueText, "2345")
        XCTAssertEqual(value.coverageFraction ?? -1, 0.75, accuracy: 0.001)
    }

    func testWidgetResolverPublishesCompleteCanonicalExactly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 2_000_000_000)
        let dayStart = calendar.startOfDay(for: day)
        let canonical = AtriaHistoricalDailyConsumerProjection.StepDay(
            localDay: "2033-05-18",
            dayStart: dayStart,
            dayEnd: dayStart.addingTimeInterval(86_400),
            state: .available,
            stepCount: 8_412,
            knownStepDeltaSum: 8_412,
            knownEpochCount: 1,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: 86_400,
            missingCoverageSeconds: 0
        )

        let value = WidgetSnapshotPublisher.resolvedDailySteps(
            day: dayStart,
            now: dayStart.addingTimeInterval(2 * 86_400),
            liveCount: 0,
            liveValidationState: "unavailable",
            liveCapturedAt: nil,
            canonicalDays: [canonical],
            calendar: calendar
        )

        XCTAssertEqual(value.source, .verifiedCanonical)
        XCTAssertEqual(value.completeness, .complete)
        XCTAssertEqual(value.valueText, "8412")
    }

    func testStaticStepsWidgetMarksPreliminaryCountsAsEstimated() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetSource = try String(contentsOf: testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift"), encoding: .utf8)

        XCTAssertTrue(widgetSource.contains("snapshot.stepsSource == \"verifiedCanonical\""))
        XCTAssertTrue(widgetSource.contains("return \"≥\\(value)\""))
        XCTAssertTrue(widgetSource.contains("return \"Verified complete day\""))
        XCTAssertTrue(widgetSource.contains(
            ": \"Verified through \\(atriaCaptureTimeText(capturedAt))\""
        ))
        // 2026-08-12: the partial tile leads with the capture frontier —
        // "Counted · through <time> · N% goal" — never a coverage percent
        // (which read as bad step detection).
        XCTAssertTrue(widgetSource.contains("[\"Counted\", frontier, progress]"))
        XCTAssertFalse(widgetSource.contains("% covered"))
        XCTAssertTrue(widgetSource.contains("snapshot.stepsAreEstimated == false"),
                      "only explicit validated provenance may claim exact steps or goal completion")
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

    func testLegacySnapshotDecodesWithoutBatteryOrStrainClocks() throws {
        let legacy = """
        {"schema":4,"createdAt":"2026-07-15T00:00:00Z","recoveryPercent":61,
        "recoveryConfidence":"saved","recoveryDetail":"Saved","strain":4.2,
        "restingHR":59,"hrvRMSSD":48,"hrvState":"saved","maxHR":190,
        "storage":"test","appGroupEnabled":true,"widgetTargetPresent":true,
        "complicationTargetPresent":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder.widgetSnapshotDecoder.decode(WidgetSnapshot.self, from: legacy)
        XCTAssertNil(decoded.batteryCapturedAt)
        XCTAssertNil(decoded.batteryCorroboratedAt)
        XCTAssertNil(decoded.batteryChargeCapturedAt)
        XCTAssertNil(decoded.strainCapturedAt)
        XCTAssertNil(decoded.strainCycleStart)
        XCTAssertNil(decoded.strainCycleExpiresAt)
        XCTAssertNil(decoded.strainDetail)
        XCTAssertNil(decoded.sleepDetail)
    }

    func testEvidenceQualifierTransitionReloadsWidgetImmediately() {
        let now = Date(timeIntervalSince1970: 70_000)
        var previous = deliverySnapshot(steps: nil,
                                        stepsCapturedAt: nil,
                                        heartRate: nil,
                                        heartRateCapturedAt: nil)
        previous.strainDetail = "Current cycle"
        previous.sleepDetail = "Confirmed sleep"
        var partial = previous
        partial.strainDetail = "Partial · sparse HR"
        partial.sleepDetail = "Review sleep"

        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous,
            lastReloadAt: now,
            snapshot: partial,
            now: now.addingTimeInterval(1)
        ), 0)
    }

    func testLiveStrainPatchCannotUpgradePartialCoverageFromValueAlone() {
        let now = Date(timeIntervalSince1970: 80_000)
        var current = deliverySnapshot(steps: nil,
                                       stepsCapturedAt: nil,
                                       heartRate: nil,
                                       heartRateCapturedAt: nil,
                                       strain: 0.4)
        current.strainDetail = "Partial · sparse HR"

        func patch(strain: Double) -> WidgetSnapshot {
            WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
                current: current,
                createdAt: now,
                heartRate: 120,
                heartRateCapturedAt: now,
                steps: nil,
                stepsAreEstimated: true,
                stepsCapturedAt: nil,
                strain: strain,
                strainCapturedAt: now,
                batteryLevel: nil,
                batteryChargeStatus: "levelOnly",
                batteryChargeText: "Unavailable"
            )
        }

        XCTAssertEqual(patch(strain: 0.8).strainDetail, "Partial · sparse HR")
        XCTAssertEqual(patch(strain: 1.2).strainDetail, "Partial · sparse HR",
                       "a larger live value is not proof that sparse day coverage became complete")
        XCTAssertEqual(
            WidgetSnapshotPublisher.mergedLiveStrainDetail(
                previous: "Partial · 21% wear",
                next: "local"
            ),
            "Partial · 21% wear",
            "a pulse patch cannot upgrade partial all-day authority even when its caller supplies an exact label"
        )
        XCTAssertEqual(
            WidgetSnapshotPublisher.mergedLiveStrainDetail(
                previous: "Current cycle",
                next: "local · partial-day wear"
            ),
            "local · partial-day wear",
            "a pulse patch may conservatively downgrade authority"
        )
    }

    func testIndependentBatteryAndStrainClocksTriggerTrailingReload() {
        let now = Date(timeIntervalSince1970: 50_000)
        var previous = deliverySnapshot(steps: nil, stepsCapturedAt: nil,
                                        heartRate: nil, heartRateCapturedAt: nil)
        previous.batteryCapturedAt = now
        previous.batteryCorroboratedAt = now
        previous.batteryChargeCapturedAt = now
        previous.strainCapturedAt = now
        var current = previous
        current.batteryCapturedAt = now.addingTimeInterval(1)
        current.batteryCorroboratedAt = now.addingTimeInterval(1)
        current.batteryChargeCapturedAt = now.addingTimeInterval(1)
        current.strainCapturedAt = now.addingTimeInterval(1)
        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: previous, lastReloadAt: now, snapshot: current, now: now
        ), 60)
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

    func testMissingStepProvenanceTransitionsIntoEstimatedLane() {
        let reloadedAt = Date(timeIntervalSince1970: 45_000)
        let validated = deliverySnapshot(steps: 2_400,
                                         stepsCapturedAt: reloadedAt,
                                         heartRate: 90,
                                         heartRateCapturedAt: reloadedAt)
        var missing = validated
        missing.stepsAreEstimated = nil

        XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: validated,
            lastReloadAt: reloadedAt,
            snapshot: missing,
            now: reloadedAt.addingTimeInterval(1)
        ), 0, "losing explicit validation must immediately remove exact-step claims")

        var estimated = missing
        estimated.stepsAreEstimated = true
        XCTAssertNil(WidgetSnapshotPublisher.timelineReloadDelay(
            previous: missing,
            lastReloadAt: reloadedAt,
            snapshot: estimated,
            now: reloadedAt.addingTimeInterval(1)
        ), "nil and true both belong to the same fail-closed estimated lane")
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

    private func durableProjection(
        source: String,
        cycleStart: Date,
        receiptCapturedAt: Date?,
        steps: Int?,
        coverage: Double = 0.75,
        receiptContentRevision: String? = nil,
        receiptInvalidatesIndependentPartial: Bool = false
    ) -> WidgetSnapshotPublisher.DurableStepProjection {
        .init(
            authorityVersion:
                WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            sourceIdentifier: source,
            cycleStart: cycleStart,
            cycleExpiresAt: cycleStart.addingTimeInterval(86_400),
            receiptCapturedAt: receiptCapturedAt,
            receiptContentRevision: receiptCapturedAt == nil
                ? nil
                : (receiptContentRevision
                    ?? String(repeating: "a", count: 64)),
            displayedReceiptContentRevision: steps == nil
                ? nil
                : (receiptContentRevision
                    ?? String(repeating: "a", count: 64)),
            receiptInvalidatesIndependentPartial:
                receiptInvalidatesIndependentPartial,
            steps: steps,
            stepsAreEstimated: steps == nil ? nil : true,
            stepsCapturedAt: steps == nil ? nil : receiptCapturedAt,
            stepsSource: steps == nil ? nil : "verifiedCanonical",
            stepsCompleteness: steps == nil ? nil : "partial",
            stepsCoverageFraction: steps == nil ? nil : coverage,
            priorCycleSteps: nil,
            priorCycleEndedAt: nil
        )
    }

    func testWidgetStrainCredibilityGateWithholdsClockWithoutRestEvidence() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/WidgetSnapshot.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        // 2026-07-31: 81eea260 renamed the raw label to baseStrainConfidence
        // and routed it through the Metrics.StrainPresentation authority; the
        // credibility gate reads the resolved confidence, not the raw one.
        let confidence = try XCTUnwrap(source.range(
            of: "let baseStrainConfidence = AtriaHomeModel.strainConfidence("
        ))
        let resolved = try XCTUnwrap(source.range(
            of: "let strainPresentation = Metrics.StrainPresentation.resolve("
        ))
        let gate = try XCTUnwrap(source.range(
            of: "let strainIsCredible =\n            !strainConfidence.localizedCaseInsensitiveContains(\"learning\")"
        ))
        let captured = try XCTUnwrap(source.range(
            of: "strainCapturedAt: strainIsCredible ? now : nil"
        ))
        XCTAssertLessThan(confidence.lowerBound, resolved.lowerBound)
        XCTAssertLessThan(resolved.lowerBound, gate.lowerBound)
        XCTAssertLessThan(gate.lowerBound, captured.lowerBound)
        // All three clock fields gate together: the widget's freshness guard
        // requires the full set, so a partial gate would leak a confident 0.0.
        XCTAssertTrue(source.contains("strainCycleStart: strainIsCredible ? physiologicalCycle.start : nil"))
        XCTAssertTrue(source.contains("strainCycleExpiresAt: strainIsCredible ? strainCycleExpiresAt : nil"))
    }

    func testWidgetPreservesDayOneRecoveryMissingHRVDisclosure() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(source.contains(
            "snapshot.recoveryDetail.localizedCaseInsensitiveContains(\"HRV unavailable\")"
        ))
        // 2026-07-27: the disclaimer keeps its SPECIFIC half only. Paired with
        // the score, "Recovery 46% · Limited confidence · HRV unavailable" ran
        // past the medium widget's secondary line and rendered as "Recovery
        // 46% · Limited…", dropping the very evidence this assertion protects.
        XCTAssertTrue(source.contains(
            "return \"HRV unavailable\""
        ))
        // 2026-08-14 pin migration (assessment P0.3): the footer routes
        // through displayRecoveryEvidence so legacy "validated" snapshots
        // render as personal baseline; the missing-HRV disclosure survives
        // via its default branch.
        XCTAssertTrue(source.contains(
            "return \"Recovery \\(recovery)% · \\(displayRecoveryEvidence(snapshot))\""
        ), "a numeric day-one score and its missing-HRV disclosure must travel together")
    }

    func testWidgetShowsReviewSleepAndPartialStrainEvidenceNotes() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let widgetURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let widget = try String(contentsOf: widgetURL, encoding: .utf8)
        let publisherURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/WidgetSnapshot.swift")
        let publisher = try String(contentsOf: publisherURL, encoding: .utf8)

        // Handoff-10 CP1: sleep hours publish only when the wake falls on the
        // snapshot's display civil day; otherwise the widget carries the
        // awaiting state instead of a prior night under today's label.
        XCTAssertTrue(publisher.contains("sleepHours: widgetSleepIsCurrentDay"))
        XCTAssertTrue(publisher.contains("? latestDisplaySleep?.durationHours"))
        XCTAssertTrue(publisher.contains("? \"Review nap\" : \"Review sleep\""))
        XCTAssertTrue(publisher.contains("AtriaCurrentDayPresentation.awaitingCurrentSleepDetail"))
        XCTAssertTrue(publisher.contains("strainConfidence.localizedCaseInsensitiveContains(\"partial\")"))
        // 2026-07-31: 81eea260 moved the percent disclosure into the shared
        // StrainPresentation.coverageText with the sparse-HR fallback kept in
        // the publisher. 2026-08-12: the word is "tracked" — "covered" read
        // as the strap detecting wrongly.
        XCTAssertTrue(publisher.contains("strainPresentation.coverageText ?? \"Partial · sparse HR\""))
        let metricsURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/Metrics.swift")
        let metrics = try String(contentsOf: metricsURL, encoding: .utf8)
        XCTAssertTrue(metrics.contains(
            "\"Partial · \\(Int((coverageFraction * 100).rounded()))% tracked\""
        ), "the partial percent disclosure must survive in the shared authority")
        XCTAssertTrue(widget.contains("snapshot.strainDetail ?? \"Updated"))
        XCTAssertTrue(widget.contains("? \"≥ \\(numeric)\""))
        XCTAssertTrue(widget.contains("sleepDetail.localizedCaseInsensitiveContains(\"review\")"))
        XCTAssertTrue(widget.contains("evidenceNote: metric.evidenceNote(entry.snapshot)"))
    }

    func testWidgetFrozenRecoveryAtomicallyOverridesProvisionalProjection() throws {
        let provisional = Metrics.RecoveryEstimate(
            percent: 42,
            confidence: .unverified,
            usesHRV: false,
            detail: "provisional live recompute",
            contributors: []
        )
        let frozen = try XCTUnwrap(FrozenRecoverySummary(
            estimate: Metrics.RecoveryEstimate(
                percent: 39,
                confidence: .personalBaseline,
                usesHRV: true,
                detail: "frozen morning recovery",
                contributors: []
            ),
            scoredDay: Date(timeIntervalSince1970: 1_722_096_000)
        ))

        let resolved = WidgetSnapshotPublisher.canonicalRecovery(
            displayed: provisional,
            frozen: frozen
        )

        XCTAssertEqual(resolved.percent, 39)
        XCTAssertEqual(resolved.confidence, .personalBaseline)
        XCTAssertEqual(resolved.detail, "frozen morning recovery")
        XCTAssertTrue(resolved.usesHRV)
    }

    func testAggregateHomeWidgetUsesBothStaticMediumRingLayoutsWithoutMigratingKind() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let entryStart = try XCTUnwrap(source.range(of: "struct AtriaWidgetEntryView: View"))
        let entryEnd = try XCTUnwrap(source.range(of: "private enum AtriaDailyOverviewMetric"))
        let aggregate = String(source[entryStart.lowerBound..<entryEnd.lowerBound])

        XCTAssertEqual(
            source.components(separatedBy: "StaticConfiguration(kind: \"AtriaWidget\"").count - 1,
            1,
            "the installed aggregate widget kind must remain a single StaticConfiguration"
        )
        XCTAssertEqual(
            source.components(separatedBy: "StaticConfiguration(kind: \"AtriaSeparateOverviewWidget\"").count - 1,
            1,
            "the separate layout needs one permanent, distinct static kind"
        )
        XCTAssertFalse(source.contains("AppIntentConfiguration(kind: \"AtriaWidget\""),
                       "migrating the installed kind to an intent can strand existing widgets")
        XCTAssertTrue(source.contains(
            "AtriaWidgetEntryView(entry: entry, mediumOverviewLayout: .concentric)"
        ))
        XCTAssertTrue(source.contains(
            "AtriaWidgetEntryView(entry: entry, mediumOverviewLayout: .separate)"
        ))
        let separateStart = try XCTUnwrap(source.range(of: "struct AtriaSeparateOverviewWidget: Widget"))
        let separateEnd = try XCTUnwrap(source.range(
            of: "#if DEBUG",
            range: separateStart.upperBound..<source.endIndex
        ))
        let separateWidget = String(source[separateStart.lowerBound..<separateEnd.lowerBound])
        XCTAssertTrue(separateWidget.contains(".supportedFamilies([.systemMedium])"))

        let bundleStart = try XCTUnwrap(source.range(of: "struct AtriaWidgetBundle: WidgetBundle"))
        let bundle = String(source[bundleStart.lowerBound...])
        XCTAssertEqual(bundle.components(separatedBy: "AtriaSeparateOverviewWidget()").count - 1, 1)

        XCTAssertTrue(aggregate.contains("private var concentricMediumOverview"))
        XCTAssertTrue(aggregate.contains("private var separateMediumOverview"))
        XCTAssertTrue(aggregate.contains("ForEach(AtriaDailyOverviewMetric.allCases)"),
                      "Sleep, Recovery, and Strain must keep an always-visible legend")
        XCTAssertGreaterThanOrEqual(
            aggregate.components(separatedBy: "ViewThatFits(in: .vertical)").count - 1,
            3,
            "Small, standard Medium, and accessibility Medium each need a constrained fallback"
        )
        XCTAssertTrue(aggregate.contains("dailyOverviewTextLayout(compact: true)"),
                      "Medium needs a deterministic terminal text fallback")

        let standardStart = try XCTUnwrap(aggregate.range(of: "private var standardMediumWidget"))
        let standardEnd = try XCTUnwrap(aggregate.range(
            of: "private var recoveryOnlyWidget",
            range: standardStart.upperBound..<aggregate.endIndex
        ))
        let medium = String(aggregate[standardStart.lowerBound..<standardEnd.lowerBound])
        XCTAssertFalse(medium.contains("widgetHeader"))
        XCTAssertFalse(medium.contains("Text(\"Atria\")"),
                       "the medium daily overview must reclaim the old visible title row")
        XCTAssertFalse(medium.contains(".background("),
                       "rings and legend stay flat on WidgetKit's one calm background")
    }

    func testAggregateDailyRingsKeepRecoveryStrainAndSleepTruthVisible() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let helperStart = try XCTUnwrap(source.range(of: "private func dailyValue"))
        let helperEnd = try XCTUnwrap(source.range(
            of: "private var recoveryOnlyWidget",
            range: helperStart.upperBound..<source.endIndex
        ))
        let helpers = String(source[helperStart.lowerBound..<helperEnd.lowerBound])
        let ringStart = try XCTUnwrap(source.range(of: "private enum AtriaDailyOverviewMetric"))
        let ringEnd = try XCTUnwrap(source.range(of: "private struct AtriaWidgetRecoveryGauge"))
        let rings = String(source[ringStart.lowerBound..<ringEnd.lowerBound])

        XCTAssertTrue(source.contains(
            "private enum AtriaDailyOverviewMetric: String, CaseIterable, Identifiable {\n    case sleep\n    case recovery\n    case strain"
        ), "widget order must match AtriaTriRingSlot.defaultOrder")
        XCTAssertTrue(rings.contains("AtriaWidgetDailyRing(presentation: sleep"))
        XCTAssertTrue(rings.contains(".frame(width: 88, height: 88)"),
                      "Sleep is the outer concentric ring")
        XCTAssertTrue(helpers.contains(
            "AtriaWidgetMetric.strain.value(snapshot, now: entry.date) != \"--\""
        ), "Strain must use its cycle and evidence clock before any fill")
        XCTAssertTrue(helpers.contains("return .partial"))
        XCTAssertTrue(rings.contains("dash: [5, 4]"),
                      "partial Strain is a non-completion dashed rail")
        XCTAssertTrue(helpers.contains("snapshot.strain / 21"),
                      "only current complete Strain may use its real 0...21 scale")
        XCTAssertTrue(helpers.contains("return .presence"))
        XCTAssertTrue(rings.contains("dash: [1, 4]"),
                      "Sleep duration is presence-only without personal need")
        XCTAssertFalse(helpers.contains("sleepHours / 8"))
        XCTAssertFalse(helpers.contains("sleepHours / 12"))
        XCTAssertTrue(helpers.contains("return displayRecoveryEvidence(snapshot)"))
        XCTAssertTrue(helpers.contains("return detail"),
                      "Confirmed and Review sleep provenance must remain visible")
        XCTAssertTrue(helpers.contains("guard let snapshot = entry.snapshot else { return \"Learning\" }"))
        XCTAssertTrue(source.contains("return \"Widget updated"),
                      "createdAt may only describe generic widget delivery")
        XCTAssertFalse(helpers.contains("Recovery updated"))
        XCTAssertFalse(helpers.contains("Sleep updated"))
        XCTAssertTrue(source.contains("#Preview(\"Daily Overview · Concentric\""))
        XCTAssertTrue(source.contains("#Preview(\"Daily Overview · Separate · Partial\""))
        XCTAssertTrue(source.contains("sleepDetail: \"Review sleep\""))
        XCTAssertTrue(source.contains("strainDetail: \"Partial · 52% tracked\""))
    }

    func testSeparateDailyRingsUseTheMediumHeightWithoutCompressingEvidence() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let overviewStart = try XCTUnwrap(source.range(of: "private var separateMediumOverview"))
        let overviewEnd = try XCTUnwrap(source.range(
            of: "private var accessibleMediumWidget",
            range: overviewStart.upperBound..<source.endIndex
        ))
        let overview = String(source[overviewStart.lowerBound..<overviewEnd.lowerBound])
        let ringStart = try XCTUnwrap(source.range(of: "private func dailySeparateRing"))
        let ringEnd = try XCTUnwrap(source.range(
            of: "private func dailyOverviewTextLayout",
            range: ringStart.upperBound..<source.endIndex
        ))
        let ring = String(source[ringStart.lowerBound..<ringEnd.lowerBound])

        XCTAssertTrue(overview.contains(".frame(maxHeight: .infinity, alignment: .center)"),
                      "the metric row should consume available height instead of huddling at the top")
        XCTAssertTrue(overview.contains("Divider()"),
                      "the freshness and battery footer needs a stable bottom rail")
        XCTAssertTrue(overview.contains(
            ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)"
        ))
        XCTAssertTrue(ring.contains(".frame(width: 58, height: 58)"),
                      "separate rings should remain glanceable at the medium-widget scale")
        XCTAssertTrue(ring.contains(".font(.system(size: 14, weight: .bold, design: .rounded))"))
        XCTAssertTrue(ring.contains(".lineLimit(2)"),
                      "evidence such as Review sleep and partial coverage may use two readable lines")
        XCTAssertTrue(ring.contains(".font(.system(size: 10, weight: .medium))"),
                      "qualifiers must remain legible on the physical medium widget")
        XCTAssertTrue(ring.contains(
            ".frame(maxWidth: .infinity, minHeight: 22, alignment: .top)"
        ), "all three evidence qualifiers should keep a shared baseline")
        XCTAssertTrue(ring.contains("presentation: dailyRingPresentation(metric)"),
                      "the reflow must retain the truthful progress/partial/presence projection")
        XCTAssertTrue(ring.contains("Text(dailyDetail(metric))"),
                      "the visual reflow must retain each metric's provenance")

        let staticSurface = overview + ring
        XCTAssertFalse(staticSurface.contains(".background("))
        XCTAssertFalse(staticSurface.contains("Material"))
        XCTAssertFalse(staticSurface.contains("glassEffect"),
                       "WidgetKit already owns the static widget material")
    }

    func testAggregateHomeWidgetKeepsEvidenceInsideMarginsAndAdaptsForAccessibility() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let entryStart = try XCTUnwrap(source.range(of: "struct AtriaWidgetEntryView: View"))
        let entryEnd = try XCTUnwrap(source.range(of: "private struct AtriaWidgetRecoveryGauge"))
        let aggregate = String(source[entryStart.lowerBound..<entryEnd.lowerBound])

        XCTAssertTrue(aggregate.contains("if dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(aggregate.contains("private var accessibleSmallWidget"))
        XCTAssertTrue(aggregate.contains("private var accessibleMediumWidget"))
        XCTAssertTrue(aggregate.contains("private var widgetStatusFooter"))
        XCTAssertTrue(aggregate.contains("return \"Widget stale \\(hours)h · Open Atria\""))
        XCTAssertTrue(aggregate.contains("return \"Widget updated \\(atriaTimeOfDayFormatter.string(from: snapshot.createdAt))\""),
                      "the delivery clock must explicitly qualify the widget, not Recovery")
        XCTAssertTrue(aggregate.contains("case \"unverified\": return \"Early estimate\""))
        // 2026-08-14 (assessment P0.3): the reserved tier renders as the
        // strongest honest claim on every surface.
        XCTAssertTrue(aggregate.contains("case \"validated\": return \"Personal baseline\""))
        XCTAssertFalse(aggregate.contains("return \"Validated\""),
                       "internal evidence states must not leak lab vocabulary into end-user copy")
        XCTAssertTrue(aggregate.contains("Text(recoveryEvidenceFooter)"))
        XCTAssertTrue(aggregate.contains("Text(widgetFreshnessFooter)"))

        let headerStart = try XCTUnwrap(aggregate.range(of: "private var widgetHeader"))
        let headerEnd = try XCTUnwrap(aggregate.range(of: "private var recoverySummaryRow", range: headerStart.upperBound..<aggregate.endIndex))
        let header = String(aggregate[headerStart.lowerBound..<headerEnd.lowerBound])
        XCTAssertFalse(header.contains("recoveryPercent"),
                       "the header must not duplicate the recovery score above the recovery hero")
    }

    func testAggregateWidgetAvoidsVisualUnitDuplicationAndSpeaksClinicalUnits() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let entryStart = try XCTUnwrap(source.range(of: "struct AtriaWidgetEntryView: View"))
        let entryEnd = try XCTUnwrap(source.range(of: "private struct AtriaWidgetRecoveryGauge"))
        let aggregate = String(source[entryStart.lowerBound..<entryEnd.lowerBound])

        XCTAssertTrue(aggregate.contains("case .sleep, .steps, .strain: return nil"),
                      "Sleep values already include h and must not render a duplicate unit")
        XCTAssertTrue(aggregate.contains("case .hrv: return \"\\(value) milliseconds\""))
        XCTAssertTrue(aggregate.contains("case .bpm, .rhr: return \"\\(value) beats per minute\""))
        XCTAssertGreaterThanOrEqual(
            aggregate.components(separatedBy: "metricAccessibilityValue(metric, value: value)").count - 1,
            2,
            "Small summaries and flat rows must both retain spoken units"
        )
    }

    func testLiveOnlyPatchCannotPassWidgetClockOffAsRecoveryFreshness() throws {
        let initialClock = Date(timeIntervalSince1970: 10_000)
        let liveClock = initialClock.addingTimeInterval(120)
        let current = deliverySnapshot(steps: 1_400,
                                       stepsCapturedAt: initialClock,
                                       heartRate: 72,
                                       heartRateCapturedAt: initialClock)
        let patched = WidgetSnapshotPublisher.liveWorkoutPatchedSnapshot(
            current: current,
            createdAt: liveClock,
            heartRate: 84,
            heartRateCapturedAt: liveClock,
            steps: 1_420,
            stepsAreEstimated: false,
            stepsCapturedAt: liveClock,
            stepsSource: "verifiedCanonical",
            stepsCompleteness: "partial",
            stepsCoverageFraction: 0.52,
            stepsAuthorityVersion: WidgetSnapshotPublisher.qualifiedStepAuthorityVersion,
            strain: current.strain,
            strainDetail: current.strainDetail,
            strainCapturedAt: current.strainCapturedAt,
            batteryLevel: current.batteryLevel,
            batteryCapturedAt: liveClock,
            batteryCorroboratedAt: liveClock,
            batteryChargeCapturedAt: liveClock,
            batteryChargeStatus: "notCharging",
            batteryChargeText: "Not charging"
        )

        XCTAssertEqual(patched.createdAt, liveClock)
        XCTAssertEqual(patched.recoveryPercent, current.recoveryPercent)
        XCTAssertEqual(patched.recoveryConfidence, current.recoveryConfidence)
        XCTAssertEqual(patched.recoveryDetail, current.recoveryDetail)

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AtriaWidget/AtriaWidget.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("Widget updated"))
        XCTAssertTrue(source.contains("Widget stale"))
        XCTAssertFalse(source.contains("Recovery updated"))
        XCTAssertFalse(source.contains("Recovery stale"))
    }

    func testCurrentCycleHRVDisplayAuthorityWithholdsRecoveryOnlyCandidate() throws {
        let now = Date(timeIntervalSince1970: 100_000)

        XCTAssertNil(AtriaCurrentCycleHRVDisplayProjection.resolve(
            validated: nil,
            live: nil,
            local: nil,
            now: now
        ), "a Recovery-only nightly candidate is not a display source")

        let local = SessionStore.LatestSessionMetricSource(
            sessionID: UUID(),
            start: now.addingTimeInterval(-600),
            end: now.addingTimeInterval(-300),
            value: 48,
            priority: 1
        )
        let validated = SessionStore.LatestSessionMetricSource(
            sessionID: UUID(),
            start: now.addingTimeInterval(-500),
            end: now.addingTimeInterval(-200),
            value: 52,
            priority: 2
        )
        XCTAssertEqual(
            AtriaCurrentCycleHRVDisplayProjection.resolve(
                validated: nil,
                live: nil,
                local: local,
                now: now
            ),
            .init(value: 48, measuredAt: local.end, source: .localDisplay)
        )
        XCTAssertEqual(
            AtriaCurrentCycleHRVDisplayProjection.resolve(
                validated: validated,
                live: nil,
                local: local,
                now: now
            ),
            .init(value: 52,
                  measuredAt: validated.end,
                  source: .referenceValidated)
        )
        let stale = SessionStore.LatestSessionMetricSource(
            sessionID: UUID(),
            start: now.addingTimeInterval(-90_000),
            end: now.addingTimeInterval(-86_401),
            value: 57,
            priority: 3
        )
        XCTAssertNil(AtriaCurrentCycleHRVDisplayProjection.resolve(
            validated: stale,
            live: nil,
            local: stale,
            now: now
        ), "neither Today nor widgets may revive an expired nightly HRV")

        let producerURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/WidgetSnapshot.swift")
        let producer = try String(contentsOf: producerURL, encoding: .utf8)
        XCTAssertTrue(producer.contains(
            "AtriaCurrentCycleHRVDisplayProjection.resolve("
        ))
        XCTAssertFalse(producer.contains("latestLocalRecoveryHRV(on:"),
                       "the widget must not resurrect Recovery-only HRV")
        XCTAssertFalse(producer.contains("frozenTodayRollup?.lnRMSSD"),
                       "a rollup HRV is not automatically a current display HRV")

        let homeURL = producerURL.deletingLastPathComponent()
            .appendingPathComponent("AtriaHomeView.swift")
        let home = try String(contentsOf: homeURL, encoding: .utf8)
        XCTAssertFalse(home.contains("else if rrPackage.ready, let rmssd"),
                       "Today must not retain a second independent HRV display authority")
    }

    func testRecoveryZoneUsesSerializedCustomThresholds() {
        XCTAssertEqual(WidgetSnapshotPublisher.recoveryZoneIdentifier(
            percent: 75,
            greenLower: 80,
            yellowLower: 50
        ), "yellow")
        XCTAssertEqual(WidgetSnapshotPublisher.recoveryZoneIdentifier(
            percent: 80,
            greenLower: 80,
            yellowLower: 50
        ), "green")
        XCTAssertEqual(WidgetSnapshotPublisher.recoveryZoneIdentifier(
            percent: 49,
            greenLower: 80,
            yellowLower: 50
        ), "red")
        XCTAssertNil(WidgetSnapshotPublisher.recoveryZoneIdentifier(
            percent: nil,
            greenLower: 80,
            yellowLower: 50
        ))
    }

    func testEveryStableIdentitySemanticForcesImmediateTimelineReload() {
        let now = Date(timeIntervalSince1970: 200_000)
        var base = deliverySnapshot(
            steps: 1_000,
            stepsCapturedAt: now,
            heartRate: 72,
            heartRateCapturedAt: now
        )
        base.displayCivilDay = now
        base.displayCivilDayKey = "1970-01-03"
        base.displayTimeZoneIdentifier = "Etc/UTC"
        base.recoveryValueState = "currentCycle"
        base.recoveryExpiresAt = now.addingTimeInterval(1_000)
        base.sleepExpiresAt = now.addingTimeInterval(1_000)
        base.whiteboardRows = [
            WidgetWhiteboardRow(id: "hrv",
                                symbol: "waveform.path.ecg",
                                value: "48 ms",
                                sentence: "Personal baseline",
                                tone: "supportive")
        ]
        base.whiteboardExpiresAt = now.addingTimeInterval(1_000)
        base.sleepNeedHours = 8
        base.sleepFillFraction = 0.75
        base.sleepFillAuthority = "nightlyNeed"
        base.recoveryZone = "yellow"
        base.hrvCapturedAt = now.addingTimeInterval(-300)
        base.biomarkerExpiresAt = now.addingTimeInterval(1_000)

        func assertImmediate(
            _ snapshot: WidgetSnapshot,
            file: StaticString = #filePath,
            line: UInt = #line
        ) {
            XCTAssertEqual(WidgetSnapshotPublisher.timelineReloadDelay(
                previous: base,
                lastReloadAt: now,
                snapshot: snapshot,
                now: now.addingTimeInterval(1)
            ), 0, file: file, line: line)
        }

        var changed = base
        changed.recoveryZone = "green"
        assertImmediate(changed)
        changed = base
        changed.recoveryValueState = "partialCurrentDay"
        assertImmediate(changed)
        changed = base
        changed.biomarkerExpiresAt = now.addingTimeInterval(2_000)
        assertImmediate(changed)
        changed = base
        changed.hrvCapturedAt = now.addingTimeInterval(-100)
        assertImmediate(changed)
        changed = base
        changed.sleepNeedHours = 9
        assertImmediate(changed)
        changed = base
        changed.sleepFillFraction = 0.82
        assertImmediate(changed)
        changed = base
        changed.sleepFillAuthority = "configuredGoal"
        assertImmediate(changed)
        changed = base
        changed.displayCivilDayKey = "1970-01-04"
        assertImmediate(changed)
        changed = base
        changed.whiteboardExpiresAt = now.addingTimeInterval(2_000)
        assertImmediate(changed)
        changed = base
        changed.whiteboardRows = [
            WidgetWhiteboardRow(id: "new-hrv",
                                symbol: "heart.text.square.fill",
                                value: base.whiteboardRows?.first?.value ?? "48 ms",
                                sentence: base.whiteboardRows?.first?.sentence ?? "Personal baseline",
                                tone: base.whiteboardRows?.first?.tone ?? "supportive")
        ]
        assertImmediate(changed)
        changed = base
        changed.stepsPriorCycleSteps = 4_200
        assertImmediate(changed)
    }

    func testWidgetExtensionUsesAppAuthorityAndFailsClosedAtExpiry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(widget.contains(
            "private let atriaStaticHeartRateFreshness: TimeInterval = 65"
        ))
        XCTAssertTrue(widget.contains(
            "private let atriaLiveHeartRateFreshness: TimeInterval = 6"
        ))
        XCTAssertTrue(widget.contains("zone: entry.snapshot?.recoveryZone"))
        XCTAssertTrue(widget.contains("snapshot.sleepFillFraction"),
                      "every sleep ring must prefer Today's serialized fill")
        XCTAssertTrue(widget.contains("snapshot?.biomarkerExpiresAt"))
        XCTAssertTrue(widget.contains("restingHR = nil"))
        XCTAssertTrue(widget.contains("hrvRMSSD = nil"))
        XCTAssertTrue(widget.contains(
            "forSecurityApplicationGroupIdentifier: appGroupID"
        ))

        let intents = try String(
            contentsOf: root.appendingPathComponent("Atria/AtriaAppIntents.swift"),
            encoding: .utf8
        )
        let storeStart = try XCTUnwrap(intents.range(
            of: "enum AtriaIntentSnapshotStore"
        ))
        let store = String(intents[storeStart.lowerBound...])
        XCTAssertFalse(store.contains("?? .standard"))
        XCTAssertFalse(store.contains("UserDefaults.standard.data(forKey: key)"))
    }

    func testActiveWorkoutRoutesStableDashboardChangesThroughFullPublisher() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaHomeView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "private func scheduleWidgetSnapshot(reason: String)"
        ))
        let end = try XCTUnwrap(source.range(
            of: "private func scheduleLiveSensorWidgetPatch",
            range: start.upperBound..<source.endIndex
        ))
        let router = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(router.contains("isLiveOnlyReason"))
        XCTAssertTrue(router.contains("dashboard authority"))
        XCTAssertTrue(router.contains("WidgetSnapshotPublisher.schedulePublish"))
        XCTAssertTrue(router.contains("scheduleLiveSensorWidgetPatch"))
    }

    func testStableAndLivePublishGenerationsCannotCancelEachOther() {
        var authority = WidgetSnapshotPublisher.PublishLaneAuthority()
        let stable = authority.mint(.stable)
        let live = authority.mint(.live)
        XCTAssertTrue(authority.isCurrent(stable),
                      "a pulse must not invalidate a pending stable rebuild")
        XCTAssertTrue(authority.isCurrent(live))

        let newerLive = authority.mint(.live)
        XCTAssertTrue(authority.isCurrent(stable))
        XCTAssertFalse(authority.isCurrent(live))
        XCTAssertTrue(authority.isCurrent(newerLive))

        let newerStable = authority.mint(.stable)
        XCTAssertFalse(authority.isCurrent(stable))
        XCTAssertTrue(authority.isCurrent(newerStable))
        XCTAssertTrue(authority.isCurrent(newerLive))
    }

    func testSiriPreservesRecoveryAndStrainQualifiers() {
        XCTAssertEqual(AtriaIntentMetricPresentation.recoverySpoken(
            percent: 54,
            confidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue
        ), "54 percent, early estimate")
        XCTAssertEqual(AtriaIntentMetricPresentation.recoveryCompact(
            percent: 54,
            confidence: Metrics.RecoveryEstimate.Confidence.unverified.rawValue
        ), "~54%")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainSpoken(
            value: 3.42,
            detail: "Partial · sparse HR"
        ), "at least 3.4")
        XCTAssertEqual(AtriaIntentMetricPresentation.strainCompact(
            value: 3.42,
            detail: "Partial · sparse HR"
        ), "≥ 3.4")
    }

}
