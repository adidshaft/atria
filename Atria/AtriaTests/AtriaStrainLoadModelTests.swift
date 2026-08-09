import XCTest
@testable import Atria

final class AtriaStrainLoadModelTests: XCTestCase {
    private typealias Model = AtriaStrainLoadModel

    private func configuration(rest: Double = 60,
                               max: Double = 190,
                               multiplier: Double = 0.64,
                               coefficient: Double = 1.92,
                               mode: Model.Mode = .workout,
                               maximumGap: TimeInterval = 15) -> Model.Configuration {
        Model.Configuration(restingBPM: rest,
                            maximumBPM: max,
                            intensityMultiplier: multiplier,
                            intensityCoefficient: coefficient,
                            mode: mode,
                            maximumGap: maximumGap)
    }

    private func constantSamples(bpm: Double,
                                 seconds: Int,
                                 spacing: Int = 1) -> [Model.Sample] {
        stride(from: 0, through: seconds, by: spacing).map {
            Model.Sample(timestamp: Double($0), bpm: bpm)
        }
    }

    func testLoadScalesLinearlyWithObservedDuration() {
        let config = configuration()
        let tenMinutes = Model.calculate(constantSamples(bpm: 145, seconds: 600),
                                         configuration: config)
        let twentyMinutes = Model.calculate(constantSamples(bpm: 145, seconds: 1_200),
                                            configuration: config)

        XCTAssertGreaterThan(tenMinutes.load, 0)
        XCTAssertEqual(twentyMinutes.load, tenMinutes.load * 2, accuracy: 1e-9)
        XCTAssertEqual(tenMinutes.acceptedDuration, 600, accuracy: 1e-9)
        XCTAssertEqual(twentyMinutes.acceptedDuration, 1_200, accuracy: 1e-9)
    }

    func testHigherIntensityProducesMoreLoadForTheSameDuration() {
        let config = configuration()
        let easy = Model.calculate(constantSamples(bpm: 110, seconds: 600),
                                   configuration: config).load
        let hard = Model.calculate(constantSamples(bpm: 165, seconds: 600),
                                   configuration: config).load

        XCTAssertGreaterThan(easy, 0)
        XCTAssertGreaterThan(hard, easy)
    }

    func testHeartRateReservePersonalizesForRestAndMaximumHeartRate() {
        let samples = constantSamples(bpm: 135, seconds: 600)
        let lowerMaximum = Model.calculate(samples,
                                           configuration: configuration(rest: 60, max: 180)).load
        let higherMaximum = Model.calculate(samples,
                                            configuration: configuration(rest: 60, max: 200)).load
        let lowerResting = Model.calculate(samples,
                                           configuration: configuration(rest: 50, max: 190)).load
        let higherResting = Model.calculate(samples,
                                            configuration: configuration(rest: 70, max: 190)).load

        XCTAssertGreaterThan(lowerMaximum, higherMaximum)
        XCTAssertGreaterThan(lowerResting, higherResting)
    }

    func testInvalidReserveConfigurationFailsClosed() {
        let samples = constantSamples(bpm: 140, seconds: 60)

        XCTAssertEqual(Model.calculate(samples,
                                       configuration: configuration(rest: 190, max: 190)).load, 0)
        XCTAssertEqual(Model.calculate(samples,
                                       configuration: configuration(rest: 195, max: 190)).load, 0)
        XCTAssertEqual(Model.calculate(samples,
                                       configuration: configuration(coefficient: .nan)).load, 0)
        XCTAssertEqual(Model.calculate(samples,
                                       configuration: configuration(multiplier: .nan)).load, 0)
    }

    func testFifteenSecondGapIsIncludedAndLongerGapIsDropped() {
        let config = configuration()
        let boundary = Model.calculate([
            Model.Sample(timestamp: 0, bpm: 130),
            Model.Sample(timestamp: 15, bpm: 130),
        ], configuration: config)
        let gap = Model.calculate([
            Model.Sample(timestamp: 0, bpm: 130),
            Model.Sample(timestamp: 15.001, bpm: 130),
        ], configuration: config)

        XCTAssertGreaterThan(boundary.load, 0)
        XCTAssertEqual(boundary.acceptedDuration, 15, accuracy: 1e-9)
        XCTAssertEqual(gap.load, 0)
        XCTAssertEqual(gap.acceptedDuration, 0)
        XCTAssertEqual(gap.droppedGapDuration, 15.001, accuracy: 1e-9)
    }

