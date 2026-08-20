import XCTest
@testable import Atria

/// Confirmed-sleep re-context pass (2026-08-20 device evidence: overnight
/// minutes in `Atria/stress-history-v3` carried sleepContext "unavailable"
/// because the live sleep authority never publishes — issue #30 — and stored
/// facts were never revisited once the sleep WAS confirmed, so sleeping REM
/// heart rate rendered as moderate/high stress).
///
/// These tests pin the honesty contract of the pass: the pure planner names
/// only sleep-context labels using the exact >=80% five-minute window
/// coverage the kernel scores with, the store relabels stored minutes without
/// touching a single score byte, reversal follows sleep deletion, a second
/// identical pass writes nothing, and durability rewrites only the hour
/// shards whose minutes actually changed.
final class AtriaStressSleepRecontextTests: XCTestCase {
    /// Hour-aligned fixture base, deliberately after 2026-08-06 (older anchors
    /// are contaminated by the host's persisted device-use journal).
    private let hourBase = Date(timeIntervalSince1970: 1_803_002_400)
    private var now: Date { hourBase.addingTimeInterval(4 * 3_600) }
    private let minute = AtriaPhysiologicalStressModel.evaluationCadence
    private let window = AtriaPhysiologicalStressModel.windowDuration

    private var personalization: AtriaPhysiologicalStressModel.Personalization {
        .init(restingHeartRate: 58,
              maximumHeartRate: 190,
              restingBaselineDayCount: 20,
              hrvBaseline: nil)
    }

    // MARK: - Pure planner

    func testPlannerMatchesKernelWindowCoverageBoundaries() {
        let sleepStart = hourBase.addingTimeInterval(600)
        let sleepEnd = sleepStart.addingTimeInterval(30 * 60)
        let sleep = AtriaHistoricalStressReplay.SleepContextInterval(
            start: sleepStart,
            end: sleepEnd
        )
        // A minute fact at date D covers the exact score window [D-300, D];
        // it qualifies as asleep at >=80% coverage (240 s), the same
        // convention `qualifiedSleepContext` scores replays with.
        let lastInsufficientEntry = sleepStart.addingTimeInterval(239)
        let earliestQualified = sleepStart.addingTimeInterval(240)
        let interior = sleepStart.addingTimeInterval(900)
        let latestQualified = sleepEnd.addingTimeInterval(60)
        let firstInsufficientExit = sleepEnd.addingTimeInterval(61)
        let facts = [
            lastInsufficientEntry,
            earliestQualified,
            interior,
            latestQualified,
            firstInsufficientExit,
        ].map { liveFact(at: $0) }

        let plan = AtriaHistoricalStressReplay.planSleepRecontext(
            facts: facts,
            sleepContexts: [sleep]
        )
        XCTAssertEqual(plan.map(\.date),
                       [earliestQualified, interior, latestQualified],
                       "239 s of coverage must stay unavailable; 240 s becomes asleep")
        XCTAssertTrue(plan.allSatisfy { $0.sleepContext == .asleep })
    }

