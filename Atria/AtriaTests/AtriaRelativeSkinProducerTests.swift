import XCTest
@testable import Atria

/// Handoff-8 CP3: the relative-skin producer plan, night store, and copy
/// policy. The pure per-night math is covered in
/// `AtriaRelativeSkinSignalTests`; these tests pin the proof chain around it —
/// completeness receipts, authority separation, invalidation, persistence
/// round-trips, and the blocker-first presentation contract.
final class AtriaRelativeSkinProducerTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryDirectories { try? FileManager.default.removeItem(at: url) }
        temporaryDirectories.removeAll()
    }

    // MARK: - Fixture

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// One qualified night: a two-hour main sleep with one worn-range row per
    /// minute (120 rows ≥ 100, 120 covered minutes ≥ 60, full coverage).
    private func sleep(_ index: Int, source: String = "auto") -> AtriaRelativeSkinSleepWindow {
        let start = base.addingTimeInterval(Double(index) * 86_400)
        let end = start.addingTimeInterval(2 * 3_600)
        return .init(id: "sleep-\(index)",
                     start: start,
                     end: end,
                     isNap: source.lowercased().contains("nap"),
                     revisionToken: AtriaRelativeSkinSleepWindow.revisionToken(
                        start: start, end: end, source: source))
    }

    private func rows(for sleep: AtriaRelativeSkinSleepWindow,
                      raw: Int,
                      strap: String? = "strap-a") -> [HistoricalArchive.SkinTemperatureRawPoint] {
        stride(from: 0.0, to: sleep.end.timeIntervalSince(sleep.start), by: 60)
            .map { offset in
                .init(t: sleep.start.addingTimeInterval(offset + 1),
                      raw: raw,
                      strapIdentifier: strap)
            }
    }

    private func environment(complete: Bool = true,
                             drainedThrough: Date) -> AtriaRelativeSkinProducer.Environment {
        .init(snapshotChannelComplete: complete,
              drainedThroughUnix: drainedThrough.timeIntervalSince1970,
              now: drainedThrough,
              calendar: .current)
    }

    /// Builds `count` fully proven stored nights (indices 0..<count).
    private func provenNights(count: Int,
                              raw: Int = 1_200) -> (sleeps: [AtriaRelativeSkinSleepWindow],
                                                    stored: [AtriaRelativeSkinStoredNight]) {
        let sleeps = (0..<count).map { self.sleep($0) }
        let allRows = sleeps.flatMap { rows(for: $0, raw: raw) }
        let plan = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps,
            rows: allRows,
            stored: [],
            environment: environment(drainedThrough: sleeps.last!.end.addingTimeInterval(3_600))
        )
        return (sleeps, plan.nightsToPersist)
    }

    // MARK: - Baseline qualification

    func testSevenProvenPriorNightsQualifyAndSixStayBuildingBaseline() throws {
        // 8 nights: 7 priors + current. Current raw is +18 above the baseline.
        var (sleeps, _) = provenNights(count: 7)
        let current = sleep(7)
        sleeps.append(current)
        let allRows = sleeps.dropLast().flatMap { rows(for: $0, raw: 1_200) }
            + rows(for: current, raw: 1_218)
        let qualified = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps,
            rows: allRows,
            stored: [],
            environment: environment(drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertNil(qualified.uiSummary.blocker)
        XCTAssertEqual(qualified.uiSummary.baselineNightCount, 7)
        XCTAssertEqual(try XCTUnwrap(qualified.uiSummary.rawDelta), 18, accuracy: 0.001)
        XCTAssertFalse(qualified.uiSummary.motionQualified,
                       "No validated motion exists on this transport; a night must never claim stillness")

        // Exactly six priors: same shape minus one prior night.
        let sixSleeps = Array(sleeps.dropFirst())
        let sixRows = sixSleeps.dropLast().flatMap { rows(for: $0, raw: 1_200) }
            + rows(for: current, raw: 1_218)
        let building = AtriaRelativeSkinProducer.plan(
            sleeps: sixSleeps,
            rows: sixRows,
            stored: [],
            environment: environment(drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(building.uiSummary.blocker, .buildingBaseline)
        XCTAssertEqual(building.uiSummary.baselineNightCount, 6)
        XCTAssertNil(building.uiSummary.rawDelta,
                     "No numeric value may surface while the baseline is building")
    }

    func testAuthorityMismatchNightsNeverJoinTheBaseline() throws {
        // 7 priors on strap-a, current on strap-b: priors do not match the
        // current authority, so the result stays baseline-building.
        var (sleeps, _) = provenNights(count: 7)
        let current = sleep(7)
        sleeps.append(current)
        let allRows = sleeps.dropLast().flatMap { rows(for: $0, raw: 1_200) }
            + rows(for: current, raw: 1_218, strap: "strap-b")
        let plan = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps,
            rows: allRows,
            stored: [],
            environment: environment(drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(plan.uiSummary.blocker, .buildingBaseline)
        XCTAssertEqual(plan.uiSummary.baselineNightCount, 0)
        XCTAssertNil(plan.uiSummary.rawDelta)
    }

    func testMixedOrUnknownStrapWithinOneNightFailsClosed() throws {
        let current = sleep(0)
        let mixed = rows(for: current, raw: 1_200, strap: "strap-a")
            + [.init(t: current.start.addingTimeInterval(90),
                     raw: 1_210, strapIdentifier: "strap-b")]
        let mixedPlan = AtriaRelativeSkinProducer.plan(
            sleeps: [current],
            rows: mixed,
            stored: [],
            environment: environment(drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(mixedPlan.uiSummary.blocker, .mixedSensorAuthority)
        XCTAssertTrue(mixedPlan.nightsToPersist.isEmpty)

        let unknownPlan = AtriaRelativeSkinProducer.plan(
            sleeps: [current],
            rows: rows(for: current, raw: 1_200, strap: nil),
            stored: [],
            environment: environment(drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(unknownPlan.uiSummary.blocker, .unknownSensorAuthority)
        XCTAssertTrue(unknownPlan.nightsToPersist.isEmpty)
    }

    // MARK: - Completeness receipts

    func testUnprovenCurrentNightFailsClosedAsIncompleteArchive() throws {
        let current = sleep(0)
        // Frontier stops mid-window: the raw channel may be truncated.
        let truncated = AtriaRelativeSkinProducer.plan(
            sleeps: [current],
            rows: rows(for: current, raw: 1_200),
            stored: [],
            environment: environment(drainedThrough: current.start.addingTimeInterval(600))
        )
        XCTAssertEqual(truncated.uiSummary.blocker, .incompleteArchive)
        XCTAssertNil(truncated.uiSummary.rawDelta)
        XCTAssertTrue(truncated.nightsToPersist.isEmpty,
                      "An unproven night must never be persisted")

        // A budget-limited snapshot channel is equally unproven.
        let budgetLimited = AtriaRelativeSkinProducer.plan(
            sleeps: [current],
            rows: rows(for: current, raw: 1_200),
            stored: [],
            environment: environment(complete: false,
                                     drainedThrough: current.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(budgetLimited.uiSummary.blocker, .incompleteArchive)
        XCTAssertTrue(budgetLimited.nightsToPersist.isEmpty)
    }

    func testIndependentlyProvenNightsSurviveALaterUnrelatedGap() throws {
        // 8 proven persisted nights, then a later run under a global gap
        // (incomplete channel, regressed frontier, no rows). The stored
        // proofs stand: the current night still resolves numerically.
        var (sleeps, stored) = provenNights(count: 8)
        let gapPlan = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps,
            rows: [],
            stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        )
        XCTAssertNil(gapPlan.uiSummary.blocker,
                     "A global gap must not erase independently proven nights")
        XCTAssertEqual(gapPlan.uiSummary.baselineNightCount, 7)
        XCTAssertEqual(gapPlan.nightsToPersist.count, 8)

        // A brand-new ninth night under the same gap fails closed while the
        // proven history remains the baseline.
        let ninth = sleep(8)
        sleeps.append(ninth)
        let ninthPlan = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps,
            rows: rows(for: ninth, raw: 1_230),
            stored: stored,
            environment: environment(complete: false,
                                     drainedThrough: ninth.end.addingTimeInterval(3_600))
        )
        XCTAssertEqual(ninthPlan.uiSummary.blocker, .incompleteArchive)
        XCTAssertNil(ninthPlan.uiSummary.rawDelta)
        XCTAssertEqual(ninthPlan.nightsToPersist.count, 8,
                       "The unproven ninth night must not be persisted")
    }

    // MARK: - Invalidation

    func testEditDeleteAndReclassificationInvalidateTheExactSummary() throws {
        let (sleeps, stored) = provenNights(count: 8)
        XCTAssertEqual(stored.count, 8)

        // Edit: the current sleep's window moves → revision token changes.
        var edited = sleeps
        let current = edited.removeLast()
        let movedStart = current.start.addingTimeInterval(600)
        edited.append(.init(id: current.id,
                            start: movedStart,
                            end: current.end,
                            isNap: false,
                            revisionToken: AtriaRelativeSkinSleepWindow.revisionToken(
                                start: movedStart, end: current.end, source: "auto")))
        let editedPlan = AtriaRelativeSkinProducer.plan(
            sleeps: edited,
            rows: [],
            stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        )
        XCTAssertEqual(editedPlan.nightsToPersist.count, 7,
                       "The edited night's stale summary must be dropped")
        XCTAssertFalse(editedPlan.nightsToPersist
            .contains { $0.summary.confirmedSleepID == current.id })
        XCTAssertEqual(editedPlan.uiSummary.blocker, .incompleteArchive,
                       "The rebuilt night cannot be proven under a gap, so it fails closed")

        // Delete: the sleep disappears entirely.
        let deletedPlan = AtriaRelativeSkinProducer.plan(
            sleeps: Array(sleeps.dropLast()),
            rows: [],
            stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        )
        XCTAssertEqual(deletedPlan.nightsToPersist.count, 7)

        // Reclassification: the sleep becomes a nap.
        var reclassified = sleeps
        let last = reclassified.removeLast()
        reclassified.append(.init(id: last.id,
                                  start: last.start,
                                  end: last.end,
                                  isNap: true,
                                  revisionToken: AtriaRelativeSkinSleepWindow.revisionToken(
                                    start: last.start, end: last.end, source: "nap")))
        let reclassifiedPlan = AtriaRelativeSkinProducer.plan(
            sleeps: reclassified,
            rows: [],
            stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        )
        XCTAssertFalse(reclassifiedPlan.nightsToPersist
            .contains { $0.summary.confirmedSleepID == last.id },
                       "A nap-reclassified sleep can no longer own a night summary")
    }

    func testNoMainSleepYieldsTypedBlocker() {
        let plan = AtriaRelativeSkinProducer.plan(
            sleeps: [sleep(0, source: "nap")],
            rows: [],
            stored: [],
            environment: environment(drainedThrough: base)
        )
        XCTAssertEqual(plan.uiSummary.blocker, .noCurrentConfirmedMainSleep)
        XCTAssertNil(plan.uiSummary.rawDelta)
    }

    // MARK: - Persistence round-trip

    func testStoreRoundTripRestoresIdenticalSummariesAndResult() throws {
        let directory = try temporaryDirectory()
        let store = AtriaRelativeSkinNightStore(directoryURL: directory)
        let (sleeps, stored) = provenNights(count: 8)
        XCTAssertTrue(store.replaceAll(stored))

        let reloaded = AtriaRelativeSkinNightStore(directoryURL: directory).load()
        XCTAssertEqual(reloaded, stored,
                       "Relaunch must restore byte-identical compact summaries")

        // The relaunch reseed path: no rows, no fresh completeness — the
        // persisted proofs alone reproduce the identical result.
        let original = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps, rows: [], stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        )
        let reseeded = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps, rows: [], stored: reloaded,
            environment: environment(complete: false, drainedThrough: base)
        )
        XCTAssertEqual(reseeded.uiSummary, original.uiSummary)
    }

    func testStoreWriteIsAtomicAndFailedWriteLeavesPreviousResult() throws {
        let directory = try temporaryDirectory()
        let store = AtriaRelativeSkinNightStore(directoryURL: directory)
        let (_, stored) = provenNights(count: 3)
        XCTAssertTrue(store.replaceAll(stored))

        // A store whose parent path is a FILE cannot be written; the failed
        // write reports false and the original store is untouched.
        let blockedParent = directory.appendingPathComponent("occupied")
        try Data("x".utf8).write(to: blockedParent)
        let blocked = AtriaRelativeSkinNightStore(
            directoryURL: blockedParent.appendingPathComponent("nested")
        )
        XCTAssertFalse(blocked.replaceAll(stored))
        XCTAssertEqual(store.load(), stored)
    }

    func testWrongVersionOrCorruptStoreLoadsEmpty() throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent(
            "night-summaries-v\(AtriaRelativeSkinNightStore.storeVersion).json"
        )
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        try Data("{\"version\":999,\"nights\":[]}".utf8).write(to: url)
        XCTAssertTrue(AtriaRelativeSkinNightStore(directoryURL: directory).load().isEmpty)
        try Data("garbage".utf8).write(to: url)
        XCTAssertTrue(AtriaRelativeSkinNightStore(directoryURL: directory).load().isEmpty)
    }

    // MARK: - Presentation contract

    func testPresentationRendersOnlyBuildingBaselineAndQualifiedStates() throws {
        let (sleeps, stored) = provenNights(count: 8)
        let qualified = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps, rows: [], stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        ).uiSummary
        let qualifiedContent = try XCTUnwrap(
            AtriaRelativeSkinSignalPresentation.content(for: qualified)
        )
        XCTAssertTrue(qualifiedContent.headline.contains("raw sensor units"))
        XCTAssertTrue(qualifiedContent.detail.contains("Experimental"))
        XCTAssertTrue(qualifiedContent.detail.contains("stillness unverified"),
                      "An HR-only night must disclose that stillness is unverified")
        XCTAssertFalse(qualifiedContent.headline.contains("Higher"),
                       "Directional wording is reserved for motion-qualified nights")

        let building = AtriaRelativeSkinSignal.resolve(
            currentNight: stored.last!.summary,
            priorNights: Array(stored.prefix(3)).map(\.summary),
            blockerIfNoCurrent: .noCurrentRawEvidence
        )
        let buildingContent = try XCTUnwrap(
            AtriaRelativeSkinSignalPresentation.content(for: building)
        )
        XCTAssertEqual(buildingContent.headline,
                       "Building personal baseline · 3 of 7 nights")

        for blocker in [AtriaRelativeSkinSignalBlocker.incompleteArchive,
                        .noCurrentConfirmedMainSleep,
                        .mixedSensorAuthority,
                        .unknownSensorAuthority,
                        .noCurrentRawEvidence] {
            let blockedSummary = AtriaRelativeSkinSignal.resolve(
                currentNight: nil,
                priorNights: [],
                blockerIfNoCurrent: blocker
            )
            XCTAssertNil(AtriaRelativeSkinSignalPresentation.content(for: blockedSummary),
                         "Blocker \(blocker) must render nothing")
        }
    }

    func testPresentationCopyNeverClaimsTemperatureOrIllness() throws {
        let (sleeps, stored) = provenNights(count: 8)
        let qualified = AtriaRelativeSkinProducer.plan(
            sleeps: sleeps, rows: [], stored: stored,
            environment: environment(complete: false, drainedThrough: base)
        ).uiSummary
        var texts: [String] = []
        if let content = AtriaRelativeSkinSignalPresentation.content(for: qualified) {
            texts.append(content.headline)
            texts.append(content.detail)
        }
        let building = AtriaRelativeSkinSignal.resolve(
            currentNight: stored.last!.summary,
            priorNights: Array(stored.prefix(3)).map(\.summary),
            blockerIfNoCurrent: .noCurrentRawEvidence
        )
        if let content = AtriaRelativeSkinSignalPresentation.content(for: building) {
            texts.append(content.headline)
            texts.append(content.detail)
        }
        XCTAssertFalse(texts.isEmpty)
        // Whole-word matching: "stillness" must not trip "ill"/"illness".
        let forbiddenWords: Set<String> = ["celsius", "fahrenheit", "temperature",
                                           "temp", "fever", "ill", "illness",
                                           "sick", "recovery", "readiness"]
        let forbiddenPrefixes = ["diagnos"]
        for text in texts {
            XCTAssertFalse(text.contains("°"),
                           "\"\(text)\" must not contain a degree symbol")
            let tokens = text.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { !$0.isEmpty }
            for token in tokens {
                XCTAssertFalse(forbiddenWords.contains(token),
                               "\"\(text)\" must not contain the word \"\(token)\"")
                for prefix in forbiddenPrefixes {
                    XCTAssertFalse(token.hasPrefix(prefix),
                                   "\"\(text)\" must not contain \"\(prefix)…\"")
                }
            }
        }
    }

    /// The forbidden Celsius authority stays untouched: the producer file
    /// never references the absolute-decoder paths.
    func testProducerSourceNeverTouchesTheCelsiusAuthority() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria")
        let source = try String(
            contentsOf: root.appendingPathComponent("AtriaRelativeSkinNightStore.swift"),
            encoding: .utf8
        )
        for forbidden in ["skinTemperatureDeviationCelsius",
                          "attachRecoveredSkinTemperature",
                          "recoveredSkinTemperatureProjection",
                          "HealthKit", "HKQuantity"] {
            XCTAssertFalse(source.contains(forbidden),
                           "Producer must not reference \(forbidden)")
        }
    }

    // MARK: - Helpers

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaRelativeSkinProducerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryDirectories.append(url)
        return url
    }
}
