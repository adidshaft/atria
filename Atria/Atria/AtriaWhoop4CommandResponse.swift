import Foundation

/// Typed Gen4 command-response layout from physical type-24 payloads.
///
/// Wire shape, confirmed on this strap:
/// `[0x24, responseSequence, opcode, echoedRequestSequence, status, body...]`
///
/// Status bytes below are named only from matching-generation fixtures.
/// A missing status, an unmatched echo, or a write submission is not success,
/// and a type-24 echo is not native IMU.
enum AtriaWhoop4CommandResponse {
    static let packetType: UInt8 = 0x24

    /// Observed firmware status byte at payload index 4.
    enum FirmwareStatus: Equatable, Sendable {
        /// `0x01` on GET_DATA_RANGE `0x22` and HISTORICAL_DATA_RESULT `0x17`.
        case accepted
        /// `0x02` on SEND_HISTORICAL `0x16` while a serve is pending.
        case pending
        /// `0x03` on both `69/00` and `69/01` in the 20 Sep 2026 attached trace.
        case unsupported
        case other(UInt8)

        init(byte: UInt8) {
            switch byte {
            case 0x01: self = .accepted
            case 0x02: self = .pending
            case 0x03: self = .unsupported
            default: self = .other(byte)
            }
        }

        var byte: UInt8 {
            switch self {
            case .accepted: return 0x01
            case .pending: return 0x02
            case .unsupported: return 0x03
            case .other(let value): return value
            }
        }

        var rawLabel: String {
            switch self {
            case .accepted: return "accepted"
            case .pending: return "pending"
            case .unsupported: return "unsupported"
            case .other(let value): return String(format: "other_%02x", value)
            }
        }
    }

    /// Distinct attempt states. Submission is never firmware success, and
    /// firmware success is never native samples observed.
    enum AttemptState: String, Equatable, Sendable {
        case writeSubmitted
        case writeCompleted
        case responseReceived
        case firmwareAccepted
        case firmwarePending
        case firmwareUnsupported
        case firmwareOther
        case missingResponse
        case unmatchedResponse
        case nativeSamplesObserved
    }

    struct Parsed: Equatable, Sendable {
        let responseSequence: UInt8
        let opcode: UInt8
        let echoedRequestSequence: UInt8
        let status: FirmwareStatus?
        let body: [UInt8]
        let raw: [UInt8]
    }

    enum ParseResult: Equatable, Sendable {
        case parsed(Parsed)
        case tooShort(actual: Int)
        case unexpectedPacketType(UInt8)
    }

    /// Physical 20 Sep 2026 attached-console fixtures. Status 03 is
    /// unsupported; these do not prove a cleared IMU mux.
    static let historicalIMUUnsupportedFixtures: [[UInt8]] = [
        [0x24, 0xef, 0x69, 0x0a, 0x03, 0x00, 0x00, 0x00],
        [0x24, 0xF0, 0x69, 0x0b, 0x03, 0x00, 0x00, 0x00],
        [0x24, 0xf1, 0x69, 0x0c, 0x03, 0x00, 0x00, 0x00],
        [0x24, 0x1f, 0x69, 0x1b, 0x03, 0x00, 0x00, 0x00],
    ]

    /// Physical 20 Sep 2026 14:12 IST: one 6A/01 seq 0 → type 24 echo seq 0,
    /// status `0x00` (not accepted/pending/unsupported). No native 0x33 followed.
    static let toggleIMUModeOther00Fixture: [UInt8] = [
        0x24, 0x97, 0x6A, 0x00, 0x00, 0x01, 0x00, 0x00,
    ]

    static func parse(_ bytes: [UInt8]) -> ParseResult {
        guard bytes.count >= 4 else { return .tooShort(actual: bytes.count) }
        guard bytes[0] == packetType else {
            return .unexpectedPacketType(bytes[0])
        }
        let status: FirmwareStatus?
        let body: [UInt8]
        if bytes.count >= 5 {
            status = FirmwareStatus(byte: bytes[4])
            body = Array(bytes.dropFirst(5))
        } else {
            status = nil
            body = []
        }
        return .parsed(
            Parsed(
                responseSequence: bytes[1],
                opcode: bytes[2],
                echoedRequestSequence: bytes[3],
                status: status,
                body: body,
                raw: bytes
            )
        )
    }

    static func parsePayload(_ bytes: [UInt8]) -> Parsed? {
        if case .parsed(let parsed) = parse(bytes) { return parsed }
        return nil
    }

    /// Correlate a response with the last submitted request sequence and
    /// opcode. Absence of a response is missing, not failure-status.
    static func correlate(
        submittedOpcode: UInt8,
        submittedSequence: UInt8,
        response: Parsed?
    ) -> AttemptState {
        guard let response else { return .missingResponse }
        guard response.opcode == submittedOpcode,
              response.echoedRequestSequence == submittedSequence else {
            return .unmatchedResponse
        }
        guard let status = response.status else { return .responseReceived }
        switch status {
        case .accepted: return .firmwareAccepted
        case .pending: return .firmwarePending
        case .unsupported: return .firmwareUnsupported
        case .other: return .firmwareOther
        }
    }

    static func shouldRetryAfter(_ state: AttemptState) -> Bool {
        switch state {
        case .firmwareUnsupported, .firmwareAccepted, .nativeSamplesObserved:
            return false
        case .writeSubmitted, .writeCompleted, .responseReceived,
             .firmwarePending, .firmwareOther, .missingResponse, .unmatchedResponse:
            return false
        }
    }

    /// Bank/stream labels require firmware acceptance plus, for IMU, native
    /// samples. A write submission never arms or stops a mux.
    static func mayMarkHistoricalIMUBankArmed(_ state: AttemptState) -> Bool {
        state == .firmwareAccepted
    }

    static func mayMarkSuccessfulStream(_ state: AttemptState) -> Bool {
        state == .nativeSamplesObserved
    }
}
