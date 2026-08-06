import XCTest
@testable import Atria

final class AtriaResearchSharingTests: XCTestCase {
    // AtriaResearchSharing writes to UserDefaults.standard directly, so we
    // snapshot and restore its keys to keep the suite hermetic on any host.
    private var savedValues: [String: Any?] = [:]
    private let keys = [AtriaResearchSharing.optInKey,
                        AtriaResearchSharing.pseudonymKey,
                        AtriaResearchSharing.consentDateKey,
                        AtriaResearchSharing.receiptsKey]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedValues = [:]
        for key in keys {
            savedValues[key] = defaults.object(forKey: key)
            defaults.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in keys {
            if let value = savedValues[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedValues = [:]
        super.tearDown()
    }

    // MARK: - Consent lifecycle

    func testGrantConsentSetsOptInPseudonymAndConsentDate() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertFalse(AtriaResearchSharing.isOptedIn)
        XCTAssertNil(AtriaResearchSharing.pseudonym)

        AtriaResearchSharing.grantConsent(now: now)

        XCTAssertTrue(AtriaResearchSharing.isOptedIn)
        let pseudonym = AtriaResearchSharing.pseudonym
        XCTAssertNotNil(pseudonym)
        XCTAssertNotNil(UUID(uuidString: pseudonym ?? ""), "pseudonym should be a UUID string")
        XCTAssertEqual(UserDefaults.standard.double(forKey: AtriaResearchSharing.consentDateKey),
                       1_780_000_000,
                       accuracy: 0.001)
    }

    func testGrantConsentAdoptsTheInspectedPreviewPseudonym() {
        let previewPseudonym = "11111111-1111-4111-8111-111111111111"
        AtriaResearchSharing.grantConsent(now: Date(timeIntervalSince1970: 1_780_000_000),
                                          previewPseudonym: previewPseudonym)

        XCTAssertTrue(AtriaResearchSharing.isOptedIn)
        XCTAssertEqual(AtriaResearchSharing.pseudonym, previewPseudonym)
    }

    func testRevokeConsentClearsStateAndReconsentIsUnlinkable() {
        AtriaResearchSharing.grantConsent(now: Date(timeIntervalSince1970: 1_780_000_000))
        let firstPseudonym = AtriaResearchSharing.pseudonym
        XCTAssertNotNil(firstPseudonym)

        AtriaResearchSharing.revokeConsent()
        XCTAssertFalse(AtriaResearchSharing.isOptedIn)
        XCTAssertNil(AtriaResearchSharing.pseudonym)
        XCTAssertNil(UserDefaults.standard.object(forKey: AtriaResearchSharing.consentDateKey))

        AtriaResearchSharing.grantConsent(now: Date(timeIntervalSince1970: 1_780_100_000))
        let secondPseudonym = AtriaResearchSharing.pseudonym
        XCTAssertNotNil(secondPseudonym)
        XCTAssertNotEqual(firstPseudonym, secondPseudonym,
                          "re-consent must generate a fresh pseudonym (unlinkability)")
    }

    // MARK: - Banding

    func testAgeBandBandingMath() {
        // Fixed mid-year instant so Calendar.current year is stable in any timezone:
        // 1_780_000_000 = 2026-06-03 UTC.
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let year = Calendar.current.component(.year, from: now)

        XCTAssertEqual(AtriaResearchBundleBuilder.ageBand(yearOfBirth: year - 34, now: now), "30-34")
        XCTAssertEqual(AtriaResearchBundleBuilder.ageBand(yearOfBirth: year - 35, now: now), "35-39")
        XCTAssertEqual(AtriaResearchBundleBuilder.ageBand(yearOfBirth: nil, now: now), "unknown")
        XCTAssertEqual(AtriaResearchBundleBuilder.ageBand(yearOfBirth: 1800, now: now), "unknown")
    }

    func testWeightAndHeightBanding() {
        XCTAssertEqual(AtriaResearchBundleBuilder.band(76.2, width: 5, unit: "kg"), "75-80 kg")
        XCTAssertEqual(AtriaResearchBundleBuilder.band(0, width: 5, unit: "kg"), "unknown")
        XCTAssertEqual(AtriaResearchBundleBuilder.band(180.0, width: 5, unit: "cm"), "180-185 cm")
    }

    // MARK: - Payload privacy

    func testEncodedPayloadContainsNoAbsoluteDatesOrIdentifiers() throws {
        let payload = fixturePayload()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // No ISO-8601 absolute date anywhere in the bundle.
        XCTAssertNil(json.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}T", options: .regularExpression),
                     "payload must not contain absolute ISO dates")
        for forbidden in ["deviceName", "displayName", "birthYear", "timezone"] {
            XCTAssertFalse(json.contains(forbidden), "payload must not contain \(forbidden)")
        }
        XCTAssertFalse(json.contains("custom private workout title"),
                       "payload must not include a free-form workout title")
        XCTAssertFalse(json.contains("\"label\":"),
                       "payload must not encode the legacy raw workout label field")
        XCTAssertTrue(json.contains("\"activityType\":\"Running\""))
    }

