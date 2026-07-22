import XCTest
@testable import Atria

final class AtriaMorningCheckInTests: XCTestCase {
    private var directory: URL!
    private var calendar: Calendar!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    func testRecordRoundTripsAndEditsSamePhysiologicalDayWithoutChangingObjectiveContext() throws {
        let now = Date(timeIntervalSince1970: 1_784_691_600)
        let store = AtriaMorningCheckInStore(directory: directory)
        var draft = AtriaMorningCheckInDraft()
        draft.perceivedRecovery = 2
        draft.sleepQuality = 4
        draft.interruptionCount = 3
        draft.interruptionTags = [.bathroom, .restless]
        draft.note = "Deep, but broken"
        let first = try store.save(dayKey: "2026-07-22",
                                   timeZone: calendar.timeZone,
                                   draft: draft,
                                   objectiveRecovery: 99,
                                   objectiveConfidence: "limited",
                                   now: now)

        draft.perceivedRecovery = 3
        let edited = try store.save(dayKey: "2026-07-22",
                                    timeZone: calendar.timeZone,
                                    draft: draft,
                                    objectiveRecovery: 12,
                                    objectiveConfidence: "changed",
                                    now: now.addingTimeInterval(60))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(edited.createdAt, first.createdAt)
        XCTAssertEqual(edited.perceivedRecovery, 3)
        XCTAssertEqual(edited.objectiveRecoveryAtCheckIn, 99)
        XCTAssertEqual(edited.objectiveRecoveryConfidence, "limited")

        let restored = AtriaMorningCheckInStore(directory: directory).record(for: "2026-07-22")
        XCTAssertEqual(restored, edited)
    }

    func testValidationClampsUserInputAndBoundsStorage() throws {
        let store = AtriaMorningCheckInStore(directory: directory)
        var draft = AtriaMorningCheckInDraft()
        draft.perceivedRecovery = -4
        draft.sleepQuality = 10
        draft.energyReadiness = 0
        draft.soreness = 8
        draft.interruptionCount = 99
        draft.note = String(repeating: "x", count: 500)
        let value = try store.save(dayKey: "2026-07-22",
                                   timeZone: calendar.timeZone,
                                   draft: draft,
                                   objectiveRecovery: 900,
                                   objectiveConfidence: String(repeating: "c", count: 200))
        XCTAssertEqual(value.perceivedRecovery, 1)
        XCTAssertEqual(value.sleepQuality, 5)
        XCTAssertEqual(value.energyReadiness, 1)
        XCTAssertEqual(value.soreness, 5)
        XCTAssertEqual(value.interruptionCount, 20)
        XCTAssertEqual(value.note.count, 280)
        XCTAssertNil(value.objectiveRecoveryAtCheckIn)
        XCTAssertEqual(value.objectiveRecoveryConfidence?.count, 80)
        XCTAssertTrue(value.isValid)
    }

    func testEligibilityUsesWakeDayAcrossTimeZonesAndMorningFallback() throws {
        let wake = ISO8601DateFormatter().date(from: "2026-07-22T03:45:00Z")! // 09:15 IST
        let later = wake.addingTimeInterval(4 * 3600)
        let afterSleep = AtriaMorningCheckInEligibility.resolve(now: later,
                                                                 mainSleepEnd: wake,
                                                                 calendar: calendar)
        XCTAssertTrue(afterSleep.isEligible)
        XCTAssertEqual(afterSleep.dayKey, "2026-07-22")
        XCTAssertEqual(afterSleep.reason, "main_sleep")

        let morning = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: later)!
        XCTAssertEqual(AtriaMorningCheckInEligibility.resolve(now: morning,
                                                               mainSleepEnd: nil,
                                                               calendar: calendar).reason,
                       "local_morning_wear")
        let evening = calendar.date(bySettingHour: 20, minute: 0, second: 0, of: later)!
        XCTAssertFalse(AtriaMorningCheckInEligibility.resolve(now: evening,
                                                               mainSleepEnd: nil,
                                                               calendar: calendar).isEligible)
    }

    func testCalibrationStaysHiddenUntilSevenPairedDays() throws {
        let store = AtriaMorningCheckInStore(directory: directory)
        var draft = AtriaMorningCheckInDraft()
        draft.perceivedRecovery = 3 // 50 on comparison scale
        for day in 1...6 {
            _ = try store.save(dayKey: String(format: "2026-07-%02d", day),
                               timeZone: calendar.timeZone,
                               draft: draft,
                               objectiveRecovery: 80,
                               objectiveConfidence: "qualified")
        }
        XCTAssertFalse(store.calibrationSummary.isReady)
        XCTAssertNil(store.calibrationSummary.meanPerceivedMinusObjective)

        _ = try store.save(dayKey: "2026-07-07",
                           timeZone: calendar.timeZone,
                           draft: draft,
                           objectiveRecovery: 80,
                           objectiveConfidence: "qualified")
        XCTAssertTrue(store.calibrationSummary.isReady)
        XCTAssertEqual(store.calibrationSummary.pairedDays, 7)
        XCTAssertEqual(store.calibrationSummary.meanObjectiveRecovery, 80)
        XCTAssertEqual(store.calibrationSummary.meanPerceivedRecovery, 50)
        XCTAssertEqual(store.calibrationSummary.meanPerceivedMinusObjective, -30)
    }

    func testMorningCheckInUISeparatesObjectiveAndSubjectiveAndIsEditable() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaMorningCheckIn.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertTrue(source.contains("Text(\"Objective recovery\")"))
        XCTAssertTrue(source.contains("Text(\"How you feel\")"))
        XCTAssertTrue(source.contains("they never rewrite today’s score"))
        XCTAssertTrue(source.contains("model.record == nil ? \"Check in\" : \"Edit\""))
        XCTAssertFalse(source.contains("baseline.update"))
        XCTAssertFalse(source.contains("recoveryPercent ="))
    }
}