    func testInvalidBPMRejectsBothAdjacentPairsWithoutBridging() {
        let config = configuration()
        let cleanTail = Model.calculate([
            Model.Sample(timestamp: 2, bpm: 100),
            Model.Sample(timestamp: 3, bpm: 100),
        ], configuration: config)
        let invalid = Model.calculate([
            Model.Sample(timestamp: 0, bpm: 100),
            Model.Sample(timestamp: 1, bpm: 300),
            Model.Sample(timestamp: 2, bpm: 100),
            Model.Sample(timestamp: 3, bpm: 100),
        ], configuration: config)
        let nonFinite = Model.calculate([
            Model.Sample(timestamp: 0, bpm: 100),
            Model.Sample(timestamp: 1, bpm: .nan),
            Model.Sample(timestamp: 2, bpm: 100),
            Model.Sample(timestamp: 3, bpm: 100),
        ], configuration: config)
        XCTAssertEqual(invalid.load, cleanTail.load, accuracy: 1e-12)
        XCTAssertEqual(nonFinite.load, cleanTail.load, accuracy: 1e-12)
        XCTAssertEqual(invalid.rejectedIntervalCount, 2)
        XCTAssertEqual(nonFinite.rejectedIntervalCount, 2)
    }

    func testQualifiedInRangeTransitionMatchesCompactMeanDurationKernel() {
        let config = configuration()
        let raw = Model.evaluateInterval(
            from: Model.Sample(timestamp: 0, bpm: 100),
            to: Model.Sample(timestamp: 1, bpm: 180),
            configuration: config
        )
        let compact = Model.load(forQualifiedMeanBPM: 140,
                                 duration: 1,
                                 configuration: config)

        XCTAssertTrue(raw.isAccepted,
                      "qualified ingress owns isolated-spike rejection until compact evidence is versioned")
        XCTAssertEqual(raw.load, compact, accuracy: 1e-12)
    }

    func testContinuousDayFloorAndTransparentTransitionDoNotChangeWorkoutLoad() {
        let workout = configuration(rest: 60, max: 160, mode: .workout)
        let day = configuration(rest: 60, max: 160, mode: .continuousDay)

        func load(at bpm: Double, using config: Model.Configuration) -> Double {
            Model.calculate(constantSamples(bpm: bpm, seconds: 60),
                            configuration: config).load
        }

        XCTAssertGreaterThan(load(at: 90, using: workout), 0)
        XCTAssertEqual(load(at: 90, using: day), 0, accuracy: 1e-12)
        XCTAssertEqual(load(at: 95, using: day),
                       load(at: 95, using: workout) * 0.5,
                       accuracy: 1e-12)
        XCTAssertEqual(load(at: 100, using: day),
                       load(at: 100, using: workout),
                       accuracy: 1e-12)
    }

    func testDisplayMappingIsMonotonicFiniteAndBounded() {
        let loads = [0.0, 1, 10, 50, 100, 250, 1_000, 1_000_000]
        let scores = loads.map(Model.displayScore(fromLoad:))

        XCTAssertEqual(scores.first, 0)
        XCTAssertTrue(scores.allSatisfy { (0...21).contains($0) })
        for pair in zip(scores, scores.dropFirst()) {
            XCTAssertLessThan(pair.0, pair.1)
        }
        XCTAssertEqual(Model.displayScore(fromLoad: -1), 0)
        XCTAssertEqual(Model.displayScore(fromLoad: .nan), 0)
        XCTAssertEqual(Model.displayScore(fromLoad: .infinity), 0)
        XCTAssertEqual(Model.displayScore(fromLoad: 65.6037), 7.44, accuracy: 0.02)
    }