    // MARK: - Receipts

    func testRecordReceiptCapsAtTwentyAndLastReceiptIsNewest() {
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0..<25 {
            AtriaResearchSharing.recordReceipt(digest: "digest-\(index)-abcdef",
                                               bytes: 100 + index,
                                               now: base.addingTimeInterval(Double(index) * 60))
        }
        let receipts = UserDefaults.standard.stringArray(forKey: AtriaResearchSharing.receiptsKey)
        XCTAssertEqual(receipts?.count, 20)
        let last = AtriaResearchSharing.lastReceipt
        XCTAssertNotNil(last)
        // digest is truncated to 12 chars: "digest-24-ab"
        XCTAssertTrue(last?.contains("digest-24-ab") ?? false, "lastReceipt should be the newest entry")
        XCTAssertTrue(last?.hasSuffix("|124") ?? false, "lastReceipt should carry the newest byte count")
        // Oldest surviving entry is index 5 after trimming.
        XCTAssertTrue(receipts?.first?.contains("digest-5-abc") ?? false)
    }

    // MARK: - Relative-time structs

    func testDayZeroTimesRoundTripExactly() throws {
        let session = AtriaResearchBundlePayload.Session(startRel: 3600.5,
                                                         endRel: 5400.9,
                                                         kind: "sleep",
                                                         hrPoints: [[3600.6, 58], [3660.7, 61]],
                                                         rrPoints: [[3600.6, 1012.5]],
                                                         motionEpochs: [.init(startRel: 3630,
                                                                              endRel: 3660,
                                                                              rows: 30,
                                                                              validatedRows: 30,
                                                                              stillnessRatio: 0.82,
                                                                              movementIntensity: 0.08,
                                                                              p95VectorDelta: 0.16,
                                                                              maximumGapSeconds: 1,
                                                                              measurementValidated: true,
                                                                              lowMotionQualified: true,
                                                                              source: AtriaRecoveredMotionEpoch.source)],
                                                         restingStable: 57,
                                                         hrv: 82)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AtriaResearchBundlePayload.Session.self, from: data)

