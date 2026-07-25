import Foundation

/// Hard safety boundary for the physical WHOOP 4 history transport capture.
/// This mode is evidence-only: it cannot acknowledge, trim, rewind, set clocks,
/// change collection modes, reboot the strap, or publish recovered metrics.
enum AtriaBLEReadOnlyHistoryCapturePolicy {
    enum WriteConfirmationResult: Equatable, Sendable {
        case confirmed
        case securityRequired
        case failed
        case timedOut
        case interrupted
    }

    struct Command: Equatable, Sendable {
        let opcode: UInt8
        let payload: [UInt8]
    }

    static let getDataRange = Command(opcode: 0x22, payload: [0x00])
    static let sendHistorical = Command(opcode: 0x16, payload: [0x00])
    static let abort = Command(opcode: 0x14, payload: [0x00])
    static let exactTrace = [getDataRange, sendHistorical, abort]
    static let postRangeResponseSettle: TimeInterval = 2
    /// iOS may dismiss its pairing sheet before the encrypted ATT link is
    /// actually usable. The physical strap needed several connection events
    /// after that UI transition; a two-second retry raced the bond and returned
    /// Authentication Insufficient immediately. Keep exactly one retry, but
    /// give CoreBluetooth a bounded twelve seconds to finish link encryption.
    static let pairingSettle: TimeInterval = 12
    /// The first protected iOS write physically returned its encryption result
    /// after 29.9 seconds. This isolated bootstrap wait exceeds that observed
    /// bound; production command timeouts remain unchanged.
    static let rangeWriteConfirmationTimeout: TimeInterval = 45
    static let maximumCapturedFrames = 50
    static let captureTimeout: TimeInterval = 20

    static func allows(opcode: UInt8, payload: [UInt8]) -> Bool {
        exactTrace.contains(Command(opcode: opcode, payload: payload))
    }

    /// Only explicit CoreBluetooth security failures authorize the single range
    /// retry. A missing callback, disconnect, or generic failure is deliberately
    /// not treated as evidence that pairing is in progress.
    static func classifyWriteCompletion(
        succeeded: Bool,
        errorDomain: String?,
        errorCode: Int?
    ) -> WriteConfirmationResult {
        if succeeded { return .confirmed }
        guard let errorDomain, let errorCode else { return .failed }
        if errorDomain == "CBATTErrorDomain",
           [0x05, 0x0c, 0x0f].contains(errorCode) {
            return .securityRequired
        }
        if errorDomain == "CBErrorDomain", errorCode == 15 {
            return .securityRequired
        }
        return .failed
    }

    static func permitsRangeRetry(
        after result: WriteConfirmationResult,
        retriesAlreadyIssued: Int
    ) -> Bool {
        result == .securityRequired && retriesAlreadyIssued == 0
    }

    static func shouldIssueAbort(
        serveWriteConfirmed: Bool,
        historyStarted: Bool
    ) -> Bool {
        serveWriteConfirmed || historyStarted
    }

    static func writeConfirmationPollAttempts(
        opcode: UInt8,
        pollInterval: TimeInterval
    ) -> Int {
        guard pollInterval > 0 else { return 1 }
        let timeout = opcode == getDataRange.opcode
            ? rangeWriteConfirmationTimeout
            : AtriaBLEHistoryWriteConfirmationPolicy.timeout
        return max(1, Int(ceil(timeout / pollInterval)))
    }
}

/// Separate command firewall for the single exact-range transport proof.
///
/// The production full-drain command remains `[0x16, 0x00]`. This policy only
/// admits a caller-supplied, bounded UTC interval encoded as
/// `startUnixLE32 + endUnixLE32`, plus the already-audited 22/00 preflight and
/// 14/00 abort. It deliberately has no ACK, seek, clock-write, or retry sweep.
enum AtriaBLEReadOnlyExactRangeCapturePolicy {
    static let maximumIntervalSeconds: UInt32 = 15 * 60
    static let captureTimeout: TimeInterval = 75

    static func payload(startUnix: UInt32, endUnix: UInt32) -> [UInt8]? {
        guard startUnix > 0,
              endUnix > startUnix,
              endUnix - startUnix <= maximumIntervalSeconds else {
            return nil
        }
        return le32(startUnix) + le32(endUnix)
    }

    static func allows(opcode: UInt8,
                       payload: [UInt8],
                       exactPayload: [UInt8]) -> Bool {
        switch opcode {
        case AtriaBLEReadOnlyHistoryCapturePolicy.getDataRange.opcode,
             AtriaBLEReadOnlyHistoryCapturePolicy.abort.opcode:
            return payload == [0x00]
        case AtriaBLEReadOnlyHistoryCapturePolicy.sendHistorical.opcode:
            return payload == exactPayload
                && payload.count == 8
                && decodedInterval(payload) != nil
        default:
            return false
        }
    }

    static func contains(timestamp: UInt32,
                         startUnix: UInt32,
                         endUnix: UInt32) -> Bool {
        timestamp >= startUnix && timestamp <= endUnix
    }

    private static func decodedInterval(_ payload: [UInt8]) -> (UInt32, UInt32)? {
        guard payload.count == 8 else { return nil }
        let start = u32le(payload, offset: 0)
        let end = u32le(payload, offset: 4)
        guard start > 0,
              end > start,
              end - start <= maximumIntervalSeconds else {
            return nil
        }
        return (start, end)
    }

    private static func le32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 24) & 0xff),
        ]
    }

    private static func u32le(_ bytes: [UInt8], offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

/// A small, bounded, fsynced evidence stream kept separate from the production
/// archive. JSONL makes every captured callback independently inspectable.
final class AtriaBLEReadOnlyHistoryCaptureStore {
    let url: URL
    private let handle: FileHandle
    private(set) var frameCount = 0

    init(directory: URL, runID: String) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        url = directory.appendingPathComponent("read-only-history-\(runID).jsonl")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(event: String,
                payload: [UInt8]? = nil,
                fields: [String: Any] = [:]) throws {
        var row = fields
        row["event"] = event
        row["received_at_unix"] = Date().timeIntervalSince1970
        if let payload {
            row["payload_hex"] = payload.map { String(format: "%02x", $0) }.joined()
        }
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        handle.write(data)
        handle.write(Data([0x0a]))
        try handle.synchronize()
        if event == "historical_frame" { frameCount += 1 }
    }

    func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
