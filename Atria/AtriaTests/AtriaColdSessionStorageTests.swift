import XCTest
@testable import Atria

final class AtriaColdSessionStorageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_100_000_000)
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    func testThirtyNinetyAndOlderTierBoundariesAreExplicit() {
        XCTAssertEqual(AtriaColdSessionRetentionPolicy.tier(ageDays: 0), .hotFullFidelity)
        XCTAssertEqual(AtriaColdSessionRetentionPolicy.tier(ageDays: 30), .hotFullFidelity)
        XCTAssertEqual(AtriaColdSessionRetentionPolicy.tier(ageDays: 30.001), .decodedColdFullFidelity)
        XCTAssertEqual(AtriaColdSessionRetentionPolicy.tier(ageDays: 90), .decodedColdFullFidelity)
        XCTAssertEqual(AtriaColdSessionRetentionPolicy.tier(ageDays: 90.001), .compactFacts)
    }

    func testFactPreservesLoadInputsAndNeverSerializesRawPointArrays() throws {
        let session = makeSession(ageDays: 120, sampleCount: 180, sampleStep: 5)
        let fact = try AtriaColdSessionFactBuilder.build(session: session, createdAt: session.end)
        let heartRate = try XCTUnwrap(fact.heartRate.value)

        XCTAssertEqual(heartRate.sampleCount, session.points.count)
        XCTAssertEqual(heartRate.minimumBPM, session.points.map(\.bpm).min())
        XCTAssertEqual(heartRate.maximumBPM, session.points.map(\.bpm).max())
        XCTAssertEqual(try XCTUnwrap(heartRate.trimp(rest: 58,
                                                    maxHR: 192,
                                                    biologicalSex: .male).value),
                       session.trimp(rest: 58, max: 192),
                       accuracy: 0.000_000_1)

        let compactJSON = try AtriaColdSessionStore.encoder().encode(fact)
        let text = try XCTUnwrap(String(data: compactJSON, encoding: .utf8))
        XCTAssertFalse(text.contains("\"points\""))
        XCTAssertFalse(text.contains("\"rrPoints\""))
        XCTAssertTrue(text.contains("transitionHalfBPMSeconds"))
    }

    func testZoneAndCalorieFactsMatchFullSessionIntegrators() throws {
        let session = makeSession(ageDays: 120, sampleCount: 240, sampleStep: 5)
        let facts = try XCTUnwrap(
            AtriaColdSessionFactBuilder.build(session: session, createdAt: session.end).heartRate.value
        )
        let compactZones = try XCTUnwrap(facts.maxHeartRateZoneSeconds(maxHR: 190).value)
        let fullZones = session.timeInZone(maxHR: 190)
        let names = ["rest", "warmup", "fatBurn", "aerobic", "anaerobic", "max"]
        for zone in HRZone.allCases {
            XCTAssertEqual(compactZones[names[zone.rawValue]] ?? 0,
                           fullZones[zone] ?? 0,
                           accuracy: 0.000_001)
        }

        let profile = AthleteProfile(age: 35,
                                     measuredMaxHR: 190,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     weightKg: 64,
                                     heightCm: 168,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let compactCalories = try XCTUnwrap(facts.activeCalories(rest: 58, profile: profile).value)
        let fullCalories = try XCTUnwrap(session.activeCalories(rest: 58, profile: profile))
        XCTAssertEqual(compactCalories, fullCalories, accuracy: 0.000_001)
    }

    func testPartialMinuteDailyLoadQueriesFailClosed() throws {
        let session = makeSession(ageDays: 120, sampleCount: 120, sampleStep: 5)
        let facts = try XCTUnwrap(
            AtriaColdSessionFactBuilder.build(session: session, createdAt: session.end).heartRate.value
        )
        let partial = DateInterval(start: session.start.addingTimeInterval(7),
                                   end: session.end.addingTimeInterval(-3))

        XCTAssertEqual(facts.trimp(rest: 58, maxHR: 190,
                                  biologicalSex: .male, within: partial).state, .unsupported)
        XCTAssertEqual(facts.maxHeartRateZoneSeconds(maxHR: 190,
                                                     within: partial).state, .unsupported)
        let profile = AthleteProfile(age: 35, measuredMaxHR: 190,
                                     maxHRSource: .measured, biologicalSex: .male,
                                     weightKg: 75, heightCm: 180,
                                     updated: now, hasCompletedOnboarding: true)
        XCTAssertEqual(facts.activeCalories(rest: 58,
                                            profile: profile,
                                            within: partial).state, .unsupported)
    }

    func testMissingRREvidenceAndUnsupportedActivityReferencesStayExplicit() throws {
        var session = makeSession(ageDays: 120, sampleCount: 20)
        session.rrPoints = nil
        let fact = try AtriaColdSessionFactBuilder.build(session: session, createdAt: session.end)

        XCTAssertEqual(fact.rr.state, .missing)
        XCTAssertNil(fact.rr.value)
        XCTAssertFalse(fact.rr.reason?.isEmpty ?? true)
        XCTAssertEqual(fact.references.activities.state, .unsupported)
        XCTAssertFalse(fact.references.activities.reason?.isEmpty ?? true)
    }

    func testMigrationPublishesVerifiedChunksWithoutDeletingFullColdSource() throws {
        let fixture = try makeFixture(sessions: [
            makeSession(ageDays: 45, sampleCount: 30),
            makeSession(ageDays: 89, sampleCount: 30),
            makeSession(ageDays: 91, sampleCount: 90),
            makeSession(ageDays: 160, sampleCount: 90),
        ])
        let result = try AtriaColdSessionMigration().migrate(sourceURL: fixture.source,
                                                              destinationRootURL: fixture.destination,
                                                              now: now)

        XCTAssertEqual(result.status, .published)
        XCTAssertEqual(result.decodedSessionCount, 4)
        XCTAssertEqual(result.eligibleSessionCount, 2)
        XCTAssertFalse(result.sourceDeleted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        let store = AtriaColdSessionStore(rootURL: fixture.destination)
        let catalog = try store.loadCatalog()
        XCTAssertFalse(catalog.authorizesRawRetirement)
        XCTAssertFalse(catalog.productionRawRetirementEnabled)
        XCTAssertEqual(catalog.source.compactEligibleSessionCount, 2)
        try store.verifyCatalog(catalog)
        let facts = try store.facts(overlapping: DateInterval(start: now.addingTimeInterval(-200 * 86_400),
                                                              end: now))
        XCTAssertEqual(facts.count, 2)
    }

    func testIdempotentMigrationReusesContentAddressedChunks() throws {
        let fixture = try makeFixture(sessions: [makeSession(ageDays: 120, sampleCount: 120)])
        let migration = AtriaColdSessionMigration()
        let first = try migration.migrate(sourceURL: fixture.source,
                                          destinationRootURL: fixture.destination,
                                          now: now)
        let filenames = try FileManager.default.contentsOfDirectory(atPath:
            AtriaColdSessionStore(rootURL: fixture.destination).chunksURL.path).sorted()
        let second = try migration.migrate(sourceURL: fixture.source,
                                           destinationRootURL: fixture.destination,
                                           now: now.addingTimeInterval(3_600))

        XCTAssertEqual(first.status, .published)
        XCTAssertEqual(second.status, .unchanged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:
            AtriaColdSessionStore(rootURL: fixture.destination).chunksURL.path).sorted(), filenames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testRepeatedSourceMutationsPruneOnlyUnreachableGeneratedChunks() throws {
        var sessions = [makeSession(ageDays: 120, sampleCount: 60)]
        let fixture = try makeFixture(sessions: sessions)
        let migration = AtriaColdSessionMigration()
        _ = try migration.migrate(sourceURL: fixture.source,
                                  destinationRootURL: fixture.destination,
                                  now: now)
        let store = AtriaColdSessionStore(rootURL: fixture.destination)
        let unknown = store.chunksURL.appendingPathComponent("owner-note.txt")
        try Data("preserve".utf8).write(to: unknown)

        for iteration in 1...5 {
            sessions.append(makeSession(ageDays: 120 + Double(iteration) / 100,
                                        sampleCount: 60 + iteration))
            try JSONEncoder().encode(sessions).write(to: fixture.source, options: .atomic)
            _ = try migration.migrate(sourceURL: fixture.source,
                                      destinationRootURL: fixture.destination,
                                      now: now)
            let catalog = try store.loadCatalog()
            let generated = try FileManager.default.contentsOfDirectory(at: store.chunksURL,
                                                                         includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("day-") }
            XCTAssertEqual(Set(generated.map(\.lastPathComponent)),
                           Set(catalog.entries.map(\.filename)),
                           "superseded content-addressed chunks must not accumulate")
            XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path),
                          "unrecognized owner files must never be pruned")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        }
    }

    func testEveryPublicationFaultLeavesFullColdSourceAuthoritative() throws {
        enum Injected: Error { case crash }
        for point in AtriaColdSessionMigration.Checkpoint.allCases {
            let fixture = try makeFixture(sessions: [makeSession(ageDays: 120, sampleCount: 60)])
            let migration = AtriaColdSessionMigration(checkpoint: {
                if $0 == point { throw Injected.crash }
            })
            XCTAssertThrowsError(try migration.migrate(sourceURL: fixture.source,
                                                        destinationRootURL: fixture.destination,
                                                        now: now),
                                 "fault at \(point.rawValue) must interrupt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path),
                          "full cold source disappeared at \(point.rawValue)")
            let decoded = try JSONDecoder().decode([SavedSession].self,
                                                   from: Data(contentsOf: fixture.source))
            XCTAssertEqual(decoded.count, 1)
        }
    }

    func testCorruptChunkFailsClosedWithExplicitMissingTimeline() throws {
        let fixture = try makeFixture(sessions: [makeSession(ageDays: 120, sampleCount: 60)])
        _ = try AtriaColdSessionMigration().migrate(sourceURL: fixture.source,
                                                    destinationRootURL: fixture.destination,
                                                    now: now)
        let store = AtriaColdSessionStore(rootURL: fixture.destination)
        let entry = try XCTUnwrap(store.loadCatalog().entries.first)
        try Data("corrupt".utf8).write(to: store.chunksURL.appendingPathComponent(entry.filename),
                                              options: .atomic)

        let timeline = store.heartRateTimeline(overlapping: DateInterval(
            start: now.addingTimeInterval(-130 * 86_400), end: now
        ))
        XCTAssertEqual(timeline.state, .missing)
        XCTAssertNil(timeline.value)
        XCTAssertTrue(timeline.reason?.contains("verification failed") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
    }

    func testStreamingSourceScannerRejectsMissingAndTrailingCommas() throws {
        let sessionData = try JSONEncoder().encode(makeSession(ageDays: 120, sampleCount: 12))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaColdSessionStorageTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let source = root.appendingPathComponent("sessions-cold.json")

        var trailingComma = Data("[".utf8)
        trailingComma.append(sessionData)
        trailingComma.append(Data(",]".utf8))
        try trailingComma.write(to: source, options: .atomic)
        XCTAssertThrowsError(try AtriaColdSessionSourceScanner.scan(url: source) { _ in }) {
            XCTAssertEqual($0 as? AtriaColdSessionSourceScanner.ScanError,
                           .malformedTopLevelArray)
        }

        var missingComma = Data("[".utf8)
        missingComma.append(sessionData)
        missingComma.append(sessionData)
        missingComma.append(Data("]".utf8))
        try missingComma.write(to: source, options: .atomic)
        XCTAssertThrowsError(try AtriaColdSessionSourceScanner.scan(url: source) { _ in }) {
            XCTAssertEqual($0 as? AtriaColdSessionSourceScanner.ScanError,
                           .malformedTopLevelArray)
        }
    }

    func testBoundedFullFidelityAppendMatchesLegacyHotColdUnion() throws {
        let hot = makeSession(ageDays: 10, sampleCount: 12)
        let shadowedByHot = makeSession(ageDays: 120,
                                        sampleCount: 14,
                                        id: hot.id)
        let coldOnlyID = UUID()
        let coldOnly = makeSession(ageDays: 121,
                                   sampleCount: 22,
                                   id: coldOnlyID)
        let repeatedColdID = makeSession(ageDays: 122,
                                         sampleCount: 18,
                                         id: coldOnlyID)
        let fixture = try makeFixture(sessions: [shadowedByHot, coldOnly, repeatedColdID])
        var destination = [hot]

        let result = try AtriaColdSessionSourceScanner.appendFullFidelitySessions(
            from: fixture.source,
            to: &destination,
            excludingIDs: Set(destination.map(\.id))
        )

        XCTAssertEqual(result.source.byteCount,
                       try fixture.source.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(UInt64.init))
        XCTAssertEqual(result.source.sessionCount, 3)
        XCTAssertEqual(result.appendedSessionCount, 2)
        XCTAssertEqual(destination.map(\.id), [hot.id, coldOnlyID, coldOnlyID],
                       "hot IDs must win while duplicate IDs internal to the cold source preserve legacy semantics")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(destination[1])) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(coldOnly)) as? NSDictionary,
                       "streaming must preserve every full-fidelity SavedSession field")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(destination[2])) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(repeatedColdID)) as? NSDictionary)
    }

    func testBoundedFullFidelityAppendRollsBackEveryDecodedSessionOnLateCorruption() throws {
        let hot = makeSession(ageDays: 10, sampleCount: 12)
        let cold = makeSession(ageDays: 120, sampleCount: 20)
        let fixture = try makeFixture(sessions: [])
        var corrupt = Data("[".utf8)
        corrupt.append(try JSONEncoder().encode(cold))
        corrupt.append(Data(",{".utf8))
        try corrupt.write(to: fixture.source, options: .atomic)
        var destination = [hot]
        let before = try JSONSerialization.jsonObject(with: JSONEncoder().encode(destination)) as? NSArray

        XCTAssertThrowsError(try AtriaColdSessionSourceScanner.appendFullFidelitySessions(
            from: fixture.source,
            to: &destination,
            excludingIDs: Set(destination.map(\.id))
        )) {
            XCTAssertEqual($0 as? AtriaColdSessionSourceScanner.ScanError, .unterminatedObject)
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(destination)) as? NSArray,
                       before,
                       "a partially scanned cold file must never publish a partial canonical union")
    }

    func testManifestedFullFidelityStoreSkipsEveryColdEncodeForHotOnlyCheckpoint() throws {
        let root = try makeRoot()
        let legacyURL = root.appendingPathComponent("sessions-cold.json")
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(nextTo: legacyURL)
        )
        let cold = (0..<24).map {
            makeSession(ageDays: 60 + Double($0), sampleCount: 300, sampleStep: 2)
        }
        var hot = makeSession(ageDays: 1, sampleCount: 100)
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let first = try store.persist(sessions: [hot] + cold,
                                      cutoff: cutoff,
                                      delta: .full,
                                      generatedAt: now)
        let firstManifestData = try Data(contentsOf: store.manifestURL)
        let firstEntries = try store.loadManifest().entries
        XCTAssertEqual(first.encodedSessionCount, cold.count)

        if let first = hot.rrPoints?.first {
            hot.rrPoints?[0] = .init(t: first.t,
                                     ms: first.ms + 1,
                                     source: first.source)
        }
        let checkpoint = try store.persist(sessions: [hot] + cold,
                                           cutoff: cutoff,
                                           delta: .none,
                                           generatedAt: now.addingTimeInterval(10))

        XCTAssertEqual(checkpoint.status, .unchanged)
        XCTAssertEqual(checkpoint.encodedSessionCount, 0)
        XCTAssertEqual(checkpoint.largestEncodedSessionBytes, 0)
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), firstManifestData)
        XCTAssertEqual(try store.loadManifest().entries, firstEntries)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    }

    func testManifestedFullFidelityStoreReencodesOnlyChangedColdIDAndRestoresExactly() throws {
        let root = try makeRoot()
        let legacyURL = root.appendingPathComponent("sessions-cold.json")
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(nextTo: legacyURL)
        )
        var sessions = (0..<12).map {
            makeSession(ageDays: 45 + Double($0), sampleCount: 180 + $0)
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        _ = try store.persist(sessions: sessions,
                              cutoff: cutoff,
                              delta: .full,
                              generatedAt: now)
        let before = try store.loadManifest()
        let changedID = sessions[7].id
        if let first = sessions[7].rrPoints?.first {
            sessions[7].rrPoints?[0] = .init(t: first.t,
                                             ms: first.ms + 17,
                                             source: first.source)
        }
        sessions[7].motionEvidenceSource = "verified_incremental_mutation"

        let result = try store.persist(
            sessions: sessions,
            cutoff: cutoff,
            delta: .init(requiresFullRewrite: false, changedSessionIDs: [changedID]),
            generatedAt: now.addingTimeInterval(1)
        )
        let after = try store.loadManifest()

        XCTAssertEqual(result.status, .published)
        XCTAssertEqual(result.encodedSessionCount, 1)
        XCTAssertEqual(before.entries.enumerated().filter { $0.element.filename != after.entries[$0.offset].filename }.count,
                       1)
        var restored: [SavedSession] = []
        let load = try store.appendFullFidelitySessions(to: &restored, excludingIDs: [])
        XCTAssertEqual(load.appendedSessionCount, sessions.count)
        XCTAssertLessThan(load.largestDecodedSessionBytes, load.decodedByteCount,
                          "restart must buffer one session payload, not the complete cold history")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? NSArray,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(sessions)) as? NSArray)
    }

    func testVerifiedManifestPublicationPrunesOnlySupersededRecognizedChunks() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        var session = makeSession(ageDays: 60, sampleCount: 120)
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        _ = try store.persist(sessions: [session],
                              cutoff: cutoff,
                              delta: .full,
                              generatedAt: now)
        let superseded = try XCTUnwrap(store.loadManifest().entries.first).filename
        let unknown = store.chunksURL.appendingPathComponent("user-preserved.bin")
        try Data("preserve".utf8).write(to: unknown, options: .atomic)

        session.motionEvidenceSource = "verified_new_generation"
        _ = try store.persist(
            sessions: [session],
            cutoff: cutoff,
            delta: .init(requiresFullRewrite: false, changedSessionIDs: [session.id]),
            generatedAt: now.addingTimeInterval(1)
        )
        let current = try XCTUnwrap(store.loadManifest().entries.first).filename

        XCTAssertNotEqual(current, superseded)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.chunksURL.appendingPathComponent(superseded).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.chunksURL.appendingPathComponent(current).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path),
                      "unknown files must never be removed by chunk retention")
        try store.verifyManifest(store.loadManifest())
    }

    func testBoundedManifestLoadKeepsNewestEligibleSessionsAndSupportsOlderRangeQuery() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let cold = [35.0, 50.0, 70.0, 91.0, 120.0].map {
            makeSession(ageDays: $0, sampleCount: 24)
        }
        _ = try store.persist(sessions: cold,
                              cutoff: now.addingTimeInterval(-30 * 86_400),
                              delta: .full,
                              generatedAt: now)

        var resident: [SavedSession] = []
        let load = try store.appendBoundedFullFidelitySessions(
            to: &resident,
            excludingIDs: [],
            policy: .init(earliestStart: now.addingTimeInterval(-92 * 86_400),
                          maximumSessionCount: 2,
                          maximumDecodedBytes: 64 * 1_024 * 1_024)
        )

        XCTAssertEqual(load.storedSessionCount, 5)
        XCTAssertEqual(load.eligibleSessionCount, 4)
        XCTAssertEqual(load.appendedSessionCount, 2)
        XCTAssertTrue(load.wasTruncated)
        XCTAssertEqual(resident.map(\.id), Array(cold.prefix(2)).map(\.id),
                       "the hard ceiling must retain the newest eligible full-fidelity sessions")

        let older = try store.sessions(
            overlapping: DateInterval(start: now.addingTimeInterval(-121 * 86_400),
                                      end: now.addingTimeInterval(-119 * 86_400)),
            maximumSessionCount: 1,
            maximumDecodedBytes: 8 * 1_024 * 1_024
        )
        XCTAssertEqual(older.map(\.id), [cold[4].id],
                       "an old detail remains individually available without joining resident state")
    }

    func testBoundedPersistPreservesUnspecifiedColdEntriesAndExplicitDeleteRemovesOnlyTarget() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let cold = (0..<5).map {
            makeSession(ageDays: 45 + Double($0 * 20), sampleCount: 20 + $0)
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        _ = try store.persist(sessions: cold,
                              cutoff: cutoff,
                              delta: .full,
                              generatedAt: now)

        let boundedSnapshot = Array(cold.prefix(2))
        let preserved = try store.persist(
            sessions: boundedSnapshot,
            cutoff: cutoff,
            delta: .none,
            preservingUnspecifiedExistingSessions: true,
            generatedAt: now.addingTimeInterval(1)
        )
        XCTAssertEqual(preserved.coldSessionCount, cold.count)
        XCTAssertEqual(Set(try store.loadManifest().entries.map(\.sessionID)),
                       Set(cold.map(\.id)))

        let deletedID = cold[3].id
        let afterDelete = try store.persist(
            sessions: boundedSnapshot,
            cutoff: cutoff,
            delta: .init(requiresFullRewrite: false, changedSessionIDs: [deletedID]),
            preservingUnspecifiedExistingSessions: true,
            generatedAt: now.addingTimeInterval(2)
        )
        XCTAssertEqual(afterDelete.coldSessionCount, cold.count - 1)
        XCTAssertFalse(try store.loadManifest().entries.contains { $0.sessionID == deletedID })
        XCTAssertTrue(try store.loadManifest().entries.contains { $0.sessionID == cold[4].id },
                      "an unrelated nonresident session must remain authoritative")
    }

    func testResidentSessionSelectionHasAgeAndCountCeilings() {
        let sessions = [1.0, 10.0, 45.0, 91.0, 93.0, 140.0].map {
            makeSession(ageDays: $0, sampleCount: 12)
        }

        let resident = SessionStore.boundedResidentSessions(sessions,
                                                            now: now,
                                                            maximumCount: 3)

        XCTAssertEqual(resident.map(\.id), Array(sessions.prefix(3)).map(\.id))
        XCTAssertTrue(resident.allSatisfy {
            $0.start >= now.addingTimeInterval(-92 * 86_400)
        })
    }

    func testManifestPublicationFaultRestartsAtCompleteOldOrCompleteNewGeneration() throws {
        enum Injected: Error { case crash }
        for point in AtriaFullFidelityColdSessionStore.Checkpoint.allCases {
            let root = try makeRoot()
            let storeRoot = AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
            var original = makeSession(ageDays: 60, sampleCount: 90)
            let cutoff = now.addingTimeInterval(-30 * 86_400)
            _ = try AtriaFullFidelityColdSessionStore(rootURL: storeRoot).persist(
                sessions: [original], cutoff: cutoff, delta: .full, generatedAt: now
            )
            let oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? NSDictionary
            if let first = original.rrPoints?.first {
                original.rrPoints?[0] = .init(t: first.t,
                                              ms: first.ms + 31,
                                              source: first.source)
            }
            original.motionEvidenceSource = "new_generation"
            let newJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? NSDictionary
            let faulting = AtriaFullFidelityColdSessionStore(rootURL: storeRoot, checkpoint: {
                if $0 == point { throw Injected.crash }
            })

            XCTAssertThrowsError(try faulting.persist(
                sessions: [original],
                cutoff: cutoff,
                delta: .init(requiresFullRewrite: false, changedSessionIDs: [original.id]),
                generatedAt: now.addingTimeInterval(1)
            ))

            let restarted = AtriaFullFidelityColdSessionStore(rootURL: storeRoot)
            var decoded: [SavedSession] = []
            _ = try restarted.appendFullFidelitySessions(to: &decoded, excludingIDs: [])
            let restartedJSON = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(XCTUnwrap(decoded.first))
            ) as? NSDictionary
            XCTAssertTrue(restartedJSON == oldJSON || restartedJSON == newJSON,
                          "fault at \(point.rawValue) exposed a mixed generation")
            XCTAssertEqual(decoded.count, 1)
            XCTAssertGreaterThanOrEqual(
                try FileManager.default.contentsOfDirectory(atPath: restarted.chunksURL.path).count,
                1,
                "raw full-fidelity chunks must survive every fault"
            )
        }
    }

    func testManifestReaderRollsBackAllAppendsOnLateChunkCorruption() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let cold = [
            makeSession(ageDays: 61, sampleCount: 30),
            makeSession(ageDays: 62, sampleCount: 31),
            makeSession(ageDays: 63, sampleCount: 32),
        ]
        _ = try store.persist(sessions: cold,
                              cutoff: now.addingTimeInterval(-30 * 86_400),
                              delta: .full,
                              generatedAt: now)
        let last = try XCTUnwrap(store.loadManifest().entries.last)
        try Data("corrupt".utf8).write(to: store.chunksURL.appendingPathComponent(last.filename),
                                       options: .atomic)
        let hot = makeSession(ageDays: 1, sampleCount: 10)
        var destination = [hot]

        XCTAssertThrowsError(try store.appendFullFidelitySessions(to: &destination,
                                                                   excludingIDs: [hot.id]))
        XCTAssertEqual(destination.map(\.id), [hot.id],
                       "a late bad chunk must not publish an incomplete cold generation")
    }

    func testManifestPreservesDuplicateIDsAndExactLegacyOrder() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let duplicateID = UUID()
        let sessions = [
            makeSession(ageDays: 63, sampleCount: 30, id: duplicateID),
            makeSession(ageDays: 61, sampleCount: 40),
            makeSession(ageDays: 62, sampleCount: 50, id: duplicateID),
        ]
        _ = try store.persist(sessions: sessions,
                              cutoff: now.addingTimeInterval(-30 * 86_400),
                              delta: .full,
                              generatedAt: now)
        var restored: [SavedSession] = []
        _ = try store.appendFullFidelitySessions(to: &restored, excludingIDs: [])

        XCTAssertEqual(restored.map(\.id), sessions.map(\.id))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? NSArray,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(sessions)) as? NSArray)
    }

    func testDurableFullRewriteMarkerSurvivesFaultAndClearsOnlyAfterVerification() throws {
        enum Injected: Error { case crash }
        let root = try makeRoot()
        let storeRoot = AtriaFullFidelityColdSessionStore.rootURL(
            nextTo: root.appendingPathComponent("sessions-cold.json")
        )
        let session = makeSession(ageDays: 61, sampleCount: 50)
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let store = AtriaFullFidelityColdSessionStore(rootURL: storeRoot)
        _ = try store.persist(sessions: [session], cutoff: cutoff, delta: .full, generatedAt: now)
        try store.requestFullRewrite()
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.invalidationURL.path))

        let faulting = AtriaFullFidelityColdSessionStore(rootURL: storeRoot, checkpoint: {
            if $0 == .manifestPublished { throw Injected.crash }
        })
        XCTAssertThrowsError(try faulting.persist(sessions: [session],
                                                  cutoff: cutoff,
                                                  delta: .none,
                                                  generatedAt: now.addingTimeInterval(1)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.invalidationURL.path))

        let retry = try store.persist(sessions: [session],
                                      cutoff: cutoff,
                                      delta: .none,
                                      generatedAt: now.addingTimeInterval(2))
        XCTAssertEqual(retry.encodedSessionCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.invalidationURL.path))
        try store.verifyManifest(store.loadManifest())
    }

    func testStreamingLaunchAdoptionArchivesLargeSourceWithBoundedResidentPayload() throws {
        let root = try makeRoot()
        let hotURL = root.appendingPathComponent("sessions.json")
        var expectedIDs: [UUID] = []
        try writeStreamingSessionArray(count: 180, to: hotURL) { index in
            let session = makeSession(ageDays: 1 + Double(index),
                                      sampleCount: 320 + index % 7)
            expectedIDs.append(session.id)
            return session
        }
        let sourceBytes = UInt64(try XCTUnwrap(
            hotURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        ))
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let residentBudget: UInt64 = 900_000

        let result = try store.adoptStreamingSources(
            hotURL: hotURL,
            legacyColdURL: nil,
            policy: .init(earliestResidentStart: now.addingTimeInterval(-92 * 86_400),
                          maximumResidentSessionCount: 6,
                          maximumResidentDecodedBytes: residentBudget),
            generatedAt: now
        )

        XCTAssertEqual(result.publicationStatus, .published)
        XCTAssertEqual(result.hotSource?.sessionCount, 180)
        XCTAssertEqual(result.archivedSessionCount, 180)
        XCTAssertLessThanOrEqual(result.residentSessions.count, 6)
        XCTAssertLessThanOrEqual(result.residentDecodedByteCount, residentBudget)
        XCTAssertTrue(result.residentWasTruncated)
        XCTAssertLessThan(result.hotSource?.largestEncodedSessionBytes ?? Int.max,
                          Int(sourceBytes / 20),
                          "the scanner must frame one session, not allocate source-sized Data")
        XCTAssertLessThan(result.largestTransientPayloadBytes, sourceBytes / 10,
                          "compression working memory must remain one-session-sized")
        XCTAssertEqual(try store.loadManifest().entries.map(\.sessionID), expectedIDs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hotURL.path),
                      "streaming adoption never retires the raw source")
        try store.verifyManifest(store.loadManifest())
    }

    func testStreamingLaunchAdoptionMalformedTailRollsBackManifestAndPreservesSource() throws {
        let root = try makeRoot()
        let hotURL = root.appendingPathComponent("sessions.json")
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let original = makeSession(ageDays: 10, sampleCount: 40)
        try JSONEncoder().encode([original]).write(to: hotURL, options: .atomic)
        _ = try store.adoptStreamingSources(
            hotURL: hotURL,
            legacyColdURL: nil,
            policy: .init(earliestResidentStart: now.addingTimeInterval(-92 * 86_400),
                          maximumResidentSessionCount: 10,
                          maximumResidentDecodedBytes: 8 * 1_024 * 1_024),
            generatedAt: now
        )
        let priorManifest = try Data(contentsOf: store.manifestURL)

        let replacement = makeSession(ageDays: 5, sampleCount: 50)
        var malformed = Data("[".utf8)
        malformed.append(try JSONEncoder().encode(replacement))
        malformed.append(Data(",{".utf8))
        try malformed.write(to: hotURL, options: .atomic)
        let malformedSource = try Data(contentsOf: hotURL)

        XCTAssertThrowsError(try store.adoptStreamingSources(
            hotURL: hotURL,
            legacyColdURL: nil,
            policy: .init(earliestResidentStart: now.addingTimeInterval(-92 * 86_400),
                          maximumResidentSessionCount: 10,
                          maximumResidentDecodedBytes: 8 * 1_024 * 1_024),
            generatedAt: now.addingTimeInterval(1)
        )) {
            XCTAssertEqual($0 as? AtriaColdSessionSourceScanner.ScanError, .unterminatedObject)
        }
        XCTAssertEqual(try Data(contentsOf: store.manifestURL), priorManifest,
                       "a partial scan must not publish a partial generation")
        XCTAssertEqual(try Data(contentsOf: hotURL), malformedSource,
                       "malformed raw evidence must remain byte-for-byte intact")
        var restored: [SavedSession] = []
        _ = try store.appendFullFidelitySessions(to: &restored, excludingIDs: [])
        XCTAssertEqual(restored.map(\.id), [original.id])
    }

    func testStreamingLaunchAdoptionPublicationFaultLeavesCompleteGenerationAndRawSource() throws {
        enum Injected: Error { case crash }
        for point in AtriaFullFidelityColdSessionStore.Checkpoint.allCases {
            let root = try makeRoot()
            let hotURL = root.appendingPathComponent("sessions.json")
            let session = makeSession(ageDays: 12, sampleCount: 60)
            try JSONEncoder().encode([session]).write(to: hotURL, options: .atomic)
            let sourceBefore = try Data(contentsOf: hotURL)
            let storeRoot = AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
            let faulting = AtriaFullFidelityColdSessionStore(rootURL: storeRoot, checkpoint: {
                if $0 == point { throw Injected.crash }
            })

            XCTAssertThrowsError(try faulting.adoptStreamingSources(
                hotURL: hotURL,
                legacyColdURL: nil,
                policy: .init(earliestResidentStart: now.addingTimeInterval(-92 * 86_400),
                              maximumResidentSessionCount: 10,
                              maximumResidentDecodedBytes: 8 * 1_024 * 1_024),
                generatedAt: now
            ))
            XCTAssertEqual(try Data(contentsOf: hotURL), sourceBefore)

            let restarted = AtriaFullFidelityColdSessionStore(rootURL: storeRoot)
            if FileManager.default.fileExists(atPath: restarted.manifestURL.path) {
                var restored: [SavedSession] = []
                _ = try restarted.appendFullFidelitySessions(to: &restored, excludingIDs: [])
                XCTAssertEqual(restored.map(\.id), [session.id],
                               "a visible post-rename generation must be complete")
            }
        }
    }

    func testSyntheticThirtyNinetyAnd365DayStorageProfile() throws {
        let thirty = try migrateSyntheticSpan(days: 30)
        let ninety = try migrateSyntheticSpan(days: 90)
        let year = try migrateSyntheticSpan(days: 365)

        XCTAssertEqual(thirty.eligible, 0)
        XCTAssertEqual(thirty.compactBytes, 0)
        XCTAssertEqual(ninety.eligible, 0)
        XCTAssertEqual(ninety.compactBytes, 0)
        XCTAssertGreaterThan(year.eligible, 0)
        XCTAssertGreaterThan(year.compactBytes, 0)
        XCTAssertLessThan(Double(year.compactBytes) / Double(year.sourceBytes), 0.40,
                          "compressed facts should be materially smaller than full HR/RR sessions")
    }

    func testProductionCompactionRetiresOnlyVerifiedOlderThanNinetyDaySessions() throws {
        let root = try makeRoot()
        let fullStore = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let old = makeSession(ageDays: 120, sampleCount: 120)
        let boundary = makeSession(ageDays: 89, sampleCount: 100)
        let recentCold = makeSession(ageDays: 60, sampleCount: 80)
        _ = try fullStore.persist(
            sessions: [old, boundary, recentCold],
            cutoff: now.addingTimeInterval(-30 * 86_400),
            delta: .full,
            generatedAt: now
        )
        let compactRoot = root.appendingPathComponent("compact-tier", isDirectory: true)

        let result = try AtriaManifestedColdSessionCompaction().compactAndRetire(
            fullStore: fullStore,
            destinationRootURL: compactRoot,
            now: now,
            confirmedSleeps: [],
            confirmedWorkouts: [],
            restingHeartRate: 58,
            maximumHeartRate: 192
        )

        XCTAssertEqual(result.compactedSessionIDs, [old.id])
        XCTAssertGreaterThan(result.fullBytesRetired, 0)
        XCTAssertEqual(Set(try fullStore.loadManifest().entries.map(\.sessionID)),
                       [boundary.id, recentCold.id])
        let compactStore = AtriaColdSessionStore(rootURL: compactRoot)
        let catalog = try compactStore.loadCatalog()
        XCTAssertTrue(catalog.authorizesRawRetirement)
        try compactStore.verifyCatalog(catalog)
        XCTAssertEqual(try compactStore.factsPage(before: now,
                                                   maximumFactCount: 100,
                                                   maximumDecodedBytes: 8 * 1_024 * 1_024)
            .map(\.source.sessionID), [old.id])
    }

    func testConcurrentCheckpointCannotRepublishEntriesRetiredByCompaction() throws {
        let root = try makeRoot()
        let gate = ColdManifestRaceGate()
        let fullRoot = AtriaFullFidelityColdSessionStore.rootURL(
            nextTo: root.appendingPathComponent("sessions-cold.json")
        )
        let compactionStore = AtriaFullFidelityColdSessionStore(
            rootURL: fullRoot,
            checkpoint: { point in
                if point == .manifestTemporaryDurable { gate.pauseFirstArmedWriter() }
            }
        )
        let ordinaryStore = AtriaFullFidelityColdSessionStore(rootURL: fullRoot)
        let old = makeSession(ageDays: 120, sampleCount: 90)
        let recent = makeSession(ageDays: 60, sampleCount: 70)
        _ = try compactionStore.persist(
            sessions: [old, recent],
            cutoff: now.addingTimeInterval(-30 * 86_400),
            delta: .full,
            generatedAt: now
        )
        gate.arm()

        let compactRoot = root.appendingPathComponent("compact-race", isDirectory: true)
        let compactionFinished = DispatchSemaphore(value: 0)
        let ordinaryFinished = DispatchSemaphore(value: 0)
        let errors = ColdManifestRaceErrors()
        // Keep this synchronization test independent of the shared utility
        // pool. The full suite runs thousands of tests in parallel and can
        // starve a global utility task past the gate timeout before the storage
        // transaction even begins, producing a timeout cascade rather than a
        // manifest-race result. Distinct queues still provide real concurrent
        // writers while making entry into the deliberately paused transaction
        // deterministic.
        let compactionQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.cold-manifest-race.compaction",
            qos: .userInitiated
        )
        let ordinaryQueue = DispatchQueue(
            label: "com.adidshaft.atria.tests.cold-manifest-race.ordinary",
            qos: .userInitiated
        )
        compactionQueue.async {
            do {
                _ = try AtriaManifestedColdSessionCompaction().compactAndRetire(
                    fullStore: compactionStore,
                    destinationRootURL: compactRoot,
                    now: self.now,
                    confirmedSleeps: [],
                    confirmedWorkouts: [],
                    restingHeartRate: 58,
                    maximumHeartRate: 192
                )
            } catch { errors.append(error) }
            compactionFinished.signal()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)

        let newlyCold = makeSession(ageDays: 61, sampleCount: 75)
        ordinaryQueue.async {
            do {
                _ = try ordinaryStore.persist(
                    sessions: [recent, newlyCold],
                    cutoff: self.now.addingTimeInterval(-30 * 86_400),
                    delta: .init(requiresFullRewrite: false,
                                 changedSessionIDs: [newlyCold.id]),
                    preservingUnspecifiedExistingSessions: true,
                    generatedAt: self.now.addingTimeInterval(1)
                )
            } catch { errors.append(error) }
            ordinaryFinished.signal()
        }
        XCTAssertEqual(ordinaryFinished.wait(timeout: .now() + 0.1), .timedOut,
                       "ordinary persistence must wait for the compaction manifest transaction")
        gate.release.signal()
        XCTAssertEqual(compactionFinished.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(ordinaryFinished.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "unexpected errors: \(errors.values)")

        let manifest = try ordinaryStore.loadManifest()
        XCTAssertEqual(Set(manifest.entries.map(\.sessionID)), [recent.id, newlyCold.id])
        try ordinaryStore.verifyManifest(manifest)
        XCTAssertEqual(Set(try AtriaColdSessionStore(rootURL: compactRoot)
            .facts(overlapping: DateInterval(start: now.addingTimeInterval(-200 * 86_400),
                                             end: now))
            .map(\.source.sessionID)), [old.id])
    }

    func testRepeatedProductionCrossingPreservesPreviouslyRetiredCompactHistory() throws {
        let root = try makeRoot()
        let fullStore = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let alreadyOld = makeSession(ageDays: 120, sampleCount: 70)
        let crossingSoon = makeSession(ageDays: 89, sampleCount: 75)
        let recentCold = makeSession(ageDays: 60, sampleCount: 65)
        _ = try fullStore.persist(sessions: [alreadyOld, crossingSoon, recentCold],
                                  cutoff: now.addingTimeInterval(-30 * 86_400),
                                  delta: .full,
                                  generatedAt: now)
        let compactRoot = root.appendingPathComponent("compact-tier", isDirectory: true)
        let compaction = AtriaManifestedColdSessionCompaction()
        _ = try compaction.compactAndRetire(fullStore: fullStore,
                                            destinationRootURL: compactRoot,
                                            now: now,
                                            confirmedSleeps: [],
                                            confirmedWorkouts: [],
                                            restingHeartRate: 58,
                                            maximumHeartRate: 192)

        let later = now.addingTimeInterval(3 * 86_400)
        _ = try compaction.compactAndRetire(fullStore: fullStore,
                                            destinationRootURL: compactRoot,
                                            now: later,
                                            confirmedSleeps: [],
                                            confirmedWorkouts: [],
                                            restingHeartRate: 58,
                                            maximumHeartRate: 192)

        let compactStore = AtriaColdSessionStore(rootURL: compactRoot)
        let facts = try compactStore.facts(overlapping: DateInterval(
            start: now.addingTimeInterval(-200 * 86_400), end: later
        ))
        XCTAssertEqual(Set(facts.map(\.source.sessionID)), [alreadyOld.id, crossingSoon.id])
        XCTAssertEqual(Set(try fullStore.loadManifest().entries.map(\.sessionID)), [recentCold.id])
        try compactStore.verifyCatalog(compactStore.loadCatalog())
    }

    func testCompactCorruptionAfterPublicationCannotRetireFullFidelitySource() throws {
        let root = try makeRoot()
        let fullStore = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        let old = makeSession(ageDays: 120, sampleCount: 90)
        _ = try fullStore.persist(sessions: [old],
                                  cutoff: now.addingTimeInterval(-30 * 86_400),
                                  delta: .full,
                                  generatedAt: now)
        let compactRoot = root.appendingPathComponent("compact-tier", isDirectory: true)
        let compaction = AtriaManifestedColdSessionCompaction(checkpoint: { point in
            guard point == .compactCatalogVerified else { return }
            let store = AtriaColdSessionStore(rootURL: compactRoot)
            let entry = try XCTUnwrap(store.loadCatalog().entries.first)
            try Data("corrupt-after-verification".utf8)
                .write(to: store.chunksURL.appendingPathComponent(entry.filename), options: .atomic)
        })

        XCTAssertThrowsError(try compaction.compactAndRetire(
            fullStore: fullStore,
            destinationRootURL: compactRoot,
            now: now,
            confirmedSleeps: [],
            confirmedWorkouts: [],
            restingHeartRate: 58,
            maximumHeartRate: 192
        ))
        XCTAssertEqual(try fullStore.loadManifest().entries.map(\.sessionID), [old.id],
                       "retirement must re-read compact bytes after publication")
        XCTAssertNoThrow(try fullStore.loadSession(entry: XCTUnwrap(
            fullStore.loadManifest().entries.first
        )))
    }

    func testNextPublicationPrunesOnlyExactAbandonedTemporaryGrammar() throws {
        let root = try makeRoot()
        let store = AtriaFullFidelityColdSessionStore(
            rootURL: AtriaFullFidelityColdSessionStore.rootURL(
                nextTo: root.appendingPathComponent("sessions-cold.json")
            )
        )
        try FileManager.default.createDirectory(at: store.chunksURL,
                                                withIntermediateDirectories: true)
        let chunkTemporary = store.chunksURL.appendingPathComponent(
            ".session-\(String(repeating: "a", count: 64)).json.gz.\(UUID().uuidString).tmp"
        )
        let manifestTemporary = store.rootURL.appendingPathComponent(
            ".manifest.\(UUID().uuidString).tmp"
        )
        let unknown = store.chunksURL.appendingPathComponent(".owner-note.tmp")
        for url in [chunkTemporary, manifestTemporary, unknown] {
            try Data("temporary".utf8).write(to: url)
        }

        _ = try store.persist(sessions: [makeSession(ageDays: 60, sampleCount: 40)],
                              cutoff: now.addingTimeInterval(-30 * 86_400),
                              delta: .full,
                              generatedAt: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: chunkTemporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestTemporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path),
                      "unknown hidden owner files must not be deleted")
    }

    private func migrateSyntheticSpan(days: Int) throws
        -> (eligible: Int, compactBytes: UInt64, sourceBytes: UInt64) {
        let sessions = stride(from: 5, through: days, by: 5).map {
            makeSession(ageDays: Double($0), sampleCount: 300, sampleStep: 2)
        }
        let fixture = try makeFixture(sessions: sessions)
        let result = try AtriaColdSessionMigration().migrate(sourceURL: fixture.source,
                                                              destinationRootURL: fixture.destination,
                                                              now: now)
        return (result.eligibleSessionCount, result.compressedBytes, result.sourceBytes)
    }

    private func makeSession(ageDays: Double,
                             sampleCount: Int,
                             sampleStep: Double = 5,
                             id: UUID = UUID()) -> SavedSession {
        let start = now.addingTimeInterval(-ageDays * 86_400)
        let points = (0..<sampleCount).map { index in
            SavedSession.Point(t: Double(index) * sampleStep,
                               bpm: 58 + (index * 7) % 92)
        }
        let rr = (0..<sampleCount).map { index in
            SavedSession.RRPoint(t: Double(index),
                                 ms: 650 + (index * 13) % 340,
                                 source: .standardHeartRateMeasurement2A37)
        }
        return SavedSession(id: id,
                            start: start,
                            end: start.addingTimeInterval(Double(max(1, sampleCount - 1)) * sampleStep),
                            label: "Synthetic wear",
                            points: points,
                            hrv: 42,
                            hrvSDNN: 51,
                            respiratoryRate: 14.2,
                            rrPoints: rr,
                            hrvReferenceValidated: true,
                            strapStepResearchCount: 123,
                            strapStepResearchAgreement: 0.96,
                            strapStepResearchState: "research",
                            biologicalSex: .male,
                            activeCalories: 18.5,
                            caloriesConfidence: "estimated",
                            kind: "wear",
                            eventTimeZoneIdentifier: "Asia/Kolkata")
    }

    private func makeFixture(sessions: [SavedSession]) throws -> (source: URL, destination: URL) {
        let root = try makeRoot()
        let source = root.appendingPathComponent("sessions-cold.json")
        try JSONEncoder().encode(sessions).write(to: source, options: .atomic)
        return (source, root.appendingPathComponent("cold-tier", isDirectory: true))
    }

    private func writeStreamingSessionArray(count: Int,
                                            to url: URL,
                                            make: (Int) -> SavedSession) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("[".utf8))
        for index in 0..<count {
            if index > 0 { try handle.write(contentsOf: Data(",".utf8)) }
            try handle.write(contentsOf: JSONEncoder().encode(make(index)))
        }
        try handle.write(contentsOf: Data("]".utf8))
        try handle.synchronize()
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AtriaColdSessionStorageTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }
}

private final class ColdManifestRaceGate: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var armed = false
    private var consumed = false

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func pauseFirstArmedWriter() {
        lock.lock()
        let shouldPause = armed && !consumed
        if shouldPause { consumed = true }
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 10)
    }
}

private final class ColdManifestRaceErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}
