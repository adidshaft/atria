import XCTest
@testable import Atria

final class AtriaExperimentalSensorCopyTests: XCTestCase {
    func testBloodOxygenStatusDistinguishesSupportedAndUnsupportedHardware() {
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap4,
            decoderAvailable: false),
            "Not available yet")
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap3,
            decoderAvailable: false),
            "Not available on this strap")
    }

    func testUnknownBloodOxygenHardwareDoesNotClaimUnsupported() {
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .unknown,
            decoderAvailable: false),
            "Not available yet")
    }

    func testAvailableBloodOxygenDecoderDoesNotUseLabValidationLanguage() {
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap4,
            decoderAvailable: true),
            "No SpO2 reading yet")
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenFootnote(
            strapModel: .strap4,
            decoderAvailable: true),
            "No SpO2 reading yet.")
        XCTAssertFalse(AtriaExperimentalSensorCopy.bloodOxygenDetail(
            strapModel: .strap4,
            decoderAvailable: true,
            candidateFrames: 0).localizedCaseInsensitiveContains("validated"))
    }

    func testSkinTemperatureCopyShowsUnavailableBeforeBaseline() {
        let summary = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: nil,
            baselineSessions: 2,
            candidateFrames: 40,
            candidateValues: 4)

        XCTAssertEqual(AtriaExperimentalSensorCopy.skinTemperatureStatus(
            summary: summary,
            decoderAvailable: false),
            "Decoder not verified")
        XCTAssertEqual(AtriaExperimentalSensorCopy.skinTemperatureDetail(
            summary: summary,
            decoderAvailable: false),
            "Not available yet. Atria does not show raw sensor data as wrist temperature.")
        XCTAssertFalse(AtriaExperimentalSensorCopy.skinTemperatureDetail(
            summary: summary,
            decoderAvailable: false).contains("building a sleep baseline"))
    }

    func testStaleSkinTemperatureSummaryCannotEscapeDecoderGate() {
        let staleReadySummary = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: 0.7,
            baselineSessions: 7,
            candidateFrames: 80,
            candidateValues: 8)

        XCTAssertFalse(AtriaExperimentalSensorCopy.hasValidatedSkinTemperatureReading(
            summary: staleReadySummary,
            decoderAvailable: false))
        XCTAssertEqual(AtriaExperimentalSensorCopy.skinTemperatureValue(
            summary: staleReadySummary,
            decoderAvailable: false), "--")
        XCTAssertFalse(AtriaExperimentalSensorCopy.skinTemperatureAccessibilityDetail(
            summary: staleReadySummary,
            decoderAvailable: false).contains("+0.7"))
        XCTAssertNil(Metrics.skinTemperatureDeviationZone(
            staleReadySummary,
            decoderAvailable: false))
    }

    func testValidatedSkinTemperatureSummaryMayBePresented() {
        let summary = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: -0.3,
            baselineSessions: 7,
            candidateFrames: 80,
            candidateValues: 8)

        XCTAssertTrue(AtriaExperimentalSensorCopy.hasValidatedSkinTemperatureReading(
            summary: summary,
            decoderAvailable: true))
        XCTAssertEqual(AtriaExperimentalSensorCopy.skinTemperatureValue(
            summary: summary,
            decoderAvailable: true), "-0.3")
        XCTAssertNotNil(Metrics.skinTemperatureDeviationZone(
            summary,
            decoderAvailable: true))
    }
}
