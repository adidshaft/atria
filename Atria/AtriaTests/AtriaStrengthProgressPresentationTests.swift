import XCTest
@testable import Atria

/// Design-parity slice 2 (2026-08-01): pure math behind the e1RM progress
/// chart (7b), its PR markers, the three-session gate that withholds the line,
/// and the catalog row projection (7c). All inputs are the real model types.
final class AtriaStrengthProgressPresentationTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: origin)!
    }

    private func historyDay(_ offset: Int,
                            weightKg: Double?,
                            reps: Int?,
                            setCount: Int = 1) -> StrengthHistoryDay {
        let date = day(offset)
        return StrengthHistoryDay(day: date,
                                  best: LoggedSet(exercise: "Back squat",
                                                  weightKg: weightKg,
                                                  reps: reps,
                                                  rpe: nil,
                                                  t: date),
                                  setCount: setCount)
    }

    // MARK: - Point selection

    func testTimelinePlotsOnlyDaysThatProduceARealEpleyEstimate() {
        let history = [
            historyDay(0, weightKg: 100, reps: 5),
            // No weight: Epley cannot run, so the day is not a chart point.
            historyDay(2, weightKg: nil, reps: 8),
            // 13 reps sits outside Epley's 1-12 band.
            historyDay(4, weightKg: 60, reps: 13),
            historyDay(6, weightKg: 110, reps: 3)
        ]

        let timeline = AtriaStrengthProgressPresentation.timeline(history)

        XCTAssertEqual(timeline.map(\.day), [day(0), day(6)])
        XCTAssertEqual(timeline[0].e1RM,
                       AtriaStrengthLog.estimatedOneRepMax(weightKg: 100, reps: 5))
    }

    func testPersonalRecordFlagsFollowTheRunningMaxOfEarlierDays() {
        let history = [
            historyDay(0, weightKg: 100, reps: 5),   // 116.67 — first, a record
            historyDay(3, weightKg: 95, reps: 5),    // 110.83 — below, not a record
            historyDay(6, weightKg: 105, reps: 5),   // 122.50 — record
            historyDay(9, weightKg: 105, reps: 5)    // equal, not a record
        ]

        let timeline = AtriaStrengthProgressPresentation.timeline(history)

        XCTAssertEqual(timeline.map(\.isPersonalRecord), [true, false, true, false])
    }

    func testChartMarksOnlyTheNewestPersonalRecordSolid() throws {
        let history = [
            historyDay(0, weightKg: 100, reps: 5),
            historyDay(3, weightKg: 95, reps: 5),
            historyDay(6, weightKg: 105, reps: 5),
            historyDay(9, weightKg: 102, reps: 5)
        ]
        let timeline = AtriaStrengthProgressPresentation.timeline(history)

        let chart = try XCTUnwrap(AtriaStrengthProgressPresentation.chart(for: timeline))
        let points = chart.points
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points.map(\.isPersonalRecord), [true, false, true, false])
        // Hollow past record, solid newest record, plain session dots.
        XCTAssertEqual(points.map(\.isNewestPersonalRecord), [false, false, true, false])

        // X runs first -> last across the plotted span; Y stays inside the band.
        XCTAssertEqual(points.first?.x ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(points.last?.x ?? -1, 1, accuracy: 0.0001)
        for point in points {
            XCTAssertGreaterThanOrEqual(point.y, 0)
            XCTAssertLessThanOrEqual(point.y, 1)
        }
    }

    func testRangeWindowingKeepsOnlySessionsInsideTheRealCutoff() {
        let history = [
            historyDay(0, weightKg: 100, reps: 5),
            historyDay(120, weightKg: 105, reps: 5),
            historyDay(175, weightKg: 108, reps: 5)
        ]
        let timeline = AtriaStrengthProgressPresentation.timeline(history)
        let now = day(180)

        XCTAssertEqual(AtriaStrengthProgressPresentation.windowed(timeline, range: .month, now: now).count, 1)
        XCTAssertEqual(AtriaStrengthProgressPresentation.windowed(timeline, range: .threeMonths, now: now).count, 2)
        XCTAssertEqual(AtriaStrengthProgressPresentation.windowed(timeline, range: .all, now: now).count, 3)
    }

    func testNinetyDayDeltaIsWithheldUntilASessionExistsThatFarBack() throws {
        let short = AtriaStrengthProgressPresentation.timeline([
            historyDay(0, weightKg: 100, reps: 5),
            historyDay(20, weightKg: 110, reps: 5)
        ])
        XCTAssertNil(AtriaStrengthProgressPresentation.delta(short, now: day(30)),
                     "a 90-day delta must not be invented from a 30-day history")

        let long = AtriaStrengthProgressPresentation.timeline([
            historyDay(0, weightKg: 100, reps: 5),
            historyDay(120, weightKg: 110, reps: 5)
        ])
        let delta = try XCTUnwrap(AtriaStrengthProgressPresentation.delta(long, now: day(120)))
        XCTAssertEqual(delta,
                       (110 * (1 + 5.0 / 30)) - (100 * (1 + 5.0 / 30)),
                       accuracy: 0.0001)
    }

    // MARK: - Three-session gate

    func testChartIsWithheldBelowThreeSessionsAndAppearsAtThree() {
        let two = AtriaStrengthProgressPresentation.timeline([
            historyDay(0, weightKg: 100, reps: 5, setCount: 1),
            historyDay(3, weightKg: 102, reps: 5, setCount: 1)
        ])
        XCTAssertEqual(two.count, 2)
        XCTAssertNil(AtriaStrengthProgressPresentation.chart(for: two))

        let three = AtriaStrengthProgressPresentation.timeline([
            historyDay(0, weightKg: 100, reps: 5),
            historyDay(3, weightKg: 102, reps: 5),
            historyDay(6, weightKg: 104, reps: 5)
        ])
        XCTAssertNotNil(AtriaStrengthProgressPresentation.chart(for: three))
        XCTAssertEqual(AtriaStrengthProgressPresentation.minimumSessions, 3)
    }

    func testLearningCopyStatesRealSetsAndRemainingWorkouts() {
        let timeline = AtriaStrengthProgressPresentation.timeline([
            historyDay(0, weightKg: 100, reps: 5, setCount: 2),
            historyDay(3, weightKg: 102, reps: 5, setCount: 3)
        ])
        let sets = AtriaStrengthProgressPresentation.setCount(timeline)

        XCTAssertEqual(sets, 5)
        XCTAssertEqual(AtriaStrengthProgressPresentation.learningText(sessions: timeline.count, sets: sets),
                       "Learning \u{00B7} 5 sets logged")
        XCTAssertEqual(AtriaStrengthProgressPresentation.learningText(sessions: 0, sets: 0),
                       "No sets logged yet")
        XCTAssertEqual(AtriaStrengthProgressPresentation.needMoreText(sessions: timeline.count),
                       "Need 3+ workouts \u{00B7} 1 to go")
        XCTAssertEqual(AtriaStrengthProgressPresentation.needMoreText(sessions: 3), "")
    }

    // MARK: - Catalog rows

    func testCatalogRowWithholdsTheSparklineUntilTheGateClears() {
        let sets = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: nil, t: day(0)),
            LoggedSet(exercise: "Back squat", weightKg: 105, reps: 5, rpe: 8, t: day(3))
        ]
        let session = SavedSession(id: UUID(),
                                   start: day(0),
                                   end: day(0).addingTimeInterval(3_600),
                                   label: "Strength",
                                   points: [],
                                   strengthSets: sets)
        let projection = AtriaStrengthLog.historyProjection(in: [session], calendar: calendar)

        let learning = AtriaStrengthProgressPresentation.catalogRow(name: "Back squat",
                                                                    group: "Legs",
                                                                    projection: projection)
        XCTAssertEqual(learning.sessionCount, 2)
        XCTAssertEqual(learning.setCount, 2)
        XCTAssertFalse(learning.hasEnoughHistory)
        XCTAssertTrue(learning.sparkline.isEmpty, "two sessions must not draw a shape")

        let never = AtriaStrengthProgressPresentation.catalogRow(name: "Front squat",
                                                                 group: "Legs",
                                                                 projection: projection)
        XCTAssertNil(never.e1RM)
        XCTAssertNil(never.lastLogged)
        XCTAssertEqual(never.sessionCount, 0)

        let third = LoggedSet(exercise: "Back squat", weightKg: 110, reps: 5, rpe: nil, t: day(6))
        let extended = SavedSession(id: UUID(),
                                    start: day(6),
                                    end: day(6).addingTimeInterval(3_600),
                                    label: "Strength",
                                    points: [],
                                    strengthSets: [third])
        let wider = AtriaStrengthLog.historyProjection(in: [session, extended], calendar: calendar)
        let charted = AtriaStrengthProgressPresentation.catalogRow(name: "back squat",
                                                                   group: "Legs",
                                                                   projection: wider)
        XCTAssertTrue(charted.hasEnoughHistory)
        XCTAssertEqual(charted.sparkline.count, 3)
        XCTAssertTrue(charted.holdsCurrentRecord, "the newest day is the heaviest e1RM")
        XCTAssertEqual(charted.lastLogged, calendar.startOfDay(for: day(6)))
    }

    func testCatalogSortsLoggedExercisesByRecencyAndKeepsUnloggedLast() {
        let rows = [
            AtriaStrengthProgressPresentation.CatalogRow(id: "a", name: "A", group: "Legs",
                                                         e1RM: nil, lastLogged: day(1),
                                                         sessionCount: 3, setCount: 3,
                                                         sparkline: [], holdsCurrentRecord: false),
            AtriaStrengthProgressPresentation.CatalogRow(id: "b", name: "B", group: "Legs",
                                                         e1RM: nil, lastLogged: nil,
                                                         sessionCount: 0, setCount: 0,
                                                         sparkline: [], holdsCurrentRecord: false),
            AtriaStrengthProgressPresentation.CatalogRow(id: "c", name: "C", group: "Push",
                                                         e1RM: nil, lastLogged: day(9),
                                                         sessionCount: 4, setCount: 4,
                                                         sparkline: [], holdsCurrentRecord: false)
        ]

        XCTAssertEqual(AtriaStrengthProgressPresentation.sortedByRecency(rows).map(\.id),
                       ["c", "a", "b"])
        XCTAssertEqual(AtriaStrengthProgressPresentation.filter(rows, search: "", group: "Push").map(\.id),
                       ["c"])
        XCTAssertEqual(AtriaStrengthProgressPresentation.filter(rows, search: "b", group: nil).map(\.id),
                       ["b"])
    }

    // MARK: - Logged muscular-input receipt

    func testBodyweightEffectiveLoadIsFrozenAndDoesNotNeedTodaysProfile() throws {
        let effective = try XCTUnwrap(AtriaStrengthLog.effectiveLoadKg(exercise: "Push-up",
                                                                        externalWeightKg: 10,
                                                                        bodyMassKg: 70))
        XCTAssertEqual(effective.movementClass, .bodyweightEstimate)
        XCTAssertEqual(effective.loadKg, 55.5, accuracy: 0.001)

        // The logged receipt takes the frozen effective load only. Reopening
        // this workout after a profile/body-mass change cannot rewrite it.
        let set = LoggedSet(exercise: "Push-up",
                            weightKg: 10,
                            reps: 12,
                            rpe: 8,
                            t: day(0),
                            effectiveLoadKg: effective.loadKg)
        let receipt = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: [set]))
        XCTAssertEqual(receipt.effectiveVolumeKg, 666, accuracy: 0.001)
        XCTAssertEqual(receipt.externalVolumeKg, 120, accuracy: 0.001)
        XCTAssertEqual(receipt.movementClasses, [.bodyweightEstimate])
    }

    func testMuscularLoadBasisDistinguishesMeasuredFromBodyMassEstimate() throws {
        // GAP-09: the results card must say whether the logged volume is a
        // measured external load or a body-mass estimate, so a pull-up session
        // is never presented like measured barbell work.
        let barbell = LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8, t: day(0))
        let measured = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: [barbell]))
        XCTAssertFalse(measured.includesBodyweightEstimate)
        XCTAssertEqual(measured.loadBasisText, "Measured external load")

        let pushUp = LoggedSet(exercise: "Push-up", weightKg: 0, reps: 12, rpe: 8, t: day(0),
                               effectiveLoadKg: 45.5)
        let estimated = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: [pushUp]))
        XCTAssertTrue(estimated.includesBodyweightEstimate)
        XCTAssertEqual(estimated.loadBasisText, "Body-mass estimate")

        let mixed = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: [barbell, pushUp]))
        XCTAssertTrue(mixed.includesBodyweightEstimate)
        XCTAssertEqual(mixed.loadBasisText, "Measured + body-mass estimate")
    }

    func testMuscularInputNeverInventsAnRPEForAnOtherwiseLoadedSet() throws {
        let sets = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8, t: day(0)),
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: nil, t: day(0))
        ]
        let receipt = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: sets))

        XCTAssertEqual(receipt.loadQualifiedSetCount, 2)
        XCTAssertEqual(receipt.effortQualifiedSetCount, 1)
        XCTAssertFalse(receipt.hasCompleteEffortEvidence)
        XCTAssertNil(receipt.muscularInputScore,
                     "a missing RPE must not silently become an average effort")
    }

    func testMuscularInputRisesWithLoggedRPEAndObservedSupersetDensity() throws {
        let lowEffort = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 6, t: day(0)),
            LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 6, t: day(0))
        ]
        let highEffortSuperset = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 9, t: day(0),
                      supersetGroupID: "round-1", supersetOrder: 0, supersetTransitionSeconds: 0),
            LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 9, t: day(0),
                      supersetGroupID: "round-1", supersetOrder: 1, supersetTransitionSeconds: 45)
        ]
        let lower = try XCTUnwrap(try XCTUnwrap(
            AtriaStrengthLog.muscularLoadReceipt(for: lowEffort)
        ).muscularInputScore)
        let higher = try XCTUnwrap(try XCTUnwrap(
            AtriaStrengthLog.muscularLoadReceipt(for: highEffortSuperset)
        ).muscularInputScore)

        XCTAssertGreaterThan(higher, lower)
        let density = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: highEffortSuperset)?.densityBonusFraction)
        XCTAssertEqual(density, 0.06, accuracy: 0.0001)
    }

    func testQualifiedMuscularReceiptRoundTripsWithItsCalculationVersion() throws {
        let sets = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8, t: day(0)),
            LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 8.5, t: day(0))
        ]
        let original = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: sets))
        let restored = try JSONDecoder().decode(AtriaStrengthLog.MuscularLoadReceipt.self,
                                                from: JSONEncoder().encode(original))

        XCTAssertEqual(restored, original)
        XCTAssertEqual(restored.calculationVersion, 1)
        XCTAssertTrue(restored.hasCompleteEffortEvidence)
    }

    // MARK: - GAP-08: superset receipts survive edits, reorders, and round trips

    func testSupersetReceiptDerivesMembershipOrderAndTransition() {
        let group = StrengthSuperset(id: "grp", exercises: ["Back squat", "bench press"])
        let earlier = LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8,
                                t: day(0), supersetGroupID: "grp", supersetOrder: 0)

        let receipt = AtriaStrengthLog.supersetReceipt(exercise: "Bench Press",
                                                       group: group,
                                                       priorSets: [earlier],
                                                       now: day(0).addingTimeInterval(40))
        XCTAssertEqual(receipt.groupID, "grp")
        XCTAssertEqual(receipt.order, 1, "membership and order are case-insensitive")
        XCTAssertEqual(receipt.transitionSeconds ?? -1, 40, accuracy: 0.001)

        XCTAssertEqual(AtriaStrengthLog.supersetReceipt(exercise: "Deadlift",
                                                        group: group,
                                                        priorSets: [earlier],
                                                        now: day(0)),
                       .none,
                       "a non-member logs an ordinary set")
        XCTAssertEqual(AtriaStrengthLog.supersetReceipt(exercise: "Back squat",
                                                        group: nil,
                                                        priorSets: [earlier],
                                                        now: day(0)),
                       .none)
    }

    func testSupersetReceiptNeverResolvesTheEditedSetAsItsOwnPriorMember() {
        let group = StrengthSuperset(id: "grp", exercises: ["Back squat", "Bench press"])
        let first = LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8,
                              t: day(0), supersetGroupID: "grp", supersetOrder: 0)
        let edited = LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 8,
                               t: day(0).addingTimeInterval(35),
                               supersetGroupID: "grp", supersetOrder: 1,
                               supersetTransitionSeconds: 35)
        // A later member logged after the set being edited must not become the
        // "previous" set either — the receipt re-derives at the ORIGINAL time.
        let later = LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8,
                              t: day(0).addingTimeInterval(200),
                              supersetGroupID: "grp", supersetOrder: 0,
                              supersetTransitionSeconds: 165)

        let receipt = AtriaStrengthLog.supersetReceipt(exercise: "Bench press",
                                                       group: group,
                                                       priorSets: [first, edited, later],
                                                       excludingSetID: edited.id,
                                                       now: edited.t)
        XCTAssertEqual(receipt.transitionSeconds ?? -1, 35, accuracy: 0.001,
                       "the transition must re-derive from the set BEFORE the edited one")
    }

    func testLoggedSetSupersetFieldsSurviveJSONRoundTrip() throws {
        let set = LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 8.5,
                            t: day(0), effectiveLoadKg: 80,
                            supersetGroupID: "grp", supersetOrder: 1,
                            supersetTransitionSeconds: 42)
        let restored = try JSONDecoder().decode(LoggedSet.self,
                                                from: JSONEncoder().encode(set))
        XCTAssertEqual(restored, set)
        XCTAssertEqual(restored.supersetGroupID, "grp")
        XCTAssertEqual(restored.supersetOrder, 1)
        XCTAssertEqual(restored.supersetTransitionSeconds ?? -1, 42, accuracy: 0.001)
    }

    /// The live-logger behaviors that cannot run headless stay pinned: an edit
    /// preserves identity/timestamp/receipt, regrouping reuses the group id,
    /// and Ungroup never touches logged sets.
    func testLiveLoggerSupersetPathsStayReceiptPreserving() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaLiveWorkoutView.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("let setTime = editingOriginal?.t ?? Date()"),
                      "an edit must keep the original timestamp")
        XCTAssertTrue(source.contains("set.id = editingOriginal.id"),
                      "an edit must keep the original set identity")
        XCTAssertTrue(source.contains("transitionSeconds: editingOriginal.supersetTransitionSeconds"),
                      "an unchanged-movement edit must keep the original receipt")
        XCTAssertTrue(source.contains("excludingSetID: editingOriginal?.id"),
                      "a re-derived receipt must exclude the edited set itself")
        XCTAssertTrue(source.contains("StrengthSuperset(id: activeSuperset?.id ?? UUID().uuidString,"),
                      "regrouping must reuse the existing group id")
        XCTAssertTrue(source.contains("Button(\"Ungroup\") { activeSuperset = nil; supersetMembers.removeAll(); showsSupersetEditor = false }"),
                      "Ungroup must only clear the active group, never logged sets")
    }

    func testDensityCountsOnlyQuickTransitionsAndCapsAtFifteenPercent() throws {
        func supersetSet(_ index: Int, transition: TimeInterval?) -> LoggedSet {
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8,
                      t: day(0).addingTimeInterval(Double(index) * 120),
                      supersetGroupID: "grp", supersetOrder: index % 2,
                      supersetTransitionSeconds: transition)
        }
        let boundary = [supersetSet(0, transition: 90), supersetSet(1, transition: 91)]
        let boundaryReceipt = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: boundary))
        XCTAssertEqual(boundaryReceipt.densityBonusFraction, 0.03, accuracy: 0.0001,
                       "exactly 90 s counts as a quick handoff; 91 s is between-round rest")

        let six = (0..<6).map { supersetSet($0, transition: 30) }
        let capped = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: six))
        XCTAssertEqual(capped.densityBonusFraction, 0.15, accuracy: 0.0001,
                       "the density bonus saturates at 15%")
    }

    // MARK: - GAP-09: muscular input is deterministic, monotonic, and bounded

    func testMuscularInputIsDeterministicForIdenticalSavedSets() throws {
        let sets = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: 8, t: day(0)),
            LoggedSet(exercise: "Bench press", weightKg: 80, reps: 6, rpe: 7.5, t: day(0),
                      supersetGroupID: "grp", supersetOrder: 1, supersetTransitionSeconds: 45)
        ]
        let first = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: sets))
        let second = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: sets))
        XCTAssertEqual(first, second, "identical saved sets must produce identical receipts")
    }

    func testMuscularInputRisesMonotonicallyWithWeightRepsAndAddedSets() throws {
        func score(weight: Double, reps: Int, extraSet: Bool = false) throws -> Double {
            var sets = [LoggedSet(exercise: "Back squat", weightKg: weight, reps: reps, rpe: 8, t: day(0))]
            if extraSet {
                sets.append(LoggedSet(exercise: "Back squat", weightKg: weight, reps: reps, rpe: 8,
                                      t: day(0).addingTimeInterval(180)))
            }
            return try XCTUnwrap(try XCTUnwrap(
                AtriaStrengthLog.muscularLoadReceipt(for: sets)
            ).muscularInputScore)
        }

        try XCTAssertGreaterThan(score(weight: 110, reps: 5), score(weight: 100, reps: 5),
                                 "more weight must raise the muscular input")
        try XCTAssertGreaterThan(score(weight: 100, reps: 6), score(weight: 100, reps: 5),
                                 "more reps must raise the muscular input")
        try XCTAssertGreaterThan(score(weight: 100, reps: 5, extraSet: true),
                                 score(weight: 100, reps: 5),
                                 "an added qualified set must raise the muscular input")
    }

    func testMuscularInputSaturatesAtOneHundred() throws {
        let extreme = (0..<60).map { index in
            LoggedSet(exercise: "Back squat", weightKg: 250, reps: 10, rpe: 10,
                      t: day(0).addingTimeInterval(Double(index) * 60),
                      supersetGroupID: "grp", supersetOrder: index % 2,
                      supersetTransitionSeconds: 30)
        }
        let receipt = try XCTUnwrap(AtriaStrengthLog.muscularLoadReceipt(for: extreme))
        let score = try XCTUnwrap(receipt.muscularInputScore)
        XCTAssertLessThanOrEqual(score, 100)
        XCTAssertGreaterThan(score, 99, "an extreme session should approach the bound, not exceed it")
    }

    // MARK: - Set table

    func testSetTableRowsBadgeOnlyRealRecordsAndKeepRPEBlankWhenUnset() {
        let sets = [
            LoggedSet(exercise: "Back squat", weightKg: 100, reps: 5, rpe: nil, t: day(0)),
            LoggedSet(exercise: "Bench press", weightKg: 80, reps: 5, rpe: nil, t: day(0)),
            LoggedSet(exercise: "Back squat", weightKg: 115, reps: 5, rpe: 8.5, t: day(0))
        ]
        // Seeded so the first row loses on every arm of the app's own PR rule:
        // lighter than the top weight, below the best e1RM, and fewer reps than
        // this exact weight has already carried.
        var records = StrengthPersonalRecords()
        records.accept(LoggedSet(exercise: "Back squat", weightKg: 100, reps: 8, rpe: nil, t: day(-14)))
        records.accept(LoggedSet(exercise: "Back squat", weightKg: 110, reps: 5, rpe: nil, t: day(-7)))

        let rows = AtriaStrengthSetTablePresentation.rows(sets: sets,
                                                          exercise: "back squat",
                                                          records: records,
                                                          editingSetID: sets[2].id)

        XCTAssertEqual(rows.count, 2, "only the selected exercise's sets are listed")
        XCTAssertEqual(rows.map(\.number), [1, 2])
        XCTAssertFalse(rows[0].isPersonalRecord, "100 kg x 5 beats nothing already saved")
        XCTAssertTrue(rows[1].isPersonalRecord)
        XCTAssertEqual(rows[0].rpeText, "--")
        XCTAssertEqual(rows[1].rpeText, "8.5")
        XCTAssertEqual(rows[1].weightText, "115")
        XCTAssertTrue(rows[1].isEditing)
    }

    func testRestRingCountsDownAgainstTheRealTarget() {
        let end = origin.addingTimeInterval(90)
        XCTAssertEqual(AtriaStrengthSetTablePresentation.restRemainingText(now: origin, end: end), "1:30")
        XCTAssertEqual(AtriaStrengthSetTablePresentation.restFraction(now: origin, end: end, target: 120),
                       0.75, accuracy: 0.0001)
        XCTAssertEqual(AtriaStrengthSetTablePresentation.restFraction(now: end.addingTimeInterval(30),
                                                                      end: end,
                                                                      target: 120),
                       0, accuracy: 0.0001)
    }
}
