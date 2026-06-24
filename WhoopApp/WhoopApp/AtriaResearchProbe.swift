import Foundation

enum AtriaResearchProbe {
    enum Source: String {
        case metadata = "0x31"
        case historical = "0x2f"
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

        var hasAnyCandidate: Bool {
            !oxygenByteCandidates.isEmpty || !temperatureWordCandidates.isEmpty
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
        return Summary(source: source,
                       payloadLength: payload.count,
                       oxygenByteCandidates: oxygen,
                       temperatureWordCandidates: temperature)
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
}
