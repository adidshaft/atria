import XCTest
@testable import Atria

/// Handoff-13: the real proof deadline, the shifted-sleep admission with
/// positive awake bracing, the isolated ring day browser, and truthful
/// whole-container storage accounting.
final class AtriaHandoff13Tests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""

    override func setUpWithError() throws {
        suiteName = "AtriaHandoff13Tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = ""
    }

    // MARK: - CP0-A: the proof deadline is real

    func testProofTimeoutFireIsBoundToItsExactProof() {
        // The fire belongs to the proof it was armed for.
        XCTAssertTrue(
            AtriaBLEManager.protectedR10ProofTimeoutFireShouldTerminalize(
                capturedStartedAtUnix: 1_000, currentStartedAtUnix: 1_000,
                proofActive: true
            )
        )
        // A replacement proof (new timestamp) is untouchable by the stale
        // predecessor timer.
        XCTAssertFalse(
            AtriaBLEManager.protectedR10ProofTimeoutFireShouldTerminalize(
                capturedStartedAtUnix: 1_000, currentStartedAtUnix: 2_000,
                proofActive: true
            )
        )
        // No active proof, nothing to terminalize.
        XCTAssertFalse(
            AtriaBLEManager.protectedR10ProofTimeoutFireShouldTerminalize(
                capturedStartedAtUnix: 1_000, currentStartedAtUnix: 1_000,
                proofActive: false
            )
        )
        // A cleared durable timestamp means the proof already terminalized.
        XCTAssertFalse(
            AtriaBLEManager.protectedR10ProofTimeoutFireShouldTerminalize(
                capturedStartedAtUnix: 1_000, currentStartedAtUnix: 0,
                proofActive: true
            )
        )
    }

    func testProofDeadlineExpiryStaysExactAndFailClosed() {
        // The 150 s bound plus fail-closed nil/negative age (pre-existing
        // pure authority the new synchronous sweep reuses verbatim).
        XCTAssertFalse(
            AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
                proofActive: true, attemptAge: 149.9
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
                proofActive: true, attemptAge: 150
            )
        )
        XCTAssertTrue(
            AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
                proofActive: true, attemptAge: nil
            ),
            "a proof without a readable start is already broken — terminalize"
        )
        XCTAssertFalse(
            AtriaBLEManager.protectedR10CleanOwnerProofHasExpired(
                proofActive: false, attemptAge: 10_000
            )
        )
    }

    /// The sweep must exist at every post-suspension edge — the physically
    /// observed 47-minute proof lived because the deadline was only a
    /// suspendable Task.sleep. Source-scan: the enforce call is present at
    /// didConnect, willRestoreState, dense bring-up, and the
    /// suspendForCanonicalRestoreFailure orphan site.
    func testProofDeadlineSweepCoversEveryPostSuspensionEdge() throws {
        let source = try bleSource()
        for trigger in ["did_connect", "will_restore_state",
                        "dense_bring_up_", "suspend_for_canonical_restore_failure"] {
            XCTAssertTrue(
                source.contains(
                    "enforceProtectedR10ProofDeadlineIfNeeded"
                ) && source.contains("trigger: \"\(trigger)"),
                "missing deadline sweep at \(trigger)"
            )
        }
        // The timer fire re-reads the durable proof identity.
        XCTAssertTrue(source.contains(
            "protectedR10ProofTimeoutFireShouldTerminalize("
        ))
    }

    // MARK: - CP1: shifted sleep with positive awake bracing

    func testSustainedAwakeEvidenceRequiresARealRun() {
        let boundary = Date(timeIntervalSince1970: 1_786_600_000)
        // Five adjacent awake bins (25 minutes) right before the boundary.
        let run = (1...5).map {
            boundary.addingTimeInterval(TimeInterval(-$0) * 300)
        }.sorted()
        XCTAssertTrue(SessionStore.sustainedAwakeEvidenceExists(
            awakeBinStarts: run, boundary: boundary, side: .before
        ))
        // A single spike bin can never brace an episode.
        XCTAssertFalse(SessionStore.sustainedAwakeEvidenceExists(
            awakeBinStarts: [boundary.addingTimeInterval(-600)],
            boundary: boundary, side: .before
        ))
        // Scattered non-adjacent bins are not a sustained run.
        let scattered = [0, 2, 4, 6, 8].map {
            boundary.addingTimeInterval(TimeInterval(-$0) * 900)
        }.sorted()
        XCTAssertFalse(SessionStore.sustainedAwakeEvidenceExists(
            awakeBinStarts: scattered, boundary: boundary, side: .before
        ))
        // Evidence outside the two-hour search window does not count.
        let tooFar = (1...5).map {
            boundary.addingTimeInterval(-3 * 3_600 - TimeInterval($0) * 300)
        }.sorted()
        XCTAssertFalse(SessionStore.sustainedAwakeEvidenceExists(
            awakeBinStarts: tooFar, boundary: boundary, side: .after
        ))
        // Silence is never awake evidence.
        XCTAssertFalse(SessionStore.sustainedAwakeEvidenceExists(
            awakeBinStarts: [], boundary: boundary, side: .after
        ))
    }

    /// The exact Aug-13 mega-cluster shape: awake prelude (08:45–09:23,
    /// ~71 bpm), the two-session low-HR core (09:56–13:39, ~61 bpm, 164 s
    /// seam), and hours of continuous post-wake wear (~70 bpm) — exactly one
    /// unconfirmed review near 09:56–13:39.
    func testAug13MegaClusterYieldsOneShiftedReview() throws {
        let (sessions, rest) = aug13MegaCluster()
        let projection = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: sessions,
            confirmedSleeps: [],
            rest: rest,
            maxHR: 190,
            cooperativeDeadline: .init(uptimeNanoseconds: .max,
                                       monotonicNow: { 0 })
        )
        let main = try XCTUnwrap(projection.main,
                                 "the shifted core must surface for review")
        XCTAssertFalse(main.confirmed)
        XCTAssertNotEqual(main.motionValidated, true)
        XCTAssertEqual(main.confidence, "review_needed")
        let calendar = Calendar.current
        let start = try XCTUnwrap(main.start)
        let end = try XCTUnwrap(main.end)
        XCTAssertEqual(calendar.component(.hour, from: start), 9,
                       "the review core begins near 09:56")
        XCTAssertEqual(calendar.component(.hour, from: end), 13,
                       "the review core ends near 13:39 — the 8 h awake tail is out")
    }

    /// Quiet daytime wear (low HR, no awake bracing on the tail — ambient
    /// continuation) must not become sleep solely from low HR.
    func testQuietDaytimeWearWithoutBracingIsNotSleep() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let rest = 58
        // Awake before, low-HR block, then MORE low-HR quiet (no awake tail).
        let before = denseSession(
            start: dayStart.addingTimeInterval(9 * 3_600),
            duration: 45 * 60, bpm: { _ in rest + 13 }
        )
        let quiet = denseSession(
            start: dayStart.addingTimeInterval(10 * 3_600),
            duration: 3 * 3_600 + 30 * 60, bpm: { _ in rest + 2 }
        )
        let stillQuiet = denseSession(
            start: dayStart.addingTimeInterval(13 * 3_600 + 31 * 60),
            duration: 2 * 3_600, bpm: { _ in rest + 3 }
        )
        let projection = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: [stillQuiet, quiet, before],
            confirmedSleeps: [],
            rest: rest,
            maxHR: 190,
            cooperativeDeadline: .init(uptimeNanoseconds: .max,
                                       monotonicNow: { 0 })
        )
        // Without positive awake evidence AFTER the block there is no
        // shifted admission — and the joined quiet span may not qualify
        // through any other daytime lane either.
        if let main = projection.main {
            XCTFail("ambient quiet must not admit: \(main.id)")
        }
    }

    /// True biphasic sleep inside the two-hour allowance stays one episode
    /// when no sustained awake run separates the blocks.
    func testBiphasicBlocksRemainOneEpisode() throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let rest = 58
        let awakeBefore = denseSession(
            start: dayStart.addingTimeInterval(8 * 3_600),
            duration: 40 * 60, bpm: { _ in rest + 14 }
        )
        let block1 = denseSession(
            start: dayStart.addingTimeInterval(9 * 3_600),
            duration: 2 * 3_600, bpm: { _ in rest + 2 }
        )
        // 90-minute silent gap (no HR at all — no awake evidence).
        let block2 = denseSession(
            start: dayStart.addingTimeInterval(12 * 3_600 + 30 * 60),
            duration: 2 * 3_600, bpm: { _ in rest + 2 }
        )
        let awakeAfter = denseSession(
            start: dayStart.addingTimeInterval(14 * 3_600 + 35 * 60),
            duration: 40 * 60, bpm: { _ in rest + 14 }
        )
        let projection = try SessionStore.makeBoundedSleepReviewCacheProjection(
            snapshot: .empty,
            canonicalSessions: [awakeAfter, block2, block1, awakeBefore],
            confirmedSleeps: [],
            rest: rest,
            maxHR: 190,
            cooperativeDeadline: .init(uptimeNanoseconds: .max,
                                       monotonicNow: { 0 })
        )
        let main = try XCTUnwrap(projection.main,
                                 "bracketed biphasic evidence surfaces once")
        let start = try XCTUnwrap(main.start)
        let end = try XCTUnwrap(main.end)
        XCTAssertEqual(Calendar.current.component(.hour, from: start), 9)
        XCTAssertGreaterThanOrEqual(
            Calendar.current.component(.hour, from: end), 14,
            "both blocks belong to one review episode"
        )
    }

    // MARK: - CP3-A: ring day browser

    func testRingBrowserLeafOwnsSelectionAndMeetsHitTargets() throws {
        let source = try String(
            contentsOf: todayScreenURL(),
            encoding: .utf8
        )
        // The parent no longer owns any browse state.
        XCTAssertFalse(source.contains("ringDayOffset"),
                       "the giant parent must not own day-browse state")
        // The leaf exists, owns selection, and its chevrons are 44x44.
        let leafStart = try XCTUnwrap(source.range(
            of: "private struct AtriaTodayRingDayBrowser: View"
        ))
        let leafEnd = try XCTUnwrap(source.range(
            of: "private struct AtriaTodayHeroShrink",
            range: leafStart.upperBound..<source.endIndex
        ))
        let leaf = String(source[leafStart.lowerBound..<leafEnd.lowerBound])
        XCTAssertTrue(leaf.contains("@State private var selectedIndex"))
        XCTAssertTrue(leaf.contains(".frame(width: 44, height: 44)"),
                      "chevron hit regions must be at least 44x44")
        XCTAssertTrue(leaf.contains("entriesByDay[selectedDay]"),
                      "selection resolves through the O(1) day index")
        XCTAssertFalse(leaf.contains(".first {"),
                       "no linear scan per selection")
        XCTAssertTrue(leaf.contains("AtriaBodyEvalProbe.tick(\"AtriaTodayRingDayBrowser\")"))
        // No archive or file work anywhere in the leaf.
        for forbidden in ["HistoricalArchive", "FileManager",
                          "JSONDecoder", "JSONEncoder",
                          "canonicalSessions"] {
            XCTAssertFalse(leaf.contains(forbidden),
                           "leaf must not perform \(forbidden) work")
        }
    }

    // MARK: - CP3-C: storage inventory

    func testStorageInventoryAccountsSQLiteSidecarsAndSkipsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaH13Inventory-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support")
        let historical = documents.appendingPathComponent(
            "atria-historical/segments"
        )
        try FileManager.default.createDirectory(
            at: historical, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: support.appendingPathComponent("Atria/stress-history-v3"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(count: 4_096).write(
            to: historical.appendingPathComponent("chunk-1.jsonl")
        )
        try Data(count: 1_024).write(
            to: support.appendingPathComponent(
                "Atria/stress-history-v3/stress-minute-v3-1.json"
            )
        )
        // A symlink must not be followed or counted.
        try? FileManager.default.createSymbolicLink(
            at: historical.appendingPathComponent("link"),
            withDestinationURL: documents
        )
        let categories = AtriaManagedStorageInventory.measure(
            documentsURL: documents,
            applicationSupportURL: support
        )
        let raw = try XCTUnwrap(categories.first {
            $0.category == "raw_history"
        })
        XCTAssertGreaterThanOrEqual(raw.bytes, 4_096)
        XCTAssertEqual(raw.fileCount, 1, "the symlink is not counted")
        let stress = try XCTUnwrap(categories.first {
            $0.category == "stress_history"
        })
        XCTAssertGreaterThanOrEqual(stress.bytes, 1_024)
        AtriaManagedStorageInventory.recordReceipt(
            categories: categories,
            retentionExecution:
                AtriaManagedStorageInventory.currentRetentionExecutionBlocked,
            nextEligibleAction: "test",
            defaults: defaults
        )
        let data = try XCTUnwrap(defaults.data(
            forKey: AtriaManagedStorageInventory.receiptKey
        ))
        let receipt = try JSONDecoder().decode(
            AtriaManagedStorageInventory.Receipt.self, from: data
        )
        XCTAssertTrue(receipt.retentionExecution.hasPrefix(
            "RETENTION_EXECUTION_BLOCKED("
        ), "no nominal cap may masquerade as enforced")
        XCTAssertEqual(receipt.totalBytes,
                       categories.reduce(0) { $0 + $1.bytes })
    }

    // MARK: - Fixtures

    private func bleSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Atria/AtriaBLEManager.swift"),
            encoding: .utf8
        )
    }

    private func todayScreenURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Atria/AtriaTodayScreen.swift")
    }

    private func aug13MegaCluster() -> ([SavedSession], Int) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date())
        let rest = 58
        let prelude = denseSession(
            start: dayStart.addingTimeInterval(8 * 3_600 + 45 * 60 + 46),
            duration: 38 * 60, bpm: { 69 + ($0 / 300) % 4 }
        )
        let coreFirst = denseSession(
            start: dayStart.addingTimeInterval(9 * 3_600 + 56 * 60 + 3),
            duration: 40 * 60 + 20, bpm: { 62 + ($0 / 420) % 2 }
        )
        let coreSecond = denseSession(
            start: dayStart.addingTimeInterval(10 * 3_600 + 39 * 60 + 7),
            duration: 3 * 3_600 - 2, bpm: { 60 + ($0 / 300) % 3 }
        )
        let tail1 = denseSession(
            start: dayStart.addingTimeInterval(13 * 3_600 + 39 * 60 + 8),
            duration: 98 * 60, bpm: { 67 + ($0 / 240) % 5 }
        )
        let tail2 = denseSession(
            start: dayStart.addingTimeInterval(15 * 3_600 + 17 * 60 + 14),
            duration: 4 * 3_600, bpm: { 68 + ($0 / 300) % 5 }
        )
        return ([tail2, tail1, coreSecond, coreFirst, prelude], rest)
    }

    private func denseSession(
        start: Date,
        duration: TimeInterval,
        bpm: (Int) -> Int
    ) -> SavedSession {
        var session = SavedSession(
            id: UUID(),
            start: start,
            end: start.addingTimeInterval(duration),
            label: "H13 fixture",
            points: stride(from: 0.0, through: duration, by: 1.0).map {
                .init(t: $0, bpm: bpm(Int($0)))
            }
        )
        session.rrPoints = stride(from: 0.0, through: duration, by: 1.0).map {
            .init(t: $0, ms: 980,
                  source: .standardHeartRateMeasurement2A37)
        }
        return session
    }
}
