import Foundation

enum AtriaResearchProbe {
    enum Source: String {
        case metadata = "0x31"
        case historical = "0x2f"
        case diagnostic = "61080007"
    }

    enum ModelGeneration: String, Equatable {
        case unknown
        case strap3
        case strap4
        case strap5
        case strapMG
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

        var hasAnyCandidate: Bool {
            !oxygenByteCandidates.isEmpty || !temperatureWordCandidates.isEmpty || modelGeneration != .unknown
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

    static func analyze(payload: [UInt8], source: Source) -> Summary {
        let oxygen = oxygenCandidates(in: payload)
        let temperature = temperatureCandidates(in: payload)
        let model = modelGeneration(in: payload)
        return Summary(source: source,
                       payloadLength: payload.count,
                       oxygenByteCandidates: oxygen,
                       temperatureWordCandidates: temperature,
                       modelGeneration: model.generation,
                       modelEvidence: model.evidence)
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
