import XCTest
@testable import Atria

final class AtriaBiologicalAgeCacheTests: XCTestCase {
    func testSameWeekBuildingCacheIsInvalidatedWhenPrerequisitesBecomeReady() {
        let building = BiologicalAgeSummary.building(
            chronologicalAge: 30,
            blockers: ["vo2max_learning", "training_load_learning"]
        )

        XCTAssertTrue(
            SessionStore.shouldReuseBiologicalAgeCadenceSummary(
                building,
                prerequisitesReady: false
            )
        )
        XCTAssertFalse(
            SessionStore.shouldReuseBiologicalAgeCadenceSummary(
                building,
                prerequisitesReady: true
            )
        )
    }

    func testSameWeekReadyFitnessAgeSurvivesOrdinarySourceChurn() {
        let ready = BiologicalAgeSummary(
            biologicalAge: 28,
            chronologicalAge: 30,
            ageDelta: -2,
            agingPaceText: "Fitness age",
            agingPaceDetail: "Qualified weekly estimate",
            factors: [],
            blockers: [],
            footnote: BiologicalAgeSummary.footnoteText
        )

        XCTAssertTrue(
            SessionStore.shouldReuseBiologicalAgeCadenceSummary(
                ready,
                prerequisitesReady: true
            )
        )
    }

    func testUnavailableFitnessAgeNamesItsFirstRealBlocker() {
        let summary = BiologicalAgeSummary.building(
            chronologicalAge: 30,
            blockers: ["vo2max_learning", "hrv_learning"]
        )

        XCTAssertFalse(summary.isReady)
        XCTAssertEqual(summary.valueText, "--")
        XCTAssertEqual(summary.compactStatusText, "VO₂ max is still learning")
    }

    func testRefreshingFitnessAgeHasDeterministicCompactStatus() {
        let summary = BiologicalAgeSummary.refreshing(chronologicalAge: 30)

        XCTAssertFalse(summary.isReady)
        XCTAssertTrue(summary.isRefreshing)
        XCTAssertEqual(summary.compactStatusText, "Updating weekly estimate")
    }

    func testBiologicalAgeCacheFreshnessRequiresWeekProfileSignatureAndReadySummary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signature = biologicalAgeSignature()
        let ready = BiologicalAgeSummary(biologicalAge: 34,
                                         chronologicalAge: 38,
                                         ageDelta: -4,
                                         agingPaceText: "Fitness age",
                                         agingPaceDetail: "HRV is helping",
                                         factors: [
                                            BioAgeFactor(id: "hrv",
                                                         label: "HRV",
                                                         ageEquivalent: 34,
                                                         deltaVsChronological: -4,
                                                         direction: .younger,
                                                         weight: 1,
                                                         detail: "70 ms HRV")
                                         ],
                                         blockers: [],
                                         footnote: BiologicalAgeSummary.footnoteText)
        let record = SessionStore.BiologicalAgeCacheRecord(schema: SessionStore.biologicalAgeCacheSchema,
                                                           computedAt: now.addingTimeInterval(-6 * 24 * 60 * 60),
                                                           signature: signature,
                                                           summary: ready)

        XCTAssertTrue(SessionStore.isBiologicalAgeCacheFresh(record,
                                                             signature: signature,
                                                             now: now))