        XCTAssertEqual(decoded.startRel, 3600.5)
        XCTAssertEqual(decoded.endRel, 5400.9)
        XCTAssertEqual(decoded.kind, "sleep")
        XCTAssertEqual(decoded.hrPoints, [[3600.6, 58], [3660.7, 61]])
        XCTAssertEqual(decoded.rrPoints, [[3600.6, 1012.5]])
        XCTAssertEqual(decoded.motionEpochs.count, 1)
        XCTAssertEqual(decoded.motionEpochs[0].startRel, 3630)
        XCTAssertEqual(decoded.motionEpochs[0].movementIntensity, 0.08)
        XCTAssertEqual(decoded.motionEpochs[0].source, AtriaRecoveredMotionEpoch.source)
        XCTAssertEqual(decoded.restingStable, 57)
        XCTAssertEqual(decoded.hrv, 82)
    }

    func testBuilderUsesOneDayZeroTimelineForMeasurementsAndLabels() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let epochDay = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))
        let workoutStart = epochDay.addingTimeInterval(2 * 3_600)
        let sessionStart = epochDay.addingTimeInterval(2 * 86_400 + 10 * 3_600)
        let sessionEnd = sessionStart.addingTimeInterval(60)

        var session = SavedSession(id: UUID(),
                                   start: sessionStart,
                                   end: sessionEnd,
                                   label: "strap capture",
                                   points: [.init(t: 10, bpm: 71), .init(t: 60, bpm: 73)])
        session.rrPoints = [.init(t: 20, ms: 900)]
        session.recoveredMotionEpochs = [AtriaRecoveredMotionEpoch(
            start: sessionStart.addingTimeInterval(30),
            end: sessionEnd,
            rows: 30,
            validatedRows: 30,
            stillnessRatio: 0.8,
            movementIntensity: 0.1,
            p95VectorDelta: 0.2,
            maximumGapSeconds: 1,
            measurementValidated: true,
            lowMotionQualified: true,
            reason: "fixture"
        )]
        let workout = UserConfirmedWorkout(id: "early-workout",
                                           createdAt: workoutStart,
                                           start: workoutStart,
                                           end: workoutStart.addingTimeInterval(30 * 60),
                                           label: "private free-text title",
                                           source: "manual",
                                           confidence: "user_confirmed",
                                           sessions: 0,
                                           samples: 0,
                                           avgHR: 0,
                                           peakHR: 0,
                                           p95HR: 0,
                                           p99HR: 0,
                                           thresholdHR: 0,
                                           streamCoveragePercent: 0,
                                           observedDuration: 0,
                                           reason: "manual",
                                           activityType: "Running")
        let journal = AtriaJournalAnswer(questionID: "tag.sleep",
                                         day: epochDay,
                                         value: .yes,
                                         loggedAt: epochDay.addingTimeInterval(8 * 3_600),
                                         source: "user")
        let input = AtriaResearchBundleBuilder.BuildInput(
            manifest: .init(schema: AtriaResearchSharing.schemaVersion,
                            pseudonym: "00000000-0000-0000-0000-000000000000",
                            appVersion: "test",
                            ageBand: "30-34",
                            weightBandKg: "75-80 kg",
                            heightBandCm: "180-185 cm",
                            biologicalSex: "male"),
            sessions: [session],
            sleeps: [],
            workouts: [workout],
            days: [],
            journalAnswers: [journal],
            calendar: calendar
        )

        let payload = try XCTUnwrap(AtriaResearchBundleBuilder.makePayload(input: input))
        let exportedSession = try XCTUnwrap(payload.sessions.first)
        let exportedWorkout = try XCTUnwrap(payload.workouts.first)
        let expectedSessionStart = 2 * 86_400.0 + 10 * 3_600.0

        XCTAssertEqual(payload.manifest.schema, AtriaResearchSharing.schemaVersion)
        XCTAssertEqual(exportedSession.startRel, expectedSessionStart, accuracy: 0.001)
        XCTAssertEqual(exportedSession.hrPoints, [[expectedSessionStart + 10, 71],
                                                   [expectedSessionStart + 60, 73]])
        XCTAssertEqual(exportedSession.rrPoints, [[expectedSessionStart + 20, 900]])
        XCTAssertEqual(exportedSession.motionEpochs.map(\.startRel), [expectedSessionStart + 30])
        XCTAssertEqual(exportedWorkout.startRel, 2 * 3_600, accuracy: 0.001)
        XCTAssertEqual(payload.journal.first?.dayIndex, 0)

        XCTAssertTrue(exportedSession.hrPoints.allSatisfy { $0[0] >= exportedSession.startRel })
        XCTAssertTrue(exportedSession.rrPoints.allSatisfy { $0[0] >= exportedSession.startRel })
        XCTAssertTrue(exportedSession.motionEpochs.allSatisfy {
            $0.startRel >= exportedSession.startRel && $0.endRel <= exportedSession.endRel
        })
        XCTAssertTrue(payload.workouts.allSatisfy { $0.startRel >= 0 && $0.endRel >= $0.startRel })
        XCTAssertTrue(payload.journal.allSatisfy { $0.dayIndex >= 0 })
    }

    // MARK: - Fixtures

    private func fixturePayload() -> AtriaResearchBundlePayload {
        AtriaResearchBundlePayload(
            manifest: .init(schema: AtriaResearchSharing.schemaVersion,
                            pseudonym: "00000000-0000-0000-0000-000000000000",
                            appVersion: "1.0",
                            ageBand: "30-34",
                            weightBandKg: "75-80 kg",
                            heightBandCm: "180-185 cm",
                            biologicalSex: "male"),
            sessions: [.init(startRel: 120.0,
                             endRel: 1920.0,
                             kind: "session",
                             hrPoints: [[0.0, 60], [10.0, 62]],
                             rrPoints: [[0.0, 1000]],
                             motionEpochs: [.init(startRel: 0,
                                                  endRel: 30,
                                                  rows: 30,
                                                  validatedRows: 30,
                                                  stillnessRatio: 0.76,
                                                  movementIntensity: 0.11,
                                                  p95VectorDelta: 0.18,
                                                  maximumGapSeconds: 1,
                                                  measurementValidated: true,
                                                  lowMotionQualified: true,
                                                  source: AtriaRecoveredMotionEpoch.source)],
                             restingStable: 58,
                             hrv: 75)],
            sleeps: [.init(startRel: 82_800.0,
                           endRel: 111_600.0,
                           durationS: 28_800.0,
                           confidence: "high",
                           stageProvenance: "atria_derived_research_only_not_reference",
                           stageReferenceEligible: false,
                           stageSeconds: ["light": 14_400, "deep": 7200])],
            workouts: [.init(startRel: 36_000.0,
                             endRel: 39_600.0,
                             activityType: "Running",
                             labelSource: "user_confirmed",
                             avgHR: 140,
                             peakHR: 172)],
            days: [.init(dayIndex: 0,
                         recoveryPercent: 67,
                         strain: 12.4,
                         sleepHours: 7.5,
                         restingHR: 56,
                         hrv: 80)],
            journal: [.init(questionID: "alcohol", dayIndex: 0, kind: "boolean", value: 0)])
    }
}
