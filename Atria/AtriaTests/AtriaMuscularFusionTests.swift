import XCTest
@testable import Atria

/// WP-8 / GAP-09 — muscular ⊕ cardiovascular fusion: deterministic, monotone,
/// bounded, zero-neutral for cardio-only days, and identical across surfaces.
final class AtriaMuscularFusionTests: XCTestCase {
    func testMuscularEquivalentIsZeroNeutralMonotoneAndBounded() {
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: nil), 0,
                       "no logged effort-complete receipt → exactly zero")
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 0), 0)
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: -5), 0)

        var previous = 0.0
        for score in stride(from: 5.0, through: 100, by: 5) {
            let equivalent = AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: score)
            XCTAssertGreaterThan(equivalent, previous,
                                 "the fusion input must rise strictly with the muscular score")
            previous = equivalent
        }
        XCTAssertEqual(previous, AtriaStrainLoadModel.muscularEquivalentCeiling, accuracy: 0.001,
                       "score 100 lands exactly on the documented ceiling")
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 500),
                       AtriaStrainLoadModel.muscularEquivalentCeiling,
                       "the equivalent never exceeds the ceiling")
    }

    func testDayTotalOnlyCountsEffortCompleteReceipts() {
        func workout(id: String, receipt: AtriaStrengthLog.MuscularLoadReceipt?) -> UserConfirmedWorkout {
            var value = UserConfirmedWorkout(id: id,
                                             createdAt: Date(timeIntervalSince1970: 1_783_900_000),
                                             start: Date(timeIntervalSince1970: 1_783_900_000),
                                             end: Date(timeIntervalSince1970: 1_783_903_600),
                                             label: "Strength",
                                             source: "live_workout_window",
                                             confidence: "live_window_user_confirmed",
                                             sessions: 1,
                                             samples: 600,
                                             avgHR: 110,
                                             peakHR: 150,
                                             p95HR: 140,
                                             p99HR: 148,
                                             thresholdHR: 140,
                                             streamCoveragePercent: 90,
                                             observedDuration: 3_600,
                                             reason: "test",
                                             eventTimeZoneIdentifier: "Asia/Kolkata")
            value.muscularLoadReceipt = receipt
            return value
        }
        func receipt(score: Double?) -> AtriaStrengthLog.MuscularLoadReceipt {
            AtriaStrengthLog.MuscularLoadReceipt(calculationVersion: 1,
                                                 setCount: 5,
                                                 loadQualifiedSetCount: 5,
                                                 effortQualifiedSetCount: score == nil ? 3 : 5,
                                                 externalVolumeKg: 2_000,
                                                 effectiveVolumeKg: 2_000,
                                                 densityBonusFraction: 0,
                                                 muscularInputScore: score,
                                                 movementClasses: [.externalLoad])
        }

        let total = SessionStore.muscularTRIMPEquivalentTotal([
            workout(id: "scored", receipt: receipt(score: 60)),
            workout(id: "incomplete-rpe", receipt: receipt(score: nil)),
            workout(id: "unlogged", receipt: nil),
        ])
        XCTAssertEqual(total,
                       AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 60),
                       accuracy: 0.001,
                       "unlogged and RPE-incomplete sessions must contribute exactly zero")

        XCTAssertEqual(SessionStore.muscularTRIMPEquivalentTotal([workout(id: "none", receipt: nil)]), 0)
    }

    func testFusedDayStrainElevatesStrengthDaysAndLeavesCardioOnlyDaysUntouched() {
        let cardioTRIMP = 40.0
        let cardioOnly = Metrics.strain(fromTRIMP: cardioTRIMP + AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: nil))
        XCTAssertEqual(cardioOnly, Metrics.strain(fromTRIMP: cardioTRIMP),
                       "a cardio-only day's Strain is bit-identical after fusion")

        let fused = Metrics.strain(fromTRIMP: cardioTRIMP + AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 70))
        XCTAssertGreaterThan(fused, cardioOnly,
                             "a logged strength day must elevate the day total")
        XCTAssertLessThanOrEqual(fused, 21, "the display scale stays bounded")

        // Explainability: the delta is reproducible from the documented formula.
        let expectedEquivalent = AtriaStrainLoadModel.muscularEquivalentCeiling * pow(0.7, AtriaStrainLoadModel.muscularEquivalentExponent)
        XCTAssertEqual(AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 70),
                       expectedEquivalent, accuracy: 0.0001)
    }

    /// GAP-09 regression (app-vs-widget Strain parity): logged strength load
    /// must reach today's FUSED Strain TRIMP, which is the exact quantity the
    /// Home hero and the widget must agree on. The reducer yields zero muscular
    /// when `confirmedWorkouts` is not threaded — the old off-MainActor Home bug
    /// where the hero briefly showed muscular at cold-start seed, then dropped
    /// it once the async refresh published — and the full equivalent when it is
    /// (the widget behaviour the hero now matches).
    func testHomeSavedAggregateFusesConfirmedMuscularWorkoutIntoDayTRIMP() {
        let day = Date(timeIntervalSince1970: 1_783_890_000)
        let now = Date(timeIntervalSince1970: 1_783_910_000)
        let workout = confirmedStrengthWorkout(
            start: Date(timeIntervalSince1970: 1_783_900_000),
            end: Date(timeIntervalSince1970: 1_783_903_600),
            score: 65
        )

        // Off-MainActor Home path BEFORE the fix passed no confirmedWorkouts, so
        // muscular load silently vanished from the hero after the async refresh.
        let withoutWorkouts = SessionStore.homeSavedAggregate(
            from: [],
            rest: 60,
            maxHR: 190,
            biologicalSex: .male,
            now: now,
            cycleStart: day
        )
        XCTAssertEqual(withoutWorkouts.savedTodayMuscularTRIMP, 0)
        XCTAssertEqual(withoutWorkouts.savedTodayTRIMP, 0)

        // Widget path (and the fixed Home path) thread the confirmed workouts, so
        // the muscular equivalent fuses into the same day TRIMP total.
        let expected = AtriaStrainLoadModel.muscularTRIMPEquivalent(inputScore: 65)
        XCTAssertGreaterThan(expected, 0, "the fixture score must produce nonzero muscular load")
        let withWorkouts = SessionStore.homeSavedAggregate(
            from: [],
            rest: 60,
            maxHR: 190,
            biologicalSex: .male,
            now: now,
            cycleStart: day,
            confirmedWorkouts: [workout]
        )
        XCTAssertEqual(withWorkouts.savedTodayMuscularTRIMP, expected, accuracy: 0.001)
        XCTAssertEqual(withWorkouts.savedTodayTRIMP, expected, accuracy: 0.001,
                       "logged muscular load must fuse into today's Strain TRIMP")
    }

    /// GAP-09 wiring guard: the off-MainActor Home refresh must thread the
    /// confirmed workouts into BOTH aggregate reductions — the main window and
    /// the pre-boundary continuous fold — so the hero's day Strain fuses the
    /// same muscular load the widget does. A source scan (matching the sibling
    /// `…ExcludesConfirmedSleepLikeHome` guard) keeps the two surfaces in
    /// lockstep even though `makeSavedAggregate(input:)` is private.
    func testOffMainActorHomeRefreshThreadsConfirmedWorkoutsLikeWidget() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")

        let homeSource = try String(
            contentsOf: base.appendingPathComponent("AtriaHomeView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            homeSource.range(of: "private nonisolated static func makeSavedAggregate(")
        )
        let end = try XCTUnwrap(
            homeSource.range(of: "private func scheduleSavedAggregateCycleRolloverRefresh",
                             range: start.upperBound..<homeSource.endIndex)
        )
        let body = String(homeSource[start.lowerBound..<end.lowerBound])
        let threadedCalls = body.components(
            separatedBy: "confirmedWorkouts: input.source.confirmedWorkouts"
        ).count - 1
        XCTAssertEqual(threadedCalls, 2,
                       "both the main aggregate and the pre-boundary fold must fuse muscular load")

        // The immutable source snapshot must actually carry the array across the
        // MainActor → utility-worker hop, and the producer must populate it.
        let sessionsSource = try String(
            contentsOf: base.appendingPathComponent("Sessions.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            sessionsSource.contains("let confirmedWorkouts: [UserConfirmedWorkout]"),
            "HomeSavedAggregateSourceSnapshot must carry confirmedWorkouts"
        )
        XCTAssertTrue(
            sessionsSource.contains("confirmedWorkouts: cachedConfirmedWorkouts"),
            "the snapshot producer must populate confirmedWorkouts from the cache"
        )
    }

    private func confirmedStrengthWorkout(start: Date,
                                          end: Date,
                                          score: Double) -> UserConfirmedWorkout {
        var value = UserConfirmedWorkout(id: "muscular-\(Int(score))",
                                         createdAt: start,
                                         start: start,
                                         end: end,
                                         label: "Strength",
                                         source: "live_workout_window",
                                         confidence: "live_window_user_confirmed",
                                         sessions: 1,
                                         samples: 600,
                                         avgHR: 110,
                                         peakHR: 150,
                                         p95HR: 140,
                                         p99HR: 148,
                                         thresholdHR: 140,
                                         streamCoveragePercent: 90,
                                         observedDuration: end.timeIntervalSince(start),
                                         reason: "test",
                                         eventTimeZoneIdentifier: "Asia/Kolkata")
        value.muscularLoadReceipt = AtriaStrengthLog.MuscularLoadReceipt(
            calculationVersion: 1,
            setCount: 5,
            loadQualifiedSetCount: 5,
            effortQualifiedSetCount: 5,
            externalVolumeKg: 2_000,
            effectiveVolumeKg: 2_000,
            densityBonusFraction: 0,
            muscularInputScore: score,
            movementClasses: [.externalLoad]
        )
        return value
    }
}
