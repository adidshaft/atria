import XCTest
@testable import Atria

final class AtriaResearchProbeGenerationGateTests: XCTestCase {
    func testV24HistoricalRecordExposesFixedRawOffsetHypotheses() {
        var payload = Array(repeating: UInt8(0), count: 84)
        payload[0] = 0x2f
        payload[1] = 24
        payload[64] = 0x50
        payload[65] = 0x46 // raw u16 at offset 64 = 18,000
        payload[66] = 0x68
        payload[67] = 0x42 // raw u16 at offset 66 = 17,000
        payload[68] = 0x3a
        payload[69] = 0x03 // raw u16 at offset 68 = 826
        payload[75] = 96 // must not be mistaken for a literal SpO2 percentage

        let summary = AtriaResearchProbe.analyze(payload: payload, source: .historical)

        XCTAssertEqual(summary.oxygenByteCandidates,
                       [.init(offset: 64, value: 18_000),
                        .init(offset: 66, value: 17_000)])
        XCTAssertEqual(summary.temperatureWordCandidates,
                       [.init(offset: 68, value: 826)])
        XCTAssertFalse(AtriaResearchProbe.validatedSpO2DecoderAvailable)
        XCTAssertFalse(AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)
        XCTAssertNil(AtriaResearchProbe.decodeSkinTemperatureCelsius(
            payload: payload,
            source: .historical,
            modelGeneration: .strap4
        ), "raw offset hypotheses must remain unavailable as Celsius")
    }

    func testCalibratedSkinTemperatureFixtureCarriesTypedDecoderIdentity() throws {
        let decoded = try XCTUnwrap(
            AtriaResearchProbe.DecodedSkinTemperatureCelsius.calibratedFixture(
                celsius: 36.4,
                modelGeneration: .strap4,
                decoderVersion: "whoop4-reference-fixture-v2",
                source: .historical
            )
        )

        XCTAssertEqual(decoded.celsius, 36.4, accuracy: 1e-9)
        XCTAssertEqual(decoded.decoder.modelGeneration, .strap4)
        XCTAssertEqual(decoded.decoder.version, "whoop4-reference-fixture-v2")
        XCTAssertEqual(decoded.decoder.source, .historical)
        XCTAssertEqual(decoded.decoder.calibrationProvenance, .calibratedFixture)
        XCTAssertTrue(decoded.isAggregationEligible)
        XCTAssertNil(AtriaResearchProbe.productionSkinTemperatureDecoder)
    }

    func testUnknownHistoricalVersionDoesNotUseWhoop4FixedOffsets() {
        var payload = Array(repeating: UInt8(0), count: 84)
        payload[0] = 0x2f
        payload[1] = 5
        payload[64] = 0x50
        payload[65] = 0x46
        payload[68] = 0x3a
        payload[69] = 0x03

        let summary = AtriaResearchProbe.analyze(payload: payload, source: .historical)

        XCTAssertTrue(summary.oxygenByteCandidates.isEmpty)
        XCTAssertTrue(summary.temperatureWordCandidates.isEmpty)
    }

    func testAuthoritativeMetadataAllowsSubsequentBinaryCandidateCounting() {
        var gate = AtriaResearchProbe.GenerationGate()
        let metadata = AtriaResearchProbe.analyze(
            payload: [0x31] + Array("WHOOP 5.0".utf8),
            source: .metadata
        )

        XCTAssertFalse(gate.acceptsForCandidateCounting(metadata))
        XCTAssertEqual(gate.authoritativeGeneration, .strap5)

        let historical = AtriaResearchProbe.analyze(
            payload: [0x2f, 0x01, 96, 0x42, 0x0e, 0x00],
            source: .historical
        )
        let diagnostic = AtriaResearchProbe.analyze(
            payload: [0xaa, 0x10, 97, 0x48, 0x0e, 0x01],
            source: .diagnostic
        )

        XCTAssertEqual(historical.modelGeneration, .unknown)
        XCTAssertEqual(diagnostic.modelGeneration, .unknown)
        XCTAssertTrue(gate.acceptsForCandidateCounting(historical))
        XCTAssertTrue(gate.acceptsForCandidateCounting(diagnostic))
    }

    func testUnknownAndHeuristicOnlyMetadataRemainRejected() {
        let binary = AtriaResearchProbe.analyze(
            payload: [0x2f, 0x01, 96, 0x42, 0x0e, 0x00],
            source: .historical
        )
        var unknownGate = AtriaResearchProbe.GenerationGate()
        XCTAssertFalse(unknownGate.acceptsForCandidateCounting(binary))

        var heuristicGate = AtriaResearchProbe.GenerationGate()
        let heuristicMetadata = AtriaResearchProbe.analyze(
            payload: [0x31] + Array("HARVARD".utf8),
            source: .metadata
        )
        XCTAssertFalse(heuristicGate.acceptsForCandidateCounting(heuristicMetadata))
        XCTAssertEqual(heuristicGate.authoritativeGeneration, .unknown)
        XCTAssertFalse(heuristicGate.acceptsForCandidateCounting(binary))
    }

    func testUnsupportedGenerationAndNonMetadataGenerationTextRemainRejected() {
        let binary = AtriaResearchProbe.analyze(
            payload: [0x2f, 0x01, 96, 0x42, 0x0e, 0x00],
            source: .historical
        )
        var unsupportedGate = AtriaResearchProbe.GenerationGate()
        let unsupportedMetadata = AtriaResearchProbe.analyze(
            payload: [0x31] + Array("WHOOP 3.0".utf8),
            source: .metadata
        )
        XCTAssertFalse(unsupportedGate.acceptsForCandidateCounting(unsupportedMetadata))
        XCTAssertEqual(unsupportedGate.authoritativeGeneration, .strap3)
        XCTAssertFalse(unsupportedGate.acceptsForCandidateCounting(binary))

        var binaryTextGate = AtriaResearchProbe.GenerationGate()
        let nonAuthoritativeText = AtriaResearchProbe.analyze(
            payload: [0x2f, 96] + Array("WHOOP 5.0".utf8),
            source: .historical
        )
        XCTAssertFalse(binaryTextGate.acceptsForCandidateCounting(nonAuthoritativeText))
        XCTAssertEqual(binaryTextGate.authoritativeGeneration, .unknown)
    }

    func testSupportedGenerationStillRequiresSensorCandidateAndCannotPromoteMetrics() {
        var gate = AtriaResearchProbe.GenerationGate()
        let metadata = AtriaResearchProbe.analyze(
            payload: [0x31] + Array("WHOOP MG".utf8),
            source: .metadata
        )
        XCTAssertFalse(gate.acceptsForCandidateCounting(metadata))

        let emptyBinary = AtriaResearchProbe.analyze(
            payload: [0x2f, 0x01, 0x02, 0x03],
            source: .historical
        )
        XCTAssertFalse(gate.acceptsForCandidateCounting(emptyBinary))
        XCTAssertFalse(AtriaResearchProbe.validatedSpO2DecoderAvailable)
        XCTAssertFalse(AtriaResearchProbe.validatedSkinTemperatureDecoderAvailable)
    }
}