    func testPlannerTreatsTouchingIntervalsAsZeroCoverageAndUnionsSplitWindows() {
        let date = hourBase.addingTimeInterval(3_000)
        // Intervals that only touch the score window's boundaries contribute
        // nothing: an interval ending exactly at the lookback start and one
        // starting exactly at the minute itself are both outside the
        // half-open overlap the sweep admits.
        let endsAtLookbackStart = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date.addingTimeInterval(-400),
            end: date.addingTimeInterval(-window)
        )
        let startsAtMinute = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date,
            end: date.addingTimeInterval(600)
        )
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [liveFact(at: date)],
                sleepContexts: [endsAtLookbackStart, startsAtMinute]
            ).isEmpty,
            "boundary-touching intervals must never relabel a minute"
        )

        // Two disjoint qualified windows whose union reaches exactly 80% of
        // the score window qualify together.
        let firstHalf = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date.addingTimeInterval(-300),
            end: date.addingTimeInterval(-180)
        )
        let secondHalf = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date.addingTimeInterval(-120),
            end: date
        )
        let unioned = AtriaHistoricalStressReplay.planSleepRecontext(
            facts: [liveFact(at: date)],
            sleepContexts: [firstHalf, secondHalf]
        )
        XCTAssertEqual(unioned,
                       [.init(date: date, sleepContext: .asleep)],
                       "split windows must union to the exact coverage threshold")
    }

    func testPlannerIsMinimalRevertsOutsideWindowsSkipsAwakeAndIsIdempotent() {
        let sleep = AtriaHistoricalStressReplay.SleepContextInterval(
            start: hourBase,
            end: hourBase.addingTimeInterval(1_200)
        )
        let facts = [
            liveFact(at: hourBase.addingTimeInterval(60)),
            liveFact(at: hourBase.addingTimeInterval(300), sleepContext: .asleep),
            liveFact(at: hourBase.addingTimeInterval(360)),
            liveFact(at: hourBase.addingTimeInterval(420), sleepContext: .awake),
            liveFact(at: hourBase.addingTimeInterval(1_800), sleepContext: .asleep),
            liveFact(at: hourBase.addingTimeInterval(1_860), sleepContext: .awake),
        ]

        let plan = AtriaHistoricalStressReplay.planSleepRecontext(
            facts: facts,
            sleepContexts: [sleep]
        )
        XCTAssertEqual(plan, [
            .init(date: hourBase.addingTimeInterval(360), sleepContext: .asleep),
            .init(date: hourBase.addingTimeInterval(1_800),
                  sleepContext: .unavailable),
        ], """
        exactly one uncovered relabel and one reversal: agreeing minutes are \
        not re-planned, insufficient coverage is not relabelled, and an \
        explicit awake claim is never rewritten in either direction
        """)

        // Applying the plan and planning again names nothing.
        let planByDate = Dictionary(uniqueKeysWithValues: plan.map {
            ($0.date, $0.sleepContext)
        })
        let relabelled = facts.map { fact in
            planByDate[fact.date].map(fact.relabelingSleepContext) ?? fact
        }
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: relabelled,
                sleepContexts: [sleep]
            ).isEmpty,
            "a second pass over relabelled facts must plan nothing"
        )
    }

    func testPlannerTreatsUnqualifiedWindowsAsNoCoverage() {
        let unqualified = AtriaHistoricalStressReplay.SleepContextInterval(
            start: hourBase,
            end: hourBase.addingTimeInterval(1_200),
            qualified: false
        )
        let plan = AtriaHistoricalStressReplay.planSleepRecontext(
            facts: [
                liveFact(at: hourBase.addingTimeInterval(300)),
                liveFact(at: hourBase.addingTimeInterval(360),
                         sleepContext: .asleep),
            ],
            sleepContexts: [unqualified]
        )
        XCTAssertEqual(plan, [
            .init(date: hourBase.addingTimeInterval(360),
                  sleepContext: .unavailable),
        ], "an unqualified interval is not sleep authority; a stale asleep inside it reverts")
    }

    func testPlannerFailsClosedOnMalformedFactsOrWindows() {
        let date = hourBase.addingTimeInterval(600)
        let needsRelabel = liveFact(at: date)
        let covering = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date.addingTimeInterval(-window),
            end: date
        )
        XCTAssertFalse(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [needsRelabel],
                sleepContexts: [covering]
            ).isEmpty,
            "fixture sanity: the well-formed inputs do plan a relabel"
        )

        let laterWindow = AtriaHistoricalStressReplay.SleepContextInterval(
            start: date.addingTimeInterval(600),
            end: date.addingTimeInterval(1_200)
        )
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [needsRelabel],
                sleepContexts: [laterWindow, covering]
            ).isEmpty,
            "unsorted windows must plan nothing rather than mis-sweep"
        )
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [needsRelabel],
                sleepContexts: [.init(start: date, end: date)]
            ).isEmpty,
            "an empty interval is malformed authority"
        )
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [needsRelabel, liveFact(at: date.addingTimeInterval(-60))],
                sleepContexts: [covering]
            ).isEmpty,
            "out-of-order minutes must plan nothing"
        )
        XCTAssertTrue(
            AtriaHistoricalStressReplay.planSleepRecontext(
                facts: [needsRelabel, needsRelabel],
                sleepContexts: [covering]
            ).isEmpty,
            "duplicate minute identities must plan nothing"
        )
    }

    // MARK: - Replay result authority

    func testEvaluateCarriesSleepAuthorityOnlyForValidatedSnapshots() {
        let sleep = AtriaHistoricalStressReplay.SleepContextInterval(
            start: hourBase,
            end: hourBase.addingTimeInterval(3_600)
        )
        let validated = AtriaHistoricalStressReplay.evaluate(
            AtriaHistoricalStressReplay.Snapshot(sessions: [],
                                                 sleepContexts: [sleep],
                                                 personalization: personalization,
                                                 now: now)
        )
        XCTAssertEqual(validated.sleepContextAuthority, [sleep],
                       "a validated empty source still publishes its complete window set")
        XCTAssertFalse(validated.managedRanges.isEmpty)

        let malformed = AtriaHistoricalStressReplay.evaluate(
            AtriaHistoricalStressReplay.Snapshot(
                sessions: [],
                sleepContexts: [.init(start: now, end: now)],
                personalization: personalization,
                now: now
            )
        )
        XCTAssertNil(malformed.sleepContextAuthority,
                     "a failed replay must never carry relabel authority")
        XCTAssertNil(AtriaHistoricalStressReplay.Result.empty.sleepContextAuthority)
    }

    // MARK: - Store wiring

    @MainActor
    func testContextOnlyMergeRelabelsLiveMinutesRevertsOnDeletionAndPreservesScores() async throws {
        let (persistence, directory) = makePersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let points = (0..<30).map { index in
            livePoint(at: hourBase.addingTimeInterval(Double(index) * minute),
                      score: 1.1 + Double(index) * 0.037)
        }
        let saved = await persistence.save(
            AtriaStressHistoryArchive(points: points),
            now: now
        )
        XCTAssertTrue(saved)

        let store = AtriaStressMonitorStore(
            historyPersistence: persistence,
            historyLoadNow: now,
            presentationPublishingIsActive: false,
            applicationIsActive: { false }
        )
        await store.waitForHistoryHydration()
        let original = store.history
        XCTAssertEqual(original.count, 30)
        XCTAssertTrue(original.allSatisfy {
            $0.minuteFact?.sleepContext == .unavailable
        })

        // Malformed authority fails the whole publication closed.
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [],
                  heartRates: [],
                  sleepContextAuthority: [.init(
                      start: hourBase.addingTimeInterval(1_800),
                      end: hourBase.addingTimeInterval(600)
                  )]),
            now: now
        )
        XCTAssertEqual(store.history, original)

        // Sleep [base+600, base+1800]: minutes 14...29 reach >=80% coverage.
        let sleep = AtriaHistoricalStressReplay.SleepContextInterval(
            start: hourBase.addingTimeInterval(600),
            end: hourBase.addingTimeInterval(1_800)
        )
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: [], sleepContextAuthority: [sleep]),
            now: now
        )
        await store.waitForPendingHistoryCheckpoint()

        for (index, point) in store.history.enumerated() {
            let fact = try XCTUnwrap(point.minuteFact)
            let expected: AtriaPhysiologicalStressModel.SleepContext =
                (14...29).contains(index) ? .asleep : .unavailable
            XCTAssertEqual(fact.sleepContext, expected, "minute \(index)")
            XCTAssertEqual(point.factSource, .live,
                           "relabelling must not launder acquisition provenance")
            let originalFact = try XCTUnwrap(original[index].minuteFact)
            assertScoreFieldsBytePreserved(originalFact, fact,
                                           minuteIndex: index)
            XCTAssertEqual(point.activation.bitPattern,
                           original[index].activation.bitPattern)
            XCTAssertEqual(point.level, original[index].level)
            XCTAssertEqual(point.confidence.bitPattern,
                           original[index].confidence.bitPattern)
        }

        // An identical second pass changes nothing.
        let afterRelabel = store.history
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: [], sleepContextAuthority: [sleep]),
            now: now
        )
        XCTAssertEqual(store.history, afterRelabel,
                       "the re-context pass must be idempotent")

        // Nil authority (failed replay, legacy/test ingestion) never reverts.
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: []),
            now: now
        )
        XCTAssertEqual(store.history, afterRelabel,
                       "absence of authority must not undo a confirmed relabel")

        // Deleting the sleep — an authoritative empty window set — reverts
        // every stale asleep label and restores the exact original timeline.
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: [], sleepContextAuthority: []),
            now: now
        )
        await store.waitForPendingHistoryCheckpoint()
        XCTAssertEqual(store.history, original,
                       "reversal must restore the exact pre-relabel timeline")
    }

    @MainActor
    func testContextOnlyMergeRewritesOnlyChangedHourShards() async throws {
        let (persistence, directory) = makePersistence()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hour2 = hourBase.addingTimeInterval(2 * 3_600)
        // Hour 1 is deliberately empty so the drain's paired-hour hop has no
        // adjacent rollover shard to close: only hour 2 may change on disk.
        var points: [AtriaStressHistoryArchive.Point] = []
        for index in 0..<6 {
            points.append(livePoint(
                at: hourBase.addingTimeInterval(Double(index) * minute),
                score: 0.9
            ))
        }
        for index in 10..<30 {
            points.append(livePoint(
                at: hour2.addingTimeInterval(Double(index) * minute),
                score: 1.7
            ))
        }
        for index in 30..<36 {
            points.append(livePoint(
                at: hourBase.addingTimeInterval(
                    3 * 3_600 + Double(index) * minute
                ),
                score: 1.2
            ))
        }
        let saved = await persistence.save(
            AtriaStressHistoryArchive(points: points),
            now: now
        )
        XCTAssertTrue(saved)

        let store = AtriaStressMonitorStore(
            historyPersistence: persistence,
            historyLoadNow: now,
            presentationPublishingIsActive: false,
            applicationIsActive: { false }
        )
        await store.waitForHistoryHydration()
        XCTAssertEqual(store.history.count, 32)

        let hour0URL = persistence.shardURL(containing: hourBase)
        let hour1URL = persistence.shardURL(
            containing: hourBase.addingTimeInterval(3_600)
        )
        let hour2URL = persistence.shardURL(containing: hour2)
        let hour3URL = persistence.shardURL(
            containing: hourBase.addingTimeInterval(3 * 3_600)
        )
        let hour0Before = try shardState(at: hour0URL)
        let hour2Before = try shardState(at: hour2URL)
        let hour3Before = try shardState(at: hour3URL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hour1URL.path))
        XCTAssertFalse(String(decoding: hour2Before.bytes, as: UTF8.self)
            .contains("\"asleep\""))

        // Sleep inside hour 2 only: minutes 14...29 of that hour change.
        let sleep = AtriaHistoricalStressReplay.SleepContextInterval(
            start: hour2.addingTimeInterval(600),
            end: hour2.addingTimeInterval(1_800)
        )
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: [], sleepContextAuthority: [sleep]),
            now: now
        )
        await store.waitForPendingHistoryCheckpoint()
        await persistence.drainWrites()

        let hour0After = try shardState(at: hour0URL)
        let hour2After = try shardState(at: hour2URL)
        let hour3After = try shardState(at: hour3URL)
        XCTAssertTrue(String(decoding: hour2After.bytes, as: UTF8.self)
            .contains("\"asleep\""),
                      "the changed hour's shard must carry the relabel durably")
        XCTAssertNotEqual(hour2After.bytes, hour2Before.bytes)
        XCTAssertEqual(hour0After, hour0Before,
                       "an hour with no changed minute must not be rewritten")
        XCTAssertEqual(hour3After, hour3Before,
                       "an hour with no changed minute must not be rewritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hour1URL.path),
                       "the drain must not invent a shard for an empty hour")

        // An identical second pass writes nothing at all.
        await store.mergeHistoricalMinuteFacts(
            .init(facts: [], heartRates: [], sleepContextAuthority: [sleep]),
            now: now
        )
        await store.waitForPendingHistoryCheckpoint()
        await persistence.drainWrites()
        XCTAssertEqual(try shardState(at: hour0URL), hour0After)
        XCTAssertEqual(try shardState(at: hour2URL), hour2After)
        XCTAssertEqual(try shardState(at: hour3URL), hour3After)
    }

    // MARK: - Fixtures

    private struct ShardState: Equatable {
        let bytes: Data
        let modifiedAt: Date?
    }

    private func shardState(at url: URL) throws -> ShardState {
        ShardState(
            bytes: try Data(contentsOf: url),
            modifiedAt: try FileManager.default
                .attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
    }

    private func makePersistence() -> (AtriaStressHistoryPersistence, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "atria-stress-recontext-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        return (AtriaStressHistoryPersistence(directoryURL: directory), directory)
    }

    /// A structurally valid HR-only live minute fact whose scored fields are
    /// deliberately minute-specific, so byte-preservation assertions cannot
    /// pass by field coincidence.
    private func liveFact(
        at date: Date,
        score: Double = 1.8,
        sleepContext: AtriaPhysiologicalStressModel.SleepContext = .unavailable
    ) -> AtriaPhysiologicalStressModel.MinuteFact {
        .init(date: date,
              score: score,
              unsmoothedScore: min(score + 0.05, 3),
              meanHeartRate: 84 + Double(Int(date.timeIntervalSince1970) % 7),
              rmssd: nil,
              hrStress: min(score / 3, 1),
              hrvStress: nil,
              heartRateWeight: 1,
              motionContext: .unavailable,
              sleepContext: sleepContext,
              confidence: .low,
              baselineLearning: true)
    }

    private func livePoint(
        at date: Date,
        score: Double
    ) -> AtriaStressHistoryArchive.Point {
        let fact = liveFact(at: date, score: score)
        let level: AtriaStressLevel
        switch fact.zone {
        case .calm: level = .calm
        case .moderate: level = .medium
        case .high: level = .high
        }
        return .init(t: date,
                     activation: fact.score / 3,
                     level: level,
                     confidence: fact.confidence.numericValue,
                     hrvAvailable: false,
                     minuteFact: fact,
                     factSource: .live)
    }

    private func assertScoreFieldsBytePreserved(
        _ original: AtriaPhysiologicalStressModel.MinuteFact,
        _ relabelled: AtriaPhysiologicalStressModel.MinuteFact,
        minuteIndex: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(original.date, relabelled.date,
                       "minute \(minuteIndex)", file: file, line: line)
        XCTAssertEqual(original.score.bitPattern,
                       relabelled.score.bitPattern,
                       "minute \(minuteIndex) score", file: file, line: line)
        XCTAssertEqual(original.unsmoothedScore.bitPattern,
                       relabelled.unsmoothedScore.bitPattern,
                       "minute \(minuteIndex) unsmoothedScore",
                       file: file, line: line)
        XCTAssertEqual(original.meanHeartRate.bitPattern,
                       relabelled.meanHeartRate.bitPattern,
                       "minute \(minuteIndex) meanHeartRate",
                       file: file, line: line)
        XCTAssertEqual(original.rmssd?.bitPattern,
                       relabelled.rmssd?.bitPattern,
                       "minute \(minuteIndex) rmssd", file: file, line: line)
        XCTAssertEqual(original.hrStress.bitPattern,
                       relabelled.hrStress.bitPattern,
                       "minute \(minuteIndex) hrStress", file: file, line: line)
        XCTAssertEqual(original.hrvStress?.bitPattern,
                       relabelled.hrvStress?.bitPattern,
                       "minute \(minuteIndex) hrvStress", file: file, line: line)
        XCTAssertEqual(original.heartRateWeight.bitPattern,
                       relabelled.heartRateWeight.bitPattern,
                       "minute \(minuteIndex) heartRateWeight",
                       file: file, line: line)
        XCTAssertEqual(original.motionContext, relabelled.motionContext,
                       "minute \(minuteIndex) motionContext",
                       file: file, line: line)
        XCTAssertEqual(original.confidence, relabelled.confidence,
                       "minute \(minuteIndex) confidence",
                       file: file, line: line)
        XCTAssertEqual(original.baselineLearning, relabelled.baselineLearning,
                       "minute \(minuteIndex) baselineLearning",
                       file: file, line: line)
        XCTAssertEqual(original.scoringVersion, relabelled.scoringVersion,
                       "minute \(minuteIndex) scoringVersion",
                       file: file, line: line)
    }
}
