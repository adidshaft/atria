import Foundation

enum AtriaResearchProbe {
    // SpO2 candidate offsets are discovery evidence only. This stays false
    // until a generation-specific layout passes an external reference maneuver.
    static let validatedSpO2DecoderAvailable = false
    static var validatedSkinTemperatureDecoderAvailable: Bool {
        productionSkinTemperatureDecoder != nil
    }

    enum Source: String, Codable, Sendable {
        case metadata = "0x31"
        case historical = "0x2f"
        case diagnostic = "61080007"
    }

    enum ModelGeneration: String, Codable, Equatable, Sendable {
        case unknown
        case strap3
        case strap4
        case strap5
        case strapMG
    }

    enum SkinTemperatureCalibrationProvenance: String, Codable, Equatable, Sendable {
        /// Reserved for a decoder calibrated and checked against an external
        /// temperature reference on its declared strap generation.
        case externalReferenceValidated = "external_reference_validated"
        /// WHOOP 4 v12/v24 raw ADC position and wear response are independently
        /// reproduced, but the absolute transfer function is not public.
        /// Production may use this only for deviation from the same strap's own
        /// learned nightly baseline, never as an absolute thermometer.
        case sameDeviceRelativeValidated = "same_device_relative_validated"
        /// Test-only evidence supplied after conversion, never derived from a
        /// raw candidate word inside production aggregation.
        case calibratedFixture = "calibrated_fixture"
    }

    struct SkinTemperatureDecoderIdentity: Codable, Equatable, Sendable {
        let modelGeneration: ModelGeneration
        let version: String
        let source: Source
        let calibrationProvenance: SkinTemperatureCalibrationProvenance

        init?(modelGeneration: ModelGeneration,
              version: String,
              source: Source,
              calibrationProvenance: SkinTemperatureCalibrationProvenance) {
            let normalizedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
            guard modelGeneration != .unknown, !normalizedVersion.isEmpty else { return nil }
            self.modelGeneration = modelGeneration
            self.version = normalizedVersion
            self.source = source
            self.calibrationProvenance = calibrationProvenance
        }
    }

    /// A unit-safe value that has already passed a generation-specific,
    /// versioned conversion. Raw research candidates cannot initialize this
    /// type without explicitly supplying calibrated Celsius and provenance.
    struct DecodedSkinTemperatureCelsius: Codable, Equatable, Sendable {
        let celsius: Double
        let decoder: SkinTemperatureDecoderIdentity

        var isAggregationEligible: Bool {
            guard celsius.isFinite,
                  decoder.modelGeneration != .unknown,
                  !decoder.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            switch decoder.calibrationProvenance {
            case .externalReferenceValidated, .sameDeviceRelativeValidated:
                // A decodable identity stored on disk is not proof by itself.
                // Production aggregation requires the exact decoder identity
                // compiled into this build after external-reference validation.
                return decoder == AtriaResearchProbe.productionSkinTemperatureDecoder
            case .calibratedFixture:
#if DEBUG
                // Algorithm tests use already-converted values; Release builds
                // must never aggregate this test-only provenance.
                return true
#else
                return false
#endif
            }
        }

        init?(celsius: Double, decoder: SkinTemperatureDecoderIdentity) {
            guard celsius.isFinite else { return nil }
            self.celsius = celsius
            self.decoder = decoder
        }

        static func calibratedFixture(celsius: Double,
                                      modelGeneration: ModelGeneration = .strap4,
                                      decoderVersion: String = "calibrated-fixture-v1",
                                      source: Source = .historical) -> Self? {
            guard let decoder = SkinTemperatureDecoderIdentity(
                modelGeneration: modelGeneration,
                version: decoderVersion,
                source: source,
                calibrationProvenance: .calibratedFixture
            ) else { return nil }
            return Self(celsius: celsius, decoder: decoder)
        }
    }

    /// WHOOP 4 v12/v24 payload-relative offset 68 is the raw skin-temperature
    /// ADC (frame-absolute offset 72). Its per-device offset is removed by a
    /// same-device median anchor; downstream code publishes only deviation from
    /// the same strap's sleep baseline.
    static let productionSkinTemperatureDecoder = SkinTemperatureDecoderIdentity(
        modelGeneration: .strap4,
        version: "whoop4-v24-relative-adc-v1",
        source: .historical,
        calibrationProvenance: .sameDeviceRelativeValidated
    )

    static let whoop4SkinTemperatureRawOffset = 68
    static let whoop4SkinTemperatureWornRawRange = 550...2040
    static let whoop4SkinTemperatureMinimumAnchorSamples = 100
    static let whoop4SkinTemperatureAnchorCelsius = 33.0
    static let whoop4SkinTemperatureRelativeSlopeCelsiusPerRaw = 0.05