    func testCleanWorkoutRetainsExistingBanisterLoadAndDisplayCalibration() {
        let duration = 10.0
        let bpm = 150.0
        let hrr = (bpm - 60) / (190 - 60)
        let expected = (duration / 60) * hrr * 0.64 * exp(1.92 * hrr)
        let actual = Model.calculate([
            Model.Sample(timestamp: 0, bpm: bpm),
            Model.Sample(timestamp: duration, bpm: bpm),
        ], configuration: configuration()).load

        XCTAssertEqual(actual, expected, accuracy: 1e-12)
        XCTAssertEqual(Metrics.trimp([(t: 0, bpm: 150), (t: 10, bpm: 150)],
                                     rest: 60,
                                     max: 190),
                       expected,
                       accuracy: 1e-12)
    }

    func testFemaleWorkoutUsesPublishedMultiplierAndExponent() {
        let duration = 10.0
        let bpm = 150.0
        let hrr = (bpm - 60) / (190 - 60)
        let expected = (duration / 60) * hrr * 0.86 * exp(1.67 * hrr)
        let parameters = AtriaAnalytics.Strain.banisterParameters(for: .female)
        let model = Model.calculate([
            Model.Sample(timestamp: 0, bpm: bpm),
            Model.Sample(timestamp: duration, bpm: bpm),
        ], configuration: configuration(multiplier: parameters.multiplier,
                                        coefficient: parameters.coefficient)).load
        let publicAPI = Metrics.trimp([(t: 0, bpm: 150), (t: 10, bpm: 150)],
                                      rest: 60,
                                      max: 190,
                                      sex: .female)

        XCTAssertEqual(parameters.multiplier, 0.86, accuracy: 1e-12)
        XCTAssertEqual(parameters.coefficient, 1.67, accuracy: 1e-12)
        XCTAssertEqual(model, expected, accuracy: 1e-12)
        XCTAssertEqual(publicAPI, expected, accuracy: 1e-12)
    }

    func testCanonicalCompactDailyStrainRetainsFemaleProfileParity() {
        let seconds = 600.0
        let bpm = 150
        let compact = SessionStore.canonicalHistoricalStrain(
            transitionHalfBPMSeconds: [bpm * 2: seconds],
            rest: 60,
            maxHR: 190,
            biologicalSex: .female
        )
        let rawSamples = stride(from: 0.0, through: seconds, by: 15.0).map {
            (t: $0, bpm: bpm)
        }
        let rawLoad = AtriaAnalytics.Strain.dailyTRIMP(
            rawSamples,
            rest: 60,
            max: 190,
            sex: .female
        )
        let unspecified = SessionStore.canonicalHistoricalStrain(
            transitionHalfBPMSeconds: [bpm * 2: seconds],
            rest: 60,
            maxHR: 190,
            biologicalSex: .unspecified
        )

        XCTAssertEqual(compact, Metrics.strain(fromTRIMP: rawLoad), accuracy: 1e-12)
        XCTAssertGreaterThan(compact, unspecified,
                             "canonical history must not silently fall back to male parameters")
    }

    func testIncrementalAndBatchCalculationAreExactlyEquivalent() {
        let samples = [
            Model.Sample(timestamp: 0, bpm: 100),
            Model.Sample(timestamp: 1, bpm: 101),
            Model.Sample(timestamp: 2, bpm: 180), // accepted in-range transition
            Model.Sample(timestamp: 3, bpm: 102),
            Model.Sample(timestamp: 4, bpm: 103),
            Model.Sample(timestamp: 20, bpm: 120), // telemetry gap
            Model.Sample(timestamp: 21, bpm: .nan),
            Model.Sample(timestamp: 22, bpm: 121),
            Model.Sample(timestamp: 23, bpm: 122),
        ]
        let config = configuration()
        let batch = Model.calculate(samples, configuration: config)
        var incremental = Model.Accumulator(configuration: config)

        incremental.append(contentsOf: samples.prefix(3))
        incremental.append(contentsOf: samples.dropFirst(3).prefix(2))
        incremental.append(contentsOf: samples.dropFirst(5))

        XCTAssertEqual(incremental.result, batch)
    }
}
