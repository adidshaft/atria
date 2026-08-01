import XCTest
@testable import Atria

final class AtriaExperimentalSensorCopyTests: XCTestCase {
    func testBloodOxygenStatusDistinguishesSupportedAndUnsupportedHardware() {
        // strap-4 carries the SpO2 sensor but has no validated decoder yet: this
        // is a genuinely TIME-BASED state, so it keeps its transient wording.
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap4,
            decoderAvailable: false),
            "Not available yet")
        // strap-3 has no SpO2 sensor at all: a true hardware limitation, so it
        // routes through the canonical AtriaSpO2Copy copy (2026-08-01).
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap3,
            decoderAvailable: false),
            AtriaSpO2Copy.notAvailableOnStrap)
    }

    func testBloodOxygenHardwareBranchUsesCanonicalCopyAndNeverAPercentage() {
        // SpO2 copy consolidation (2026-08-01): the strap-3 hardware branch of
        // every factory surface reads from the canonical AtriaSpO2Copy strings so
        // SpO2 tells one honest hardware story -- and never a fabricated percent.
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenStatus(
            strapModel: .strap3, decoderAvailable: false),
            AtriaSpO2Copy.notAvailableOnStrap)
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenFootnote(
            strapModel: .strap3, decoderAvailable: false),
            "\(AtriaSpO2Copy.notAvailableOnStrap) \(AtriaSpO2Copy.wontFakeAPercentage)")
        XCTAssertEqual(AtriaExperimentalSensorCopy.bloodOxygenDetail(
            strapModel: .strap3, decoderAvailable: false, candidateFrames: 0),
            AtriaSpO2Copy.longUnavailable)

        // No blood-oxygen surface -- for any strap or decoder state -- may render
        // a "%", which would imply a fabricated saturation value.
        let models: [AtriaBLEManager.AtriaStrapModel] = [.unknown, .strap3, .strap4, .strap5, .strapMG]
        for model in models {
            for decoder in [true, false] {
                for frames in [0, 5] {
                    for text in [
                        AtriaExperimentalSensorCopy.bloodOxygenStatus(strapModel: model, decoderAvailable: decoder),
                        AtriaExperimentalSensorCopy.bloodOxygenFootnote(strapModel: model, decoderAvailable: decoder),
                        AtriaExperimentalSensorCopy.bloodOxygenDetail(strapModel: model, decoderAvailable: decoder, candidateFrames: frames),
                    ] {
                        XCTAssertFalse(text.contains("%"),
                                       "SpO2 factory copy must never render a percentage: \(text)")
                    }
                }
            }
        }
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
            "Not available yet")
        XCTAssertEqual(AtriaExperimentalSensorCopy.skinTemperatureDetail(
            summary: summary,
            decoderAvailable: false),
            "Not available yet. Atria does not show raw sensor data as wrist temperature.")
        XCTAssertFalse(AtriaExperimentalSensorCopy.skinTemperatureDetail(
            summary: summary,
            decoderAvailable: false).contains("building a sleep baseline"))
    }

    func testValidatedSkinTemperatureCopyShowsExactBaselineProgress() {
        let summary = IMUAuditSummary.SkinTemperatureDeviationSummary(
            latestDeltaCelsius: nil,
            baselineSessions: 3,
            candidateFrames: 47_921,
            candidateValues: 0)

        XCTAssertEqual(
            AtriaExperimentalSensorCopy.skinTemperatureStatus(
                summary: summary,
                decoderAvailable: true
            ),
            "3 baseline nights · next sleep unlocks"
        )
        XCTAssertTrue(
            AtriaExperimentalSensorCopy.skinTemperatureAccessibilityDetail(
                summary: summary,
                decoderAvailable: true
            ).contains("3 baseline nights")
        )
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