    static func decodeSkinTemperatureCelsius(payload: [UInt8],
                                             source: Source,
                                             modelGeneration: ModelGeneration,
                                             sameDeviceAnchorRaw: Double?)
        -> DecodedSkinTemperatureCelsius? {
        guard source == .historical,
              modelGeneration == .strap4,
              payload.count > whoop4SkinTemperatureRawOffset + 1,
              payload[0] == 0x2f,
              payload[1] == 12 || payload[1] == 24,
              let sameDeviceAnchorRaw,
              sameDeviceAnchorRaw.isFinite else { return nil }
        let raw = u16LE(payload, offset: whoop4SkinTemperatureRawOffset)
        return decodeWhoop4SkinTemperatureRaw(
            raw,
            sameDeviceAnchorRaw: sameDeviceAnchorRaw
        )
    }

    static func decodeWhoop4SkinTemperatureRaw(
        _ raw: Int,
        sameDeviceAnchorRaw: Double
    ) -> DecodedSkinTemperatureCelsius? {
        guard let decoder = productionSkinTemperatureDecoder,
              whoop4SkinTemperatureWornRawRange.contains(raw),
              sameDeviceAnchorRaw.isFinite else { return nil }
        let celsius = whoop4SkinTemperatureAnchorCelsius
            + (Double(raw) - sameDeviceAnchorRaw)
                * whoop4SkinTemperatureRelativeSlopeCelsiusPerRaw
        // This gate rejects doff/saturation transients after per-device
        // centering. It does not certify an absolute temperature.
        guard (28...42).contains(celsius) else { return nil }
        return DecodedSkinTemperatureCelsius(celsius: celsius, decoder: decoder)
    }

