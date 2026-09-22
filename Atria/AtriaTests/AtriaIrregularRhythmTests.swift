import XCTest
@testable import Atria

final class AtriaIrregularRhythmTests: XCTestCase {
    func testEmptyWindowFailsClosed() {
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: [], now: Date())
        XCTAssertEqual(result.outcome, .insufficientEvidence)
        XCTAssertEqual(result.headline, AtriaCompactMetricPresentation.noValue)
        XCTAssertEqual(result.detail, AtriaIrregularRhythmCopy.cannotDiagnose)
        XCTAssertFalse(result.caution.localizedCaseInsensitiveContains("diagnosed with AFib"))
    }

    func testRegularRestPulseIsNotAFlag() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = makeWindow(endingAt: now, milliseconds: { _ in 800 })
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: samples, now: now)
        XCTAssertEqual(result.outcome, .insufficientEvidence)
    }

    func testSinusoidalBreathingVariationFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = makeWindow(endingAt: now) { index in
            800 + 40 * sin(Double(index) * 0.35)
        }
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: samples, now: now)
        XCTAssertEqual(result.outcome, .insufficientEvidence)
    }

    func testMissingProvenanceFailsClosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let samples = makeWindow(endingAt: now, milliseconds: { _ in 800 }, source: nil)
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: samples, now: now)
        XCTAssertEqual(result.outcome, .insufficientEvidence)
        XCTAssertEqual(result.reason, "provenance")
    }

    func testOneHertzHeartRateSamplesAreNotTreatedAsECG() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var samples: [AtriaIrregularRhythmAssessment.Interval] = []
        for index in 0..<300 {
            samples.append(
                AtriaIrregularRhythmAssessment.Interval(
                    date: now.addingTimeInterval(Double(index - 299)),
                    milliseconds: 60_000 / 75,
                    source: .standardHeartRateMeasurement2A37
                )
            )
        }
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: samples, now: now)
        XCTAssertEqual(result.outcome, .insufficientEvidence)
    }

    func testDenseIrregularSuccessiveDifferencesCanSurfaceSigns() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var generator = SplitMix64(seed: 42)
        let samples = makeWindow(endingAt: now) { _ in
            generator.nextInRange(520...1_050)
        }
        let result = AtriaIrregularRhythmAssessment.evaluate(intervals: samples, now: now)
        XCTAssertEqual(result.outcome, .irregularRhythmSigns)
        XCTAssertEqual(result.headline, "Signs")
        XCTAssertTrue(result.caution.contains("not a diagnosis"))
        XCTAssertFalse(result.caution.localizedCaseInsensitiveContains("diagnosed with AFib"))
        XCTAssertFalse(result.caution.localizedCaseInsensitiveContains("ECG"))
    }

    func testCopyConstantsStayEducational() {
        XCTAssertEqual(AtriaIrregularRhythmCopy.cannotDiagnose,
                       "Atria cannot diagnose AFib from this strap.")
        XCTAssertTrue(AtriaIrregularRhythmCopy.notECG.contains("not an ECG"))
        XCTAssertFalse(AtriaIrregularRhythmCopy.watchLikeCaution.contains("you have AFib"))
        XCTAssertFalse(AtriaEvidenceCatalog.sources(for: "irregularRhythm").isEmpty)
    }

    func testPhysicianNoteRoundTrip() {
        let defaults = UserDefaults(suiteName: "atria.irregularRhythm.tests")!
        defaults.removePersistentDomain(forName: "atria.irregularRhythm.tests")
        XCTAssertNil(AtriaIrregularRhythmNoteStore.physicianNotedAt(defaults: defaults))
        let stamped = Date(timeIntervalSince1970: 1_800_000_100)
        AtriaIrregularRhythmNoteStore.markPhysicianNoted(at: stamped, defaults: defaults)
        XCTAssertEqual(AtriaIrregularRhythmNoteStore.physicianNotedAt(defaults: defaults)?.timeIntervalSince1970,
                       stamped.timeIntervalSince1970)
        AtriaIrregularRhythmNoteStore.clearPhysicianNote(defaults: defaults)
        XCTAssertNil(AtriaIrregularRhythmNoteStore.physicianNotedAt(defaults: defaults))
    }

    private func makeWindow(
        endingAt now: Date,
        milliseconds: (Int) -> Double,
        source: AtriaRRSourceProvenance? = .standardHeartRateMeasurement2A37
    ) -> [AtriaIrregularRhythmAssessment.Interval] {
        var samples: [AtriaIrregularRhythmAssessment.Interval] = []
        var cursor = now.addingTimeInterval(-300)
        var index = 0
        while cursor <= now {
            let ms = milliseconds(index)
            cursor = cursor.addingTimeInterval(ms / 1_000)
            if cursor > now { break }
            samples.append(
                AtriaIrregularRhythmAssessment.Interval(
                    date: cursor,
                    milliseconds: ms,
                    source: source
                )
            )
            index += 1
        }
        return samples
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextInRange(_ range: ClosedRange<Double>) -> Double {
        let unit = Double(next() % 10_000) / 10_000
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