        let staleByAge = SessionStore.BiologicalAgeCacheRecord(schema: SessionStore.biologicalAgeCacheSchema,
                                                               computedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
                                                               signature: signature,
                                                               summary: ready)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(staleByAge,
                                                              signature: signature,
                                                              now: now))

        let changedProfile = biologicalAgeSignature(profileAge: 39)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(record,
                                                              signature: changedProfile,
                                                              now: now))

        let building = BiologicalAgeSummary.building(chronologicalAge: 38,
                                                     blockers: ["hrv_learning"])
        let notReady = SessionStore.BiologicalAgeCacheRecord(schema: SessionStore.biologicalAgeCacheSchema,
                                                             computedAt: now,
                                                             signature: signature,
                                                             summary: building)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(notReady,
                                                              signature: signature,
                                                              now: now))
    }

    func testBiologicalAgeWeeklySummaryCacheAllowsBuildingOnlyForSameWeekAndSignature() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                  timeZone: calendar.timeZone,
                                                  year: 2026,
                                                  month: 7,
                                                  day: 6).date)
        let thursday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                    timeZone: calendar.timeZone,
                                                    year: 2026,
                                                    month: 7,
                                                    day: 9).date)
        let nextMonday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                      timeZone: calendar.timeZone,
                                                      year: 2026,
                                                      month: 7,
                                                      day: 13).date)
        let signature = biologicalAgeSignature()
        let building = BiologicalAgeSummary.building(chronologicalAge: 38,
                                                     blockers: ["hrv_learning"])
        let record = SessionStore.BiologicalAgeWeeklySummaryRecord(schema: SessionStore.biologicalAgeCacheSchema,
                                                                   weekStart: SessionStore.biologicalAgeCacheWeekStart(for: monday,
                                                                                                                       calendar: calendar),
                                                                   signature: signature,
                                                                   summary: building)

        XCTAssertTrue(SessionStore.isBiologicalAgeWeeklySummaryFresh(record,
                                                                     signature: signature,
                                                                     now: thursday,
                                                                     calendar: calendar))
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklySummaryFresh(record,
                                                                      signature: signature,
                                                                      now: nextMonday,
                                                                      calendar: calendar))

        let changedProfile = biologicalAgeSignature(profileAge: 39)
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklySummaryFresh(record,
                                                                      signature: changedProfile,
                                                                      now: thursday,
                                                                      calendar: calendar))

        let wrongSchema = SessionStore.BiologicalAgeWeeklySummaryRecord(schema: -1,
                                                                        weekStart: record.weekStart,
                                                                        signature: signature,
                                                                        summary: building)
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklySummaryFresh(wrongSchema,
                                                                      signature: signature,
                                                                      now: thursday,
                                                                          calendar: calendar))
    }

    func testBiologicalAgeCacheCadenceRejectsWrongSchemaAndProfile() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 11)))
        let friday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15)))
        let nextMonday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2027, month: 1, day: 18)))
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     updated: monday,
                                     hasCompletedOnboarding: true)
        let ready = BiologicalAgeSummary(biologicalAge: 34,
                                         chronologicalAge: 38,
                                         ageDelta: -4,
                                         agingPaceText: "Fitness age",
                                         agingPaceDetail: "HRV is helping",
                                         factors: [],
                                         blockers: [],
                                         footnote: BiologicalAgeSummary.footnoteText)
        let record = SessionStore.BiologicalAgeCacheRecord(
            schema: -1,
            computedAt: monday,
            signature: biologicalAgeSignature(profileAge: 38,
                                              maxHR: 188,
                                              maxHRSource: .measured,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              canonicalSessionFingerprint: 33),
            summary: ready
        )

        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                     profile: profile,
                                                                     sessionsLoaded: false,
                                                                     now: friday,
                                                                     calendar: calendar))

        let changedSex = AthleteProfile(age: 38,
                                        measuredMaxHR: 188,
                                        maxHRSource: .measured,
                                        biologicalSex: .female,
                                        updated: friday,
                                        hasCompletedOnboarding: true)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                     profile: changedSex,
                                                                     sessionsLoaded: true,
                                                                     now: friday,
                                                                     calendar: calendar))

        let changedProfile = AthleteProfile(age: 39,
                                            measuredMaxHR: 188,
                                            maxHRSource: .measured,
                                            biologicalSex: .male,
                                            updated: friday,
                                            hasCompletedOnboarding: true)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                     profile: changedProfile,
                                                                     now: friday,
                                                                     calendar: calendar))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                     profile: profile,
                                                                     now: nextMonday,
                                                                     calendar: calendar))
    }

    func testPersistedCalibratingSummaryIsFreshOnlyForLoadedSessionWeek() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let cadenceKey = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                    sessionsLoaded: true,
                                                                    now: now,
                                                                    calendar: calendar)
        let record = SessionStore.BiologicalAgeCacheRecord(
            schema: SessionStore.biologicalAgeCacheSchema,
            computedAt: now,
            cadenceKey: cadenceKey,
            signature: biologicalAgeSignature(profileAge: profile.age,
                                              biologicalSex: profile.biologicalSex,
                                              maxHR: profile.maxHR,
                                              maxHRSource: profile.maxHRSource),
            summary: .building(chronologicalAge: profile.age, blockers: ["hrv_learning"])
        )

        XCTAssertTrue(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                    profile: profile,
                                                                    sessionsLoaded: true,
                                                                    now: now,
                                                                    calendar: calendar))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(record,
                                                                     profile: profile,
                                                                     sessionsLoaded: false,
                                                                     now: now,
                                                                     calendar: calendar))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(
            record,
            profile: profile,
            sessionsLoaded: true,
            now: calendar.date(byAdding: .day, value: 7, to: now) ?? now,
            calendar: calendar
        ))
    }

    func testCalibratingWeeklyCacheRoundTripsToDisk() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let record = SessionStore.BiologicalAgeCacheRecord(
            schema: SessionStore.biologicalAgeCacheSchema,
            computedAt: now,
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                   sessionsLoaded: true,
                                                                   now: now),
            signature: biologicalAgeSignature(),
            summary: .building(chronologicalAge: profile.age, blockers: ["sleep_history_thin"])
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-biological-age-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        SessionStore.persistBiologicalAgeCacheSnapshot(record, to: url)

        let relaunchedRecord = try XCTUnwrap(SessionStore.readBiologicalAgeCache(from: url))
        XCTAssertEqual(relaunchedRecord, record)
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(relaunchedRecord,
                                                                     profile: profile,
                                                                     sessionsLoaded: false,
                                                                     now: now))
    }

    func testPersistedWeeklyCacheSurvivesMissingSignatureFieldsAfterRelaunch() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let record = SessionStore.BiologicalAgeCacheRecord(
            schema: -1,
            computedAt: now,
            signature: biologicalAgeSignature(dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              canonicalSessionFingerprint: 33),
            summary: .building(chronologicalAge: 38, blockers: ["hrv_learning"])
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var signature = try XCTUnwrap(object["signature"] as? [String: Any])
        signature.removeValue(forKey: "biologicalSex")
        signature.removeValue(forKey: "dailyMetricFingerprint")
        signature.removeValue(forKey: "sleepHistoryFingerprint")
        signature.removeValue(forKey: "canonicalSessionFingerprint")
        signature.removeValue(forKey: "todayZone2PlusMinutes")
        object["signature"] = signature

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-biological-age-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONSerialization.data(withJSONObject: object).write(to: url, options: .atomic)

        let relaunchedRecord = try XCTUnwrap(SessionStore.readBiologicalAgeCache(from: url))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheCadenceFresh(relaunchedRecord,
                                                                     profile: AthleteProfile(age: AthleteProfile.defaultAge,
                                                                                             measuredMaxHR: AthleteProfile.defaultMeasuredMaxHR,
                                                                                             maxHRSource: .measured,
                                                                                             updated: nil,
                                                                                             hasCompletedOnboarding: false),
                                                                     sessionsLoaded: true,
                                                                     now: now))
    }

    func testColdBiologicalAgePlaceholderIsExplicitlyRefreshing() {
        let summary = BiologicalAgeSummary.refreshing(chronologicalAge: 38)

        XCTAssertFalse(summary.isReady)
        XCTAssertTrue(summary.isRefreshing)
        XCTAssertEqual(summary.detailText, "Refreshing weekly estimate")
        XCTAssertEqual(summary.narrative, "Updating weekly estimate")
    }

    func testBiologicalAgeWeeklyCadenceFreshIgnoresSameWeekSignatureChurn() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                  timeZone: calendar.timeZone,
                                                  year: 2026,
                                                  month: 7,
                                                  day: 6).date)
        let thursday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                    timeZone: calendar.timeZone,
                                                    year: 2026,
                                                    month: 7,
                                                    day: 9).date)
        let nextMonday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                      timeZone: calendar.timeZone,
                                                      year: 2026,
                                                      month: 7,
                                                      day: 13).date)
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     updated: monday,
                                     hasCompletedOnboarding: true)
        let cadenceKey = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                    now: monday,
                                                                    calendar: calendar)
        let building = BiologicalAgeSummary.building(chronologicalAge: 38,
                                                     blockers: ["hrv_learning"])
        let record = SessionStore.BiologicalAgeWeeklySummaryRecord(
            schema: SessionStore.biologicalAgeCacheSchema,
            weekStart: cadenceKey.weekStart,
            cadenceKey: cadenceKey,
            signature: biologicalAgeSignature(dailyMetricFingerprint: 11,
                                              canonicalSessionFingerprint: 22),
            summary: building
        )

        XCTAssertTrue(SessionStore.isBiologicalAgeWeeklyCadenceFresh(
            record,
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                   now: thursday,
                                                                   calendar: calendar)
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklySummaryFresh(
            record,
            signature: biologicalAgeSignature(dailyMetricFingerprint: 12,
                                              canonicalSessionFingerprint: 23),
            now: thursday,
            calendar: calendar
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklyCadenceFresh(
            record,
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                   now: nextMonday,
                                                                   calendar: calendar)
        ))

        var changedSex = profile
        changedSex.biologicalSex = .male
        XCTAssertFalse(SessionStore.isBiologicalAgeWeeklyCadenceFresh(
            record,
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: changedSex,
                                                                   now: thursday,
                                                                   calendar: calendar)
        ))
    }

    func testSameWeekBiologicalAgeDeferralAllowsExplicitProfileCadenceChange() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6)))
        let thursday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 9)))
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     updated: monday,
                                     hasCompletedOnboarding: true)
        let originalKey = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                      sessionsLoaded: true,
                                                                      now: monday,
                                                                      calendar: calendar)

        XCTAssertTrue(SessionStore.shouldDeferBiologicalAgeRefreshUntilNextWeek(
            recordWeekStart: originalKey.weekStart,
            recordCadenceKey: originalKey,
            requestedCadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(
                profile: profile,
                sessionsLoaded: true,
                now: thursday,
                calendar: calendar
            )
        ))

        var editedProfile = profile
        editedProfile.biologicalSex = .male
        let editedKey = SessionStore.biologicalAgeWeeklyCadenceKey(profile: editedProfile,
                                                                    sessionsLoaded: true,
                                                                    now: thursday,
                                                                    calendar: calendar)
        XCTAssertFalse(SessionStore.shouldDeferBiologicalAgeRefreshUntilNextWeek(
            recordWeekStart: originalKey.weekStart,
            recordCadenceKey: originalKey,
            requestedCadenceKey: editedKey
        ))
    }

    func testBiologicalAgeRefreshRequestCoalescesByFullCadenceKey() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .female,
                                     updated: now,
                                     hasCompletedOnboarding: true)
        let originalCadence = SessionStore.biologicalAgeWeeklyCadenceKey(profile: profile,
                                                                          sessionsLoaded: true,
                                                                          now: now)
        let first = SessionStore.BiologicalAgeRefreshRequestKey(cadenceKey: originalCadence)
        let duplicate = SessionStore.BiologicalAgeRefreshRequestKey(cadenceKey: originalCadence)
        XCTAssertEqual(first, duplicate)

        var editedProfile = profile
        editedProfile.age = 39
        let edited = SessionStore.BiologicalAgeRefreshRequestKey(
            cadenceKey: SessionStore.biologicalAgeWeeklyCadenceKey(profile: editedProfile,
                                                                    sessionsLoaded: true,
                                                                    now: now)
        )
        XCTAssertNotEqual(first, edited)
    }

    func testBiologicalAgeCacheFreshnessTracksSlowMovingInputs() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let signature = biologicalAgeSignature(vo2MaxValueTenth: 421,
                                               dailyMetricFingerprint: 11,
                                               sleepHistoryFingerprint: 22,
                                               confirmedSleepFingerprint: 33,
                                               canonicalSessionFingerprint: 44,
                                               baselineHRV: 61,
                                               trainingLoadConfidence: "local")
        let ready = BiologicalAgeSummary(biologicalAge: 34,
                                         chronologicalAge: 38,
                                         ageDelta: -4,
                                         agingPaceText: "Fitness age",
                                         agingPaceDetail: "HRV is helping",
                                         factors: [],
                                         blockers: [],
                                         footnote: BiologicalAgeSummary.footnoteText)
        let record = SessionStore.BiologicalAgeCacheRecord(schema: SessionStore.biologicalAgeCacheSchema,
                                                           computedAt: now,
                                                           signature: signature,
                                                           summary: ready)

        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 430,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              confirmedSleepFingerprint: 33,
                                              canonicalSessionFingerprint: 44,
                                              baselineHRV: 61,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 421,
                                              dailyMetricFingerprint: 12,
                                              sleepHistoryFingerprint: 22,
                                              confirmedSleepFingerprint: 33,
                                              canonicalSessionFingerprint: 44,
                                              baselineHRV: 61,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 421,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 23,
                                              confirmedSleepFingerprint: 33,
                                              canonicalSessionFingerprint: 44,
                                              baselineHRV: 61,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 421,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              confirmedSleepFingerprint: 34,
                                              canonicalSessionFingerprint: 44,
                                              baselineHRV: 61,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 421,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              confirmedSleepFingerprint: 33,
                                              canonicalSessionFingerprint: 45,
                                              baselineHRV: 61,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
        XCTAssertFalse(SessionStore.isBiologicalAgeCacheFresh(
            record,
            signature: biologicalAgeSignature(vo2MaxValueTenth: 421,
                                              dailyMetricFingerprint: 11,
                                              sleepHistoryFingerprint: 22,
                                              confirmedSleepFingerprint: 33,
                                              canonicalSessionFingerprint: 44,
                                              baselineHRV: 62,
                                              trainingLoadConfidence: "local"),
            now: now
        ))
    }

    func testBiologicalAgeSignatureMemoKeyIsWeeklyAndIgnoresCheckpointChurn() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let thursday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                    timeZone: calendar.timeZone,
                                                    year: 2026,
                                                    month: 7,
                                                    day: 9,
                                                    hour: 12).date)
        let friday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                  timeZone: calendar.timeZone,
                                                  year: 2026,
                                                  month: 7,
                                                  day: 10,
                                                  hour: 12).date)
        let nextMonday = try XCTUnwrap(DateComponents(calendar: calendar,
                                                      timeZone: calendar.timeZone,
                                                      year: 2026,
                                                      month: 7,
                                                      day: 13,
                                                      hour: 12).date)
        let profile = AthleteProfile(age: 38,
                                     measuredMaxHR: 188,
                                     maxHRSource: .measured,
                                     biologicalSex: .male,
                                     updated: thursday,
                                     hasCompletedOnboarding: true)
        let vo2 = VO2MaxEstimateSummary(value: 42.1,
                                        confidence: "local",
                                        detail: "",
                                        narrative: "",
                                        trendText: "",
                                        trendDetail: "",
                                        trendDelta: 0.2)
        let baseline = PersonalBaseline(restingHR: 58,
                                        hrvEMA: 62,
                                        sessions: 20,
                                        updated: thursday,
                                        samples: [PersonalBaseline.BaselineSample(date: thursday,
                                                                                  restingHR: 58,
                                                                                  rmssd: 62,
                                                                                  overnight: true)])
        let trainingLoad = TrainingLoadSummary(acuteLoad: 42,
                                               chronicLoad: 38,
                                               ratio: 1.1,
                                               monotony: 1.4,
                                               confidence: "local",
                                               readiness: "good",
                                               acwrSignal: "good",
                                               monotonySignal: "good",
                                               targetBand: 0.8...1.3,
                                               detail: "")

        let key = SessionStore.biologicalAgeSignatureMemoKey(profile: profile,
                                                             vo2MaxEstimate: vo2,
                                                             dailyMetricHistoryRevision: 4,
                                                             sleepHistorySnapshotRevision: 5,
                                                             confirmedSleepsRevision: 6,
                                                             canonicalSessionsRevision: 7,
                                                             sourceSessionsRevision: 9,
                                                             canonicalSessionCount: 12,
                                                             sessionsLoaded: true,
                                                             baseline: baseline,
                                                             trainingLoadSummary: trainingLoad,
                                                             now: thursday,
                                                             calendar: calendar)
        let sameWeekCheckpointChurn = SessionStore.biologicalAgeSignatureMemoKey(profile: profile,
                                                                                 vo2MaxEstimate: vo2,
                                                                                 dailyMetricHistoryRevision: 4,
                                                                                 sleepHistorySnapshotRevision: 5,
                                                                                 confirmedSleepsRevision: 6,
                                                                                 canonicalSessionsRevision: 8,
                                                                                 sourceSessionsRevision: 9,
                                                                                 canonicalSessionCount: 12,
                                                                                 sessionsLoaded: true,
                                                                                 baseline: baseline,
                                                                                 trainingLoadSummary: trainingLoad,
                                                                                 now: friday,
                                                                                 calendar: calendar)
        XCTAssertEqual(key, sameWeekCheckpointChurn)

        let changedSexProfile = AthleteProfile(age: 38,
                                               measuredMaxHR: 188,
                                               maxHRSource: .measured,
                                               biologicalSex: .female,
                                               updated: friday,
                                               hasCompletedOnboarding: true)
        let changedSex = SessionStore.biologicalAgeSignatureMemoKey(profile: changedSexProfile,
                                                                    vo2MaxEstimate: vo2,
                                                                    dailyMetricHistoryRevision: 4,
                                                                    sleepHistorySnapshotRevision: 5,
                                                                    confirmedSleepsRevision: 6,
                                                                    canonicalSessionsRevision: 7,
                                                                    sourceSessionsRevision: 9,
                                                                    canonicalSessionCount: 12,
                                                                    sessionsLoaded: true,
                                                                    baseline: baseline,
                                                                    trainingLoadSummary: trainingLoad,
                                                                    now: friday,
                                                                    calendar: calendar)
        XCTAssertNotEqual(key, changedSex)

        let newSessionCohort = SessionStore.biologicalAgeSignatureMemoKey(profile: profile,
                                                                          vo2MaxEstimate: vo2,
                                                                          dailyMetricHistoryRevision: 4,
                                                                          sleepHistorySnapshotRevision: 5,
                                                                          confirmedSleepsRevision: 6,
                                                                          canonicalSessionsRevision: 8,
                                                                          sourceSessionsRevision: 10,
                                                                          canonicalSessionCount: 12,
                                                                          sessionsLoaded: true,
                                                                          baseline: baseline,
                                                                          trainingLoadSummary: trainingLoad,
                                                                          now: friday,
                                                                          calendar: calendar)
        XCTAssertNotEqual(key, newSessionCohort)

        let deferredLoadNotCompleted = SessionStore.biologicalAgeSignatureMemoKey(profile: profile,
                                                                                vo2MaxEstimate: vo2,
                                                                                dailyMetricHistoryRevision: 4,
                                                                                sleepHistorySnapshotRevision: 5,
                                                                                confirmedSleepsRevision: 6,
                                                                                canonicalSessionsRevision: 8,
                                                                                sourceSessionsRevision: 9,
                                                                                canonicalSessionCount: 12,
                                                                                sessionsLoaded: false,
                                                                                baseline: baseline,
                                                                                trainingLoadSummary: trainingLoad,
                                                                                now: friday,
                                                                                calendar: calendar)
        XCTAssertNotEqual(key, deferredLoadNotCompleted)

        let nextWeek = SessionStore.biologicalAgeSignatureMemoKey(profile: profile,
                                                                  vo2MaxEstimate: vo2,
                                                                  dailyMetricHistoryRevision: 4,
                                                                  sleepHistorySnapshotRevision: 5,
                                                                  confirmedSleepsRevision: 6,
                                                                  canonicalSessionsRevision: 7,
                                                                  sourceSessionsRevision: 9,
                                                                  canonicalSessionCount: 12,
                                                                  sessionsLoaded: true,
                                                                  baseline: baseline,
                                                                  trainingLoadSummary: trainingLoad,
                                                                  now: nextMonday,
                                                                  calendar: calendar)
        XCTAssertNotEqual(key, nextWeek)
    }

    private func biologicalAgeSignature(profileAge: Int = 38,
                                        biologicalSex: AthleteProfile.BiologicalSex = .male,
                                        maxHR: Int = 188,
                                        maxHRSource: AthleteProfile.HRMaxSource = .measured,
                                        vo2MaxValueTenth: Int? = nil,
                                        vo2MaxConfidence: String = "",
                                        dailyMetricFingerprint: UInt64 = 0,
                                        sleepHistoryFingerprint: UInt64 = 0,
                                        confirmedSleepFingerprint: UInt64 = 0,
                                        canonicalSessionFingerprint: UInt64 = 0,
                                        baselineHRV: Int? = nil,
                                        trainingLoadConfidence: String = "") -> SessionStore.BiologicalAgeCacheSignature {
        SessionStore.BiologicalAgeCacheSignature(profileAge: profileAge,
                                                 biologicalSex: biologicalSex,
                                                 maxHR: maxHR,
                                                 maxHRSource: maxHRSource,
                                                 vo2MaxValueTenth: vo2MaxValueTenth,
                                                 vo2MaxConfidence: vo2MaxConfidence,
                                                 dailyMetricFingerprint: dailyMetricFingerprint,
                                                 sleepHistoryFingerprint: sleepHistoryFingerprint,
                                                 confirmedSleepFingerprint: confirmedSleepFingerprint,
                                                 canonicalSessionFingerprint: canonicalSessionFingerprint,
                                                 baselineHRV: baselineHRV,
                                                 trainingLoadConfidence: trainingLoadConfidence)
    }
}