    static func whoop4SkinTemperatureAnchorRaw(_ rawValues: [Int]) -> Double? {
        let sorted = rawValues
            .filter(whoop4SkinTemperatureWornRawRange.contains)
            .sorted()
        guard sorted.count >= whoop4SkinTemperatureMinimumAnchorSamples else { return nil }
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Double(sorted[middle - 1] + sorted[middle]) / 2
        }
        return Double(sorted[middle])
    }

    struct Candidate: Equatable {
        let offset: Int
        let value: Int
    }

    struct Summary: Equatable {
        let source: Source
        let payloadLength: Int
        let oxygenByteCandidates: [Candidate]
        let temperatureWordCandidates: [Candidate]
        let modelGeneration: ModelGeneration
        let modelEvidence: String
        let layoutHead: String

        var hasAnyCandidate: Bool {
            !oxygenByteCandidates.isEmpty || !temperatureWordCandidates.isEmpty || modelGeneration != .unknown
        }

        var hasExplicitGeneration: Bool {
            modelGeneration != .unknown
        }

        var hasSensorCandidate: Bool {
            !oxygenByteCandidates.isEmpty || !temperatureWordCandidates.isEmpty
        }

        func allowsGenerationSpecificDecode(strapAllowsGenerationSpecificDecode: Bool) -> Bool {
            hasExplicitGeneration && strapAllowsGenerationSpecificDecode
        }

        var oxygenOffsetSummary: String {
            Self.offsetSummary(oxygenByteCandidates)
        }

        var temperatureOffsetSummary: String {
            Self.offsetSummary(temperatureWordCandidates)
        }

        private static func offsetSummary(_ candidates: [Candidate]) -> String {
            guard !candidates.isEmpty else { return "none" }
            return candidates
                .prefix(12)
                .map { "\($0.offset):\($0.value)" }
                .joined(separator: ",")
        }
    }

    struct GenerationGate {
        private(set) var authoritativeGeneration: ModelGeneration = .unknown

        mutating func acceptsForCandidateCounting(_ summary: Summary) -> Bool {
            if summary.source == .metadata {
                if summary.hasExplicitGeneration {
                    authoritativeGeneration = summary.modelGeneration
                }
                return false
            }

            guard summary.hasSensorCandidate else { return false }
            switch authoritativeGeneration {
            case .strap4, .strap5, .strapMG:
                return true
            case .unknown, .strap3:
                return false
            }
        }
    }

    static func analyze(payload: [UInt8], source: Source) -> Summary {
        let fixedHistoricalOffsets = source == .historical
            ? historicalFixedOffsetCandidates(in: payload)
            : nil
        let oxygen = fixedHistoricalOffsets?.oxygenHypotheses ?? oxygenCandidates(in: payload)
        let temperature = fixedHistoricalOffsets?.temperatureHypotheses ?? temperatureCandidates(in: payload)
        let model = modelGeneration(in: payload)
        return Summary(source: source,
                       payloadLength: payload.count,
                       oxygenByteCandidates: oxygen,
                       temperatureWordCandidates: temperature,
                       modelGeneration: model.generation,
                       modelEvidence: model.evidence,
                       layoutHead: payload.prefix(12).map { String(format: "%02x", $0) }.joined())
    }

    /// Historical records v12/v24 have changing u16 words at fixed offsets.
    /// Their sensor meaning and generation ownership are not established. Keep
    /// them as replay hypotheses only: they are not red/IR proof, an SpO2
    /// percentage, a temperature register, or a Celsius conversion.
    private static func historicalFixedOffsetCandidates(
        in payload: [UInt8]
    ) -> (oxygenHypotheses: [Candidate], temperatureHypotheses: [Candidate])? {
        let supportedVersions: Set<UInt8> = [12, 24]
        guard payload.count >= 70,
              payload[0] == 0x2f,
              supportedVersions.contains(payload[1]) else { return nil }

        let raw64 = u16LE(payload, offset: 64)
        let raw66 = u16LE(payload, offset: 66)
        let raw68 = u16LE(payload, offset: 68)
        let oxygenHypotheses: [Candidate] = [(64, raw64), (66, raw66)].compactMap { pair in
            let (offset, value) = pair
            guard value > 0, value < Int(UInt16.max) else { return nil as Candidate? }
            return Candidate(offset: offset, value: value)
        }
        let temperatureHypotheses = (raw68 > 0 && raw68 < Int(UInt16.max))
            ? [Candidate(offset: 68, value: raw68)]
            : []
        return (oxygenHypotheses, temperatureHypotheses)
    }

    private static func u16LE(_ payload: [UInt8], offset: Int) -> Int {
        Int(UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8))
    }

    private static func oxygenCandidates(in payload: [UInt8]) -> [Candidate] {
        payload.enumerated().compactMap { offset, byte in
            let value = Int(byte)
            guard (90...100).contains(value) else { return nil }
            return Candidate(offset: offset, value: value)
        }
    }

    private static func temperatureCandidates(in payload: [UInt8]) -> [Candidate] {
        guard payload.count >= 2 else { return [] }
        var candidates: [Candidate] = []
        for offset in 0..<(payload.count - 1) {
            let value = Int(UInt16(payload[offset]) | (UInt16(payload[offset + 1]) << 8))
            guard (2_500...4_200).contains(value) else { continue }
            candidates.append(Candidate(offset: offset, value: value))
        }
        return candidates
    }

    private static func modelGeneration(in payload: [UInt8]) -> (generation: ModelGeneration, evidence: String) {
        let runs = printableRuns(in: payload)
        let redactedRuns = runs.map(redactIdentifierLikeTokens)
        for run in redactedRuns {
            let normalized = run
                .uppercased()
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: ".", with: " ")
            if normalized.contains("WHOOP MG") || normalized.contains("WHOOPMG") || normalized.contains(" MG") {
                return (.strapMG, run)
            }
            if normalized.contains("WHOOP 5") || normalized.contains("WHOOP5") {
                return (.strap5, run)
            }
            if normalized.contains("WHOOP 4") || normalized.contains("WHOOP4") {
                return (.strap4, run)
            }
            if normalized.contains("WHOOP 3") || normalized.contains("WHOOP3") {
                return (.strap3, run)
            }
        }
        // Community firmware codenames corroborate a generation but are NOT ground
        // truth: log a hint, never assign the model from one. Allowlist only.
        let codenameHints: [(token: String, model: String)] = [("HARVARD", "strap4")]
        for run in redactedRuns {
            let normalized = run.uppercased()
            for hint in codenameHints where normalized.contains(hint.token) {
                AtriaDebugLog("ATRIADBG model_gate status=codename_hint model=%@ evidence=%@",
                              hint.model,
                              hint.token)
            }
        }
        return (.unknown, redactedRuns.prefix(4).joined(separator: "|"))
    }

    private static func printableRuns(in bytes: [UInt8], minimumLength: Int = 4) -> [String] {
        var runs: [String] = []
        var current: [UInt8] = []
        func flush() {
            defer { current.removeAll(keepingCapacity: true) }
            guard current.count >= minimumLength,
                  let string = String(bytes: current, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !string.isEmpty else { return }
            runs.append(string)
        }
        for byte in bytes {
            if byte == 0x0a || byte == 0x0d || (byte >= 0x20 && byte <= 0x7e) {
                current.append(byte)
            } else {
                flush()
            }
        }
        flush()
        return runs
    }

    private static func redactIdentifierLikeTokens(_ value: String) -> String {
        value
            .split(separator: " ")
            .map { token -> String in
                let scalar = token.unicodeScalars
                let letters = scalar.filter { CharacterSet.letters.contains($0) }.count
                let digits = scalar.filter { CharacterSet.decimalDigits.contains($0) }.count
                if token.count >= 8, digits >= 3, letters >= 3 {
                    return "[redacted]"
                }
                return String(token)
            }
            .joined(separator: " ")
    }
}
