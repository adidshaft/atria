import XCTest
@testable import Atria

final class AtriaStressMonitorTests: XCTestCase {
    @MainActor
    func testLiveStoreRequiresExplicitActiveSleepEvidenceBeforeShowingAsleep() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let awakeStore = AtriaStressMonitorStore()
        awakeStore.update(
            heartRate: 64,
            hasContact: true,
            recentRRSamples: [],
            isRecording: false,
            zoneIndex: 0,
            hrvSnapshot: nil,
            baseline: baseline,
            restingMaxHR: restingMaxHR,
            hasActiveSleepEvidence: false,
            now: now
        )
        XCTAssertNotEqual(awakeStore.state.kind, .asleep)

        let sleepingStore = AtriaStressMonitorStore()
        sleepingStore.update(
            heartRate: 64,
            hasContact: true,
            recentRRSamples: [],
            isRecording: false,
            zoneIndex: 0,
            hrvSnapshot: nil,
            baseline: baseline,
            restingMaxHR: restingMaxHR,
            hasActiveSleepEvidence: true,
            now: now
        )
        XCTAssertEqual(sleepingStore.state.kind, .asleep)
    }

    // Added 2026-07-31 (device review: stress tile stuck at "collecting 2 min
    // of live signal"): warm-up is anchored to accepted-HR continuity. A brief
    // contact flicker must not restart the 2-minute clock; a sustained loss
    // (longer than the 30s grace) must.
    @MainActor
    func testWarmUpSurvivesBriefContactFlicker() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, hasContact: Bool) {
            store.update(heartRate: hasContact ? 62 : 0,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)
        tick(atOffset: 50, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)

        // 100s in, one flicker (single zero-contact tick), contact resumes.
        tick(atOffset: 100, hasContact: false)
        XCTAssertEqual(store.state.kind, .noSignal)
        tick(atOffset: 106, hasContact: true)

        // 125s after first contact: warm-up completes because the flicker did
        // not restart the clock.
        tick(atOffset: 125, hasContact: true)
        XCTAssertEqual(store.state.kind, .scored)
    }

    @MainActor
    func testWarmUpRestartsAfterSustainedContactLoss() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, hasContact: Bool) {
            store.update(heartRate: hasContact ? 62 : 0,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, hasContact: true)
        tick(atOffset: 50, hasContact: true)
        tick(atOffset: 100, hasContact: true)
        // A 75s outage — past the 60s continuity grace.
        tick(atOffset: 130, hasContact: false)
        tick(atOffset: 175, hasContact: false)
        // Contact returns: this is fresh contact and warm-up restarts, so at
        // +40s of the new epoch the tile is still honestly warming up.
        tick(atOffset: 180, hasContact: true)
        tick(atOffset: 220, hasContact: true)
        XCTAssertEqual(store.state.kind, .warmingUp)
        // ...and completes 120s after the new contact epoch (ticks stay inside
        // the production <=30s evaluation cadence).
        tick(atOffset: 260, hasContact: true)
        tick(atOffset: 301, hasContact: true)
        XCTAssertEqual(store.state.kind, .scored)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let restingMaxHR: (rest: Int, max: Int) = (rest: 60, max: 190)

    // MARK: Baseline fixture

    /// Builds a `PersonalBaseline` with `dayCount` distinct fresh days (all
    /// overnight), each contributing a resting-HR sample alternating
    /// `restingMean +/- restingSD`. When `lnRMSSDMean`/`lnRMSSDSD` are supplied,
    /// the first `hrvSampleDays` of those days also carry an RMSSD value
    /// alternating around the given ln-space mean/sd, so the HRV trust gate
    /// (14 distinct days) can be controlled independently of the resting gate.
    private func makeBaseline(restingMean: Double,
                              restingSD: Double,
                              lnRMSSDMean: Double? = nil,
                              lnRMSSDSD: Double? = nil,
                              hrvSampleDays: Int = 0,
                              dayCount: Int = 20) -> PersonalBaseline {
        var samples: [PersonalBaseline.BaselineSample] = []
        for day in 0..<dayCount {
            let date = now.addingTimeInterval(-Double(day + 1) * 24 * 60 * 60)
            let sign = (day % 2 == 0) ? 1.0 : -1.0
            let restingHR = restingMean + sign * restingSD
            var rmssd: Double?
            if day < hrvSampleDays, let lnRMSSDMean, let lnRMSSDSD {
                rmssd = exp(lnRMSSDMean + sign * lnRMSSDSD)
            }
            samples.append(PersonalBaseline.BaselineSample(date: date,
                                                            restingHR: restingHR,
                                                            rmssd: rmssd,
                                                            overnight: true))
        }
        let hrvEMA = lnRMSSDMean.map(exp)
        return PersonalBaseline(restingHR: restingMean, hrvEMA: hrvEMA,
                                sessions: dayCount, updated: now, samples: samples)
    }

    // MARK: Scored cases

    func testCalmAtPersonalBaselineHROnly() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 60,
                                             hrWindow: [60, 60, 60],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertEqual(state.level, .calm)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only")
    }

    /// Corroboration model (2026-08-08 adversarial review): a lone signal — an
    /// elevated HR alone OR a big (nonspecific) HRV drop alone — reads at most
    /// Medium; only elevated HR AND suppressed HRV together reach High. This
    /// replaces the noisy-OR that let either lone signal, or two merely-moderate
    /// signals, escalate to High.
    func testHighRequiresBothHRAndHRVCorroboration() {
        let baseline = makeBaseline(restingMean: 55, restingSD: 3,
                                    lnRMSSDMean: log(45), lnRMSSDSD: 0.15,
                                    hrvSampleDays: 20)
        let awake = (center: 72.0, spread: 12.0)
        func result(hr: Int, rmssd: Double) -> AtriaStressState {
            AtriaStressMonitor.score(hrNow: hr, hrWindow: [hr, hr, hr], rrWindowMs: [],
                                     hrvFallbackRMSSD: rmssd, baseline: baseline,
                                     restingMaxHR: restingMaxHR, workoutActive: false,
                                     zoneIndex: 0, inSleepWindow: false, hasContact: true,
                                     contactAgeSeconds: 300, awakeReference: awake, now: now)
        }
        // Lone big HRV drop, calm HR → Medium (not High): HRV is nonspecific.
        XCTAssertEqual(result(hr: 64, rmssd: 5).level, .medium)
        // Lone elevated HR, normal HRV → Medium (not High).
        XCTAssertEqual(result(hr: 95, rmssd: 45).level, .medium)
        // Both elevated HR AND suppressed HRV → High (corroboration).
        let corroborated = result(hr: 95, rmssd: 5)
        XCTAssertEqual(corroborated.level, .high)
        XCTAssertTrue(corroborated.hrvAvailable)
        XCTAssertEqual(corroborated.detail, "HR + HRV")
    }

    func testHRVOnlyModeCapsEmittedLevelAtMedium() {
        // Resting baseline is trusted, but zero distinct HRV days means the
        // HRV baseline never reaches trust -- HR alone can push activation to
        // 1.0, but the emitted level must never claim "High" without HRV
        // corroboration.
        let baseline = makeBaseline(restingMean: 60, restingSD: 2, hrvSampleDays: 0)

        // Genuinely elevated HR (well above the awake reference), so activation
        // saturates and the cap is what's under test. Post-rescoring (2026-08-08)
        // an HR only mildly above rest is correctly Calm/Low, so an old value
        // like 80 would no longer exercise the cap.
        let state = AtriaStressMonitor.score(hrNow: 95,
                                             hrWindow: [95, 94, 95],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .scored)
        XCTAssertFalse(state.hrvAvailable)
        XCTAssertEqual(state.detail, "HR-only")
        XCTAssertEqual(state.level, .medium, "HR-only mode must cap at Medium, never High")
        XCTAssertNotEqual(state.level, .high)
    }

    /// The 2026-08-08 rescoring: awake HR at/near the wearer's own awake
    /// reference reads Calm (not Medium), and only genuine elevation climbs.
    /// Validated against 4 real days where the old resting-referenced math
    /// pinned 90-98% of the waking day to Medium.
    func testAwakeReferencedStressIsCalmAtTypicalAwakeHR() {
        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)
        let awake = (center: 73.0, spread: 12.0) // this wearer's real median/spread

        func level(hr: Int) -> AtriaStressLevel? {
            AtriaStressMonitor.score(hrNow: hr, hrWindow: [hr, hr, hr], rrWindowMs: [],
                                     hrvFallbackRMSSD: nil, baseline: baseline,
                                     restingMaxHR: restingMaxHR, workoutActive: false,
                                     zoneIndex: 0, inSleepWindow: false, hasContact: true,
                                     contactAgeSeconds: 300, awakeReference: awake, now: now).level
        }
        XCTAssertEqual(level(hr: 73), .calm, "at the awake reference → Calm, not Medium")
        XCTAssertEqual(level(hr: 62), .calm, "below the awake reference → Calm")
        XCTAssertEqual(level(hr: 95), .medium, "genuine elevation → Medium (HR-only cap)")

        // Same wearer, WITHOUT a learned reference: the physiological default
        // (resting + offset) must also keep typical awake HR out of Medium.
        let atRestingAwake = AtriaStressMonitor.score(
            hrNow: 71, hrWindow: [71, 71, 71], rrWindowMs: [], hrvFallbackRMSSD: nil,
            baseline: baseline, restingMaxHR: restingMaxHR, workoutActive: false,
            zoneIndex: 0, inSleepWindow: false, hasContact: true,
            contactAgeSeconds: 300, now: now).level
        XCTAssertNotEqual(atRestingAwake, .medium,
                          "default awake reference must not pin typical awake HR to Medium")
    }

    func testAwakeReferenceLearnsRobustMedianOnceWarm() {
        let base = Date(timeIntervalSince1970: 1_786_000_000)
        // 70 samples over 10 min, mostly ~72 bpm with a couple of stray spikes.
        var buffer: [(t: Date, bpm: Int)] = []
        for i in 0..<70 {
            let bpm = (i == 10 || i == 40) ? 150 : 72
            buffer.append((t: base.addingTimeInterval(Double(i) * 9), bpm: bpm))
        }
        let ref = AtriaStressMonitorStore.awakeReference(from: buffer, now: base.addingTimeInterval(700))
        XCTAssertNotNil(ref)
        XCTAssertEqual(ref!.center, 72, accuracy: 0.5, "median ignores the two spikes")

        // Too few samples / too short a span → nil (scorer uses its default).
        let cold = Array(buffer.prefix(10))
        XCTAssertNil(AtriaStressMonitorStore.awakeReference(from: cold, now: base.addingTimeInterval(90)))
    }

    // Persisted awake reference (2026-08-08 §"persist awake reference"): the
    // 45-min buffer takes ~8 min of quiet-awake wear to warm up, so without a
    // seed every cold launch scores the first minutes against the fixed
    // physiological default. Store A learns and persists a reference; a fresh
    // Store B on the same suite must seed from it and score the wearer's own
    // (high-for-most-people) awake HR as Calm on its very first scored tick —
    // before its own buffer can warm — where an unseeded Store C does not.
    @MainActor
    func testAwakeReferencePersistsAndSeedsFreshLaunchBeforeBufferWarms() throws {
        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)
        let awakeHR = 85 // this wearer's real awake HR, well above rest (60)

        let suiteName = "atria.stress.awakeref.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Store A: warm the awake buffer past its 60-sample / 8-min trust gate so
        // a reference is learned and written to the injected suite.
        let storeA = AtriaStressMonitorStore(defaults: suite)
        for i in 0..<70 {
            storeA.update(heartRate: (i % 2 == 0) ? 84 : 86,
                          hasContact: true,
                          recentRRSamples: [],
                          isRecording: false,
                          zoneIndex: 0,
                          hrvSnapshot: nil,
                          baseline: baseline,
                          restingMaxHR: restingMaxHR,
                          hasActiveSleepEvidence: false,
                          now: now.addingTimeInterval(Double(i) * 9))
        }
        let persisted = try XCTUnwrap(
            AtriaStressMonitorStore.loadPersistedAwakeReference(defaults: suite),
            "a warm awake buffer must persist its learned reference")
        XCTAssertEqual(persisted.center, 85, accuracy: 1.0)

        // Drive a fresh store to its FIRST scored tick (≈125s of contact) with a
        // handful of same-HR ticks — too few to warm its own buffer, so scoring
        // depends entirely on whatever reference was seeded at launch.
        func warmToFirstScoredTick(_ store: AtriaStressMonitorStore) {
            for offset in [0.0, 50.0, 100.0, 125.0] {
                store.update(heartRate: awakeHR,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: false,
                             now: now.addingTimeInterval(1000 + offset))
            }
        }

        // Store B: fresh launch on the SAME suite → seeded → Calm at 85 bpm.
        let storeB = AtriaStressMonitorStore(defaults: suite)
        warmToFirstScoredTick(storeB)
        XCTAssertEqual(storeB.state.kind, .scored)
        XCTAssertEqual(storeB.state.level, .calm,
                       "seeded from the wearer's own ~85 bpm awake HR, 85 reads Calm")

        // Store C: fresh launch on an EMPTY suite → no seed → the physiological
        // default centers far lower, so the same 85 bpm does NOT read Calm.
        let emptyName = "atria.stress.awakeref.test.empty.\(UUID().uuidString)"
        let emptySuite = try XCTUnwrap(UserDefaults(suiteName: emptyName))
        defer { emptySuite.removePersistentDomain(forName: emptyName) }
        let storeC = AtriaStressMonitorStore(defaults: emptySuite)
        warmToFirstScoredTick(storeC)
        XCTAssertEqual(storeC.state.kind, .scored)
        XCTAssertNotEqual(storeC.state.level, .calm,
                          "without a seed the default reference flags this wearer's typical awake HR as elevated")
    }

    // A persisted reference older than the seed max-age must be ignored — awake
    // HR drifts with fitness/illness/season, so a stale seed is worse than the
    // default. A ~30-day-old seed for a low-awake-HR profile must NOT drag a
    // genuinely-typical reading; the store falls back to the default instead.
    @MainActor
    func testStaleAwakeReferenceSeedIsIgnored() throws {
        let baseline = makeBaseline(restingMean: 56, restingSD: 3, hrvSampleDays: 0)

        let suiteName = "atria.stress.awakeref.stale.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        // Hand-write a seed stamped 30 days ago (past the 14-day max-age).
        let stale = AtriaAwakeReferenceSnapshot(center: 120,
                                                spread: 6,
                                                updatedAt: now.addingTimeInterval(-30 * 24 * 3600))
        suite.set(try JSONEncoder().encode(stale), forKey: "atria.stress.awakeReference.v1")

        let store = AtriaStressMonitorStore(defaults: suite)
        for offset in [0.0, 50.0, 100.0, 125.0] {
            store.update(heartRate: 85,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }
        // A fresh center-120 seed would make 85 bpm read Calm; because the seed
        // is stale it is discarded and the default (center ≈ rest + 15) applies,
        // so 85 bpm scores elevated exactly as in the unseeded case.
        XCTAssertEqual(store.state.kind, .scored)
        XCTAssertNotEqual(store.state.level, .calm,
                          "a seed past the max-age must be ignored in favour of the default")
    }

    // Audit §1 #7: in HR-only mode the emitted level is capped at Medium, but
    // the store used to publish the uncapped activation EMA — so the detail
    // gauge and the history timeline (both score = activation × 3) could render
    // "High" while the label read "Medium". Both the published activation and
    // the recorded history point must be capped to the Medium ceiling.
    @MainActor
    func testHROnlyModeCapsPublishedActivationToMediumCeiling() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        let store = AtriaStressMonitorStore()

        // 98 bpm: high enough that the HR-only activation lands in the High band
        // against the default awake reference, yet at/below rest+40 (100) so it
        // is not suppressed as activity. Only a few ticks → the awake buffer
        // stays cold → the default reference (not a learned ~98) drives scoring.
        for offset in [0.0, 50.0, 100.0, 125.0] {
            store.update(heartRate: 98,
                         hasContact: true,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 1,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        XCTAssertEqual(store.state.kind, .scored)
        XCTAssertEqual(store.state.level, .medium, "HR-only caps the level at Medium")
        XCTAssertFalse(store.state.hrvAvailable)
        XCTAssertLessThanOrEqual(store.state.rawActivation,
                                 AtriaStressMonitor.mediumUpperBound + 1e-9,
                                 "published activation must not exceed the Medium ceiling")
        // Guard against a regression where the cap silently zeroes the reading:
        // this is a genuine top-of-Medium reading, so it should sit near the cap.
        XCTAssertGreaterThan(store.state.rawActivation, AtriaStressMonitor.lowUpperBound,
                             "a genuinely elevated HR-only reading should still fill the Medium band")

        // The timeline reads the recorded history point — the same cap must apply.
        guard let recorded = store.history.last else {
            return XCTFail("a scored tick must record a history point")
        }
        XCTAssertLessThanOrEqual(recorded.activation,
                                 AtriaStressMonitor.mediumUpperBound + 1e-9,
                                 "recorded timeline activation must also be capped")
    }

    // MARK: Slow multi-day awake baseline (audit B3, recording-only)

    private func fillBaselineDay(_ archive: inout AtriaAwakeBaselineArchive,
                                 day: Date,
                                 bpm: Int,
                                 count: Int,
                                 calendar: Calendar) {
        for i in 0..<count {
            _ = archive.record(bpm: bpm,
                               at: day.addingTimeInterval(Double(i) * 30),
                               calendar: calendar)
        }
    }

    func testAwakeBaselineDayMedianFromHistogram() throws {
        var day = AtriaAwakeBaselineArchive.Day(day: now, histogram: [:], lastSampleAt: .distantPast)
        // 70,70,72,74,74 → median 72; a stray 150 is one of six → still 72/73.
        day.histogram = [70: 2, 72: 1, 74: 2]
        XCTAssertEqual(try XCTUnwrap(day.median), 72, accuracy: 0.001)
        day.histogram[150] = 1 // 6 samples: sorted 70,70,72,74,74,150 → median (72+74)/2
        XCTAssertEqual(try XCTUnwrap(day.median), 73, accuracy: 0.001)
    }

    func testAwakeBaselineIgnoresASingleStressedDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()

        // Three calm days at 72 bpm, then a whole stressed day at 95 bpm.
        for offset in 0..<3 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: d0))
            fillBaselineDay(&archive, day: day, bpm: 72, count: 40, calendar: calendar)
        }
        let stressedDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: d0))
        fillBaselineDay(&archive, day: stressedDay, bpm: 95, count: 40, calendar: calendar)

        XCTAssertEqual(archive.qualifyingDayCount, 4)
        // median of daily medians [72,72,72,95] = 72 — the stressed day is one
        // outlier and cannot move the baseline. THIS is the B3 property.
        XCTAssertEqual(try XCTUnwrap(archive.multiDayCenter()), 72, accuracy: 0.001)
    }

    func testAwakeBaselineWithheldUntilEnoughQualifyingDaysAndSamples() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()

        // Two well-sampled days: below the 3-day floor → nil.
        for offset in 0..<2 {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: d0))
            fillBaselineDay(&archive, day: day, bpm: 70, count: 40, calendar: calendar)
        }
        XCTAssertNil(archive.multiDayCenter(), "two days is below the qualifying-day floor")

        // A third day but under the per-day sample floor must not qualify it.
        let thinDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: d0))
        fillBaselineDay(&archive, day: thinDay, bpm: 70, count: 10, calendar: calendar)
        XCTAssertEqual(archive.qualifyingDayCount, 2)
        XCTAssertNil(archive.multiDayCenter(), "a day under the per-day sample floor does not count")

        // Filling it past the floor unlocks the center.
        fillBaselineDay(&archive,
                        day: thinDay.addingTimeInterval(1000),
                        bpm: 70,
                        count: 30,
                        calendar: calendar)
        XCTAssertEqual(archive.qualifyingDayCount, 3)
        XCTAssertEqual(try XCTUnwrap(archive.multiDayCenter()), 70, accuracy: 0.001)
    }

    func testAwakeBaselineRetentionDropsOldDaysAndRoundTrips() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let d0 = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 9)))
        var archive = AtriaAwakeBaselineArchive()
        fillBaselineDay(&archive, day: d0, bpm: 70, count: 5, calendar: calendar)
        // A sample 40 days later must evict the original day (30-day retention).
        let farLater = try XCTUnwrap(calendar.date(byAdding: .day, value: 40, to: d0))
        _ = archive.record(bpm: 71, at: farLater, calendar: calendar)
        XCTAssertEqual(archive.days.count, 1)

        let suiteName = "atria.stress.awakebaseline.test.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        archive.save(defaults: suite)
        let reloaded = AtriaAwakeBaselineArchive.load(defaults: suite)
        XCTAssertEqual(reloaded, archive, "archive must survive a persistence round-trip")
    }

    // Integration: admitted quiet-awake samples fed through the live store must
    // flow into the slow baseline, and the exposed center must match the pure
    // archive's median-of-daily-medians.
    @MainActor
    func testStoreAccumulatesSlowAwakeBaselineFromAdmittedSamples() throws {
        let suiteName = "atria.stress.awakebaseline.store.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }

        let baseline = makeBaseline(restingMean: 60, restingSD: 4, hrvSampleDays: 0)
        let store = AtriaStressMonitorStore(defaults: suite)

        XCTAssertNil(store.slowAwakeBaselineCenter(), "no center before any days accumulate")

        // 72 bpm is admitted for rest 60 (above rest+8, below rest+40, zone 0).
        // Three feeding-days spaced a full day apart. The store records with the
        // CURRENT calendar (not injectable), so a feeding-day could straddle
        // local midnight; 70 samples guarantees at least one calendar-day per
        // feeding-day clears the per-day sample floor regardless of the split.
        for dayOffset in 0..<3 {
            let dayBase = now.addingTimeInterval(Double(dayOffset) * 86_400)
            for i in 0..<70 {
                store.update(heartRate: 72,
                             hasContact: true,
                             recentRRSamples: [],
                             isRecording: false,
                             zoneIndex: 0,
                             hrvSnapshot: nil,
                             baseline: baseline,
                             restingMaxHR: restingMaxHR,
                             hasActiveSleepEvidence: false,
                             now: dayBase.addingTimeInterval(Double(i) * 60))
            }
        }

        XCTAssertGreaterThanOrEqual(store.slowAwakeBaselineQualifyingDayCount, 3)
        XCTAssertEqual(try XCTUnwrap(store.slowAwakeBaselineCenter()), 72, accuracy: 0.001,
                       "every admitted sample is 72, so the median of daily medians is 72")
    }

    // MARK: Suppression

    func testSuppressedWhileRecording() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 150,
                                             hrWindow: [150],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: true,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .active)
        XCTAssertNil(state.level)
        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(
            presentation.value,
            AtriaCompactMetricPresentation.noValue
        )
        XCTAssertEqual(presentation.detail, "Paused during activity")
        XCTAssertTrue(presentation.narrative.contains("pauses during activity"))
    }

    func testSuppressedAtZoneTwoOrAbove() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 130,
                                             hrWindow: [130],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 2,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .active)
        XCTAssertNil(state.level)
    }

    func testSuppressedInSleepWindow() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 58,
                                             hrWindow: [58],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: true,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .asleep)
        XCTAssertNil(state.level)
    }

    func testNoSignalWhenContactLost() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 0,
                                             hrWindow: [],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: nil,
                                             inSleepWindow: false,
                                             hasContact: false,
                                             contactAgeSeconds: 0,
                                             now: now)

        XCTAssertEqual(state.kind, .noSignal)
        XCTAssertNil(state.level)
        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(
            presentation.value,
            AtriaCompactMetricPresentation.noValue
        )
        XCTAssertEqual(presentation.detail, "Waiting for a fresh strap signal")
    }

    func testImmatureBaselinePresentationNeverLeaksNumericStress() {
        let baseline = makeBaseline(restingMean: 60,
                                    restingSD: 4,
                                    dayCount: PersonalBaseline.trustedMinimumSamples - 1)
        let state = AtriaStressMonitor.score(hrNow: 72,
                                             hrWindow: [72, 72, 72],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        let presentation = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(state.kind, .calibrating)
        XCTAssertEqual(
            presentation.value,
            AtriaCompactMetricPresentation.noValue
        )
        // Migrated 2026-08-05: the scorer's calibrating detail now carries the
        // visible progress count (the card shows detail, not label, so the
        // count was invisible to users watching live HR stream beside "--").
        XCTAssertEqual(presentation.detail, "Baseline 13 of 14 rest days")
        XCTAssertFalse(presentation.value.contains("/3"))
    }

    func testMatureRestPresentationIsIdenticalForEverySurfaceConsumer() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let state = AtriaStressMonitor.score(hrNow: 60,
                                             hrWindow: [60, 60, 60],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        let homeProjection = AtriaStressPresentation.make(state: state)
        let healthProjection = AtriaStressPresentation.make(state: state)
        XCTAssertEqual(homeProjection, healthProjection)
        XCTAssertEqual(homeProjection.value, "Calm")
        XCTAssertEqual(homeProjection.detail, "HR-only")
        // Copy now names the awake reference (2026-08-08 rescoring) rather than
        // "personal baseline", which specifically meant the resting baseline.
        XCTAssertTrue(homeProjection.narrative.contains("awake heart rate"))
    }

    func testWarmingUpDuringFirst120SecondsOfContact() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 30,
                                             now: now)

        XCTAssertEqual(state.kind, .warmingUp)
        XCTAssertNil(state.level)
        XCTAssertEqual(AtriaStressPresentation.make(state: state).detail,
                       "2 min of live signal")
    }

    // MARK: Honesty gating

    func testCalibratingWhenRestingBaselineNotYetTrusted() {
        let baseline = PersonalBaseline() // no samples at all

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .calibrating)
        XCTAssertNil(state.level)
        XCTAssertEqual(state.label, "Calibrating (0/14)")
    }

    func testCalibratingProgressReflectsFreshRestingSampleCount() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4, dayCount: 5)

        let state = AtriaStressMonitor.score(hrNow: 62,
                                             hrWindow: [62],
                                             rrWindowMs: [],
                                             hrvFallbackRMSSD: nil,
                                             baseline: baseline,
                                             restingMaxHR: restingMaxHR,
                                             workoutActive: false,
                                             zoneIndex: 0,
                                             inSleepWindow: false,
                                             hasContact: true,
                                             contactAgeSeconds: 300,
                                             now: now)

        XCTAssertEqual(state.kind, .calibrating)
        XCTAssertEqual(state.label, "Calibrating (5/14)")
    }

    func testStressDistributionTypicalRequiresThreeComparableMeasuredDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let monday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                       month: 7,
                                                                       day: 6,
                                                                       hour: 12)))
        var archive = AtriaStressDistributionArchive()

        for dayOffset in [0, 1, 2] {
            let day = try XCTUnwrap(calendar.date(byAdding: .day, value: dayOffset, to: monday))
            for sample in 0..<10 {
                let date = day.addingTimeInterval(TimeInterval(sample * 30))
                XCTAssertTrue(archive.record(level: dayOffset == 1 ? .high : .calm,
                                             at: date,
                                             calendar: calendar))
            }
        }

        let thursday = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: monday))
        XCTAssertTrue(archive.record(level: .medium, at: thursday, calendar: calendar))
        let comparison = try XCTUnwrap(archive.comparison(at: thursday, calendar: calendar))

        XCTAssertEqual(comparison.comparisonDayCount, 3)
        XCTAssertEqual(comparison.today.mediumSamples, 1)
        XCTAssertEqual(comparison.typical?.calmSamples, 20)
        XCTAssertEqual(comparison.typical?.highSamples, 10)
    }

    func testStressDistributionDoesNotCountRestoredDuplicateSample() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026,
                                                                    month: 7,
                                                                    day: 13,
                                                                    hour: 10)))
        var archive = AtriaStressDistributionArchive()

        XCTAssertTrue(archive.record(level: .medium, at: date, calendar: calendar))
        XCTAssertFalse(archive.record(level: .high, at: date, calendar: calendar))
        XCTAssertEqual(archive.comparison(at: date, calendar: calendar)?.today.mediumSamples, 1)
        XCTAssertEqual(archive.comparison(at: date, calendar: calendar)?.today.highSamples, 0)
    }

    // Activity "heart & stress" card (2026-08-04): the store republishes the
    // contact-backed live HR it is already fed. Contract: set on contact,
    // cleared on lost contact, stamp refreshed on steady bpm so freshness
    // gating never hides a delivering strap.
    @MainActor
    func testLiveHeartRatePublishesOnContactAndClearsOnLoss() {
        let baseline = makeBaseline(restingMean: 60, restingSD: 4)
        let store = AtriaStressMonitorStore()

        func tick(atOffset offset: TimeInterval, bpm: Int, hasContact: Bool) {
            store.update(heartRate: bpm,
                         hasContact: hasContact,
                         recentRRSamples: [],
                         isRecording: false,
                         zoneIndex: 0,
                         hrvSnapshot: nil,
                         baseline: baseline,
                         restingMaxHR: restingMaxHR,
                         hasActiveSleepEvidence: false,
                         now: now.addingTimeInterval(offset))
        }

        tick(atOffset: 0, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.bpm, 64)
        XCTAssertEqual(store.liveHeartRate?.at, now)

        // Steady bpm: the stamp refreshes once the old one ages past 30s.
        tick(atOffset: 10, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.at, now, "stamp must not churn under 30s")
        tick(atOffset: 40, bpm: 64, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.at, now.addingTimeInterval(40))

        tick(atOffset: 45, bpm: 71, hasContact: true)
        XCTAssertEqual(store.liveHeartRate?.bpm, 71)

        tick(atOffset: 50, bpm: 0, hasContact: false)
        XCTAssertNil(store.liveHeartRate, "lost contact must clear the readout, not cache it")

        let reading = AtriaStressMonitorStore.LiveHeartRateReading(bpm: 70, at: now)
        XCTAssertTrue(reading.isFresh(now: now.addingTimeInterval(60)))
        XCTAssertFalse(reading.isFresh(now: now.addingTimeInterval(120)))
    }
}
