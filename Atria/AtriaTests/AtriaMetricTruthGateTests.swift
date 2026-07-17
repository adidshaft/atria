import XCTest
@testable import Atria

final class AtriaMetricTruthGateTests: XCTestCase {
    func testUnvalidatedSkinTemperatureCandidateNeverBecomesAHealthReading() {
        let unvalidatedCandidate = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: 1.7,
            baselineSessions: 5,
            candidateFrames: 84,
            candidateValues: 12
        )

        let projected = SessionStore.skinTemperatureDeviationSummary(
            finalizedDeviationCelsius: 0.4,
            fallback: unvalidatedCandidate,
            validatedSource: false
        )

        XCTAssertNil(projected.latestDeltaCelsius)
        XCTAssertFalse(projected.isReady)
        XCTAssertEqual(projected.valueText, "--")
        XCTAssertEqual(projected.baselineSessions, 0)
        XCTAssertEqual(projected.candidateFrames, 84)
        XCTAssertEqual(projected.candidateValues, 12)
        XCTAssertNil(Metrics.skinTemperatureDeviationZone(projected,
                                                          decoderAvailable: false))
    }

    func testValidatedSkinTemperatureUsesOnlyFinalizedDeviation() {
        let candidate = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: 1.7,
            baselineSessions: 2,
            candidateFrames: 84,
            candidateValues: 12
        )

        let projected = SessionStore.skinTemperatureDeviationSummary(
            finalizedDeviationCelsius: 0.4,
            fallback: candidate,
            validatedSource: true
        )

        XCTAssertEqual(projected.latestDeltaCelsius, 0.4)
        XCTAssertTrue(projected.isReady)
        XCTAssertGreaterThanOrEqual(projected.baselineSessions, 3)
        XCTAssertEqual(projected.candidateFrames, 84)
        XCTAssertEqual(projected.candidateValues, 12)
    }
}
