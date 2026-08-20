import XCTest
@testable import Atria

/// 2026-08-20 (widget-sync W2-A, fixes 1–2). RC1: nothing republished the
/// widget snapshot at civil midnight, so a shifted sleeper (13:15–19:15 cycle)
/// saw "Awaiting today's data"/"--" from 00:00 until the next full publish
/// while the in-app Today stayed correct. RC2: the extension's day fence
/// blanked EVERY family at the day-key mismatch, including wake-to-wake
/// steps/strain whose own publisher-persisted cycle fences were still in the
/// future. The fence decision is now a pure function compiled into the app
/// target (Atria/AtriaWidgetDayFence.swift) and mirrored byte-identically in
/// the widget target; these tests carry the unit coverage and pin the mirror.
@MainActor
final class AtriaWidgetDayFenceTests: XCTestCase {
    private var kolkata: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        kolkata.date(from: DateComponents(year: year, month: month, day: day,
                                          hour: hour, minute: minute))!
    }

    // MARK: - Fence split (RC2)

    /// The plan's shifted-sleeper fixture: snapshot published 23:50, step and
    /// strain cycle fences expiring 19:15 the NEXT civil day. At 00:10 the
    /// payload no longer belongs to the current civil day (recovery/sleep/
    /// biomarker/whiteboard blank, H10 identity unchanged) but steps and
    /// strain survive because their own physiological fences are still in the
    /// future. Past 19:15 everything blanks.
    func testShiftedSleeperKeepsStepsAndStrainAcrossCivilMidnightUntilTheirFences() {
        let calendar = kolkata
        let published = date(2026, 8, 19, 23, 50)
        let cycleExpiry = date(2026, 8, 20, 19, 15)
        let justPastMidnight = date(2026, 8, 20, 0, 10)
        let publishedKey = WidgetSnapshotPublisher.civilDayKey(
            for: published, calendar: calendar
        )

        let midnightDecision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: publishedKey
                == WidgetSnapshotPublisher.civilDayKey(
                    for: justPastMidnight, calendar: calendar
                ),
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: calendar.isDate(
                published, inSameDayAs: justPastMidnight
            ),
            stepsCycleExpiresAt: cycleExpiry,
            strainCycleExpiresAt: cycleExpiry,
            now: justPastMidnight
        )
        XCTAssertFalse(midnightDecision.belongsToCurrentDay,
                       "recovery/sleep/biomarkers never survive civil midnight")
        XCTAssertTrue(midnightDecision.keepsSteps,
                      "the 19:15 step fence is still in the future at 00:10")
        XCTAssertTrue(midnightDecision.keepsStrain,
                      "the 19:15 strain fence is still in the future at 00:10")

        let pastFence = date(2026, 8, 20, 19, 16)
        let pastFenceDecision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: publishedKey
                == WidgetSnapshotPublisher.civilDayKey(
                    for: pastFence, calendar: calendar
                ),
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: calendar.isDate(
                published, inSameDayAs: pastFence
            ),
            stepsCycleExpiresAt: cycleExpiry,
            strainCycleExpiresAt: cycleExpiry,
            now: pastFence
        )
        XCTAssertFalse(pastFenceDecision.belongsToCurrentDay)
        XCTAssertFalse(pastFenceDecision.keepsSteps,
                       "an expired physiological fence blanks steps too")
        XCTAssertFalse(pastFenceDecision.keepsStrain)
    }

    func testSameDayPayloadIsUntouchedByTheFence() {
        let calendar = kolkata
        let published = date(2026, 8, 19, 23, 50)
        let now = date(2026, 8, 19, 23, 55)
        let key = WidgetSnapshotPublisher.civilDayKey(
            for: published, calendar: calendar
        )
        let decision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: key
                == WidgetSnapshotPublisher.civilDayKey(
                    for: now, calendar: calendar
                ),
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: true,
            stepsCycleExpiresAt: date(2026, 8, 20, 19, 15),
            strainCycleExpiresAt: date(2026, 8, 20, 19, 15),
            now: now
        )
        XCTAssertTrue(decision.belongsToCurrentDay)
    }

    /// Absent fence fields must keep failing closed exactly as before this
    /// change: legacy payloads carry no cycle expiry, so a day-key mismatch
    /// blanks their steps and strain.
    func testAbsentFencesFailClosedOnDayMismatch() {
        let now = date(2026, 8, 20, 0, 10)
        let decision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: false,
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: false,
            stepsCycleExpiresAt: nil,
            strainCycleExpiresAt: nil,
            now: now
        )
        XCTAssertFalse(decision.belongsToCurrentDay)
        XCTAssertFalse(decision.keepsSteps, "no fence, no survival")
        XCTAssertFalse(decision.keepsStrain, "no fence, no survival")
    }

    func testFencesSplitIndependentlyPerFamily() {
        let now = date(2026, 8, 20, 0, 10)
        let decision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: false,
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: false,
            stepsCycleExpiresAt: date(2026, 8, 20, 19, 15),
            strainCycleExpiresAt: nil,
            now: now
        )
        XCTAssertTrue(decision.keepsSteps)
        XCTAssertFalse(decision.keepsStrain,
                       "strain honesty pin: a withheld credibility clock has no "
                       + "fence and must blank")
    }

    func testLegacyPayloadUsesCreatedAtDayIdentity() {
        let now = date(2026, 8, 20, 0, 10)
        let sameDay = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: nil,
            displayTimeZoneMatchesCurrentCalendar: true,
            createdAtIsOnCurrentDay: true,
            stepsCycleExpiresAt: nil,
            strainCycleExpiresAt: nil,
            now: now
        )
        XCTAssertTrue(sameDay.belongsToCurrentDay)
        let priorDay = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: nil,
            displayTimeZoneMatchesCurrentCalendar: false,
            createdAtIsOnCurrentDay: false,
            stepsCycleExpiresAt: nil,
            strainCycleExpiresAt: nil,
            now: now
        )
        XCTAssertFalse(priorDay.belongsToCurrentDay)
    }

    /// Mirrors testIntentAndWidgetIdentityRejectAnOldZoneEvenWhenDateKeyMatches:
    /// a matching date key from another timezone is another day's identity.
    func testTimeZoneMismatchRejectsAMatchingDayKey() {
        let now = date(2026, 8, 20, 12, 0)
        let decision = AtriaWidgetDayFence.resolve(
            displayCivilDayKeyMatchesCurrentDay: true,
            displayTimeZoneMatchesCurrentCalendar: false,
            createdAtIsOnCurrentDay: true,
            stepsCycleExpiresAt: date(2026, 8, 20, 19, 15),
            strainCycleExpiresAt: date(2026, 8, 20, 19, 15),
            now: now
        )
        XCTAssertFalse(decision.belongsToCurrentDay)
    }

    // MARK: - Mirror and enforcement pins

    /// The two targets share no source file, so the widget compiles a copy of
    /// the fence. The copy must stay byte-identical with the app-target
    /// original that carries this unit coverage.
    func testDayFenceMirrorBlocksAreByteIdentical() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        func mirrorBlock(_ relativePath: String) throws -> String {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            let begin = try XCTUnwrap(source.range(
                of: "// ATRIA-DAY-FENCE-MIRROR-BEGIN\n"
            ), "\(relativePath) lost its mirror begin marker")
            let end = try XCTUnwrap(source.range(
                of: "// ATRIA-DAY-FENCE-MIRROR-END",
                range: begin.upperBound..<source.endIndex
            ), "\(relativePath) lost its mirror end marker")
            return String(source[begin.upperBound..<end.lowerBound])
        }
        XCTAssertEqual(
            try mirrorBlock("Atria/AtriaWidgetDayFence.swift"),
            try mirrorBlock("AtriaWidget/AtriaWidget.swift"),
            "the widget's day-fence copy drifted from the tested app original"
        )
    }

    /// The extension must consult the shared decision and gate ONLY the step
    /// and strain families on it; recovery/sleep/biomarker/whiteboard blanking
    /// stays unconditional at a day mismatch (H10 civil-day identity).
    func testExtensionEnforcementGatesOnlyStepsAndStrainOnTheFence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let widget = try String(
            contentsOf: root.appendingPathComponent("AtriaWidget/AtriaWidget.swift"),
            encoding: .utf8
        )
        let enforcementStart = try XCTUnwrap(widget.range(
            of: "mutating func atriaEnforceCurrentDayIdentity("
        ))
        let enforcementEnd = try XCTUnwrap(widget.range(
            of: "var steps: Int?",
            range: enforcementStart.upperBound..<widget.endIndex
        ))
        let enforcement = String(
            widget[enforcementStart.lowerBound..<enforcementEnd.lowerBound]
        )
        XCTAssertTrue(enforcement.contains("AtriaWidgetDayFence.resolve("))
        XCTAssertTrue(enforcement.contains("if !decision.belongsToCurrentDay {"))
        XCTAssertTrue(enforcement.contains("if !decision.keepsStrain {"))
        XCTAssertTrue(enforcement.contains("if !decision.keepsSteps {"))
        let blanking = try XCTUnwrap(enforcement.range(
            of: "if !decision.belongsToCurrentDay {"
        ))
        let recoveryBlank = try XCTUnwrap(enforcement.range(
            of: "recoveryPercent = nil",
            range: blanking.upperBound..<enforcement.endIndex
        ))
        let strainGate = try XCTUnwrap(enforcement.range(
            of: "if !decision.keepsStrain {",
            range: blanking.upperBound..<enforcement.endIndex
        ))
        XCTAssertLessThan(recoveryBlank.lowerBound, strainGate.lowerBound,
                          "recovery must blank unconditionally, before any "
                          + "family gate")
        XCTAssertFalse(enforcement.contains("keepsRecovery"),
                       "no fence may ever let recovery cross civil midnight")
        XCTAssertFalse(enforcement.contains("keepsSleep"),
                       "no fence may ever let sleep cross civil midnight")
    }

    // MARK: - Rollover republish trigger (RC1)

    /// Fix 1, in the existing durable-step-observer style: AtriaAppDependencies
    /// must observe the civil-day change and route the republish through
    /// `schedulePublish` (launch fence inherited), never a direct defaults
    /// write. Launch-independent by design — the recovery-state defect class
    /// forbids a fence clearable only by the success it blocks.
    func testAppLifetimeDependenciesRepublishOnCivilDayRollover() throws {
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

        XCTAssertTrue(dependencies.contains("forName: .NSCalendarDayChanged"))
        let observerStart = try XCTUnwrap(dependencies.range(
            of: "civilDayRolloverObserver = NotificationCenter.default.addObserver("
        ))
        let observerBody = String(dependencies[observerStart.lowerBound...])
        XCTAssertTrue(observerBody.contains(
            "WidgetSnapshotPublisher.schedulePublish("
        ))
        XCTAssertTrue(observerBody.contains("reason: \"civil_day_rollover\""))
        XCTAssertFalse(observerBody.contains("UserDefaults"),
                       "the rollover republish must inherit the "
                       + "shouldPersistSnapshot launch fence via schedulePublish, "
                       + "never write the shared snapshot directly")
        XCTAssertTrue(dependencies.contains(
            "if let civilDayRolloverObserver {"
        ), "the observer must be removed with the dependencies lifetime")
    }
}
