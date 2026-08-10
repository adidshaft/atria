import Foundation

/// Reassembles WHOOP 4 Harvard frames that span multiple BLE notifications.
/// Buffers are independent per characteristic so interleaved GATT streams cannot
/// corrupt one another. Framing is length-based because sensor payloads can
/// legitimately contain the 0xAA start byte.
final class AtriaWhoop4FrameReassembler: @unchecked Sendable {
    /// Immutable callback-entry scope for one characteristic buffer. Ordinary
    /// realtime traffic uses the all-nil scope. Historical traffic binds every
    /// fragment to its transport generation and exact 0x16 serve command, so a
    /// partial predecessor frame can never inherit a later command's authority.
    struct Scope: Equatable, Sendable {
        let historyGeneration: UInt64?
        let historyServeToken: UInt64?

        static let realtime = Scope(
            historyGeneration: nil,
            historyServeToken: nil
        )
    }

    private let lock = NSLock()
    private let maximumFrameBytes: Int
    private let maximumBufferedBytes: Int
    private var buffers: [String: [UInt8]] = [:]
    private var scopes: [String: Scope] = [:]

    init(maximumFrameBytes: Int = 4_096,
         maximumBufferedBytes: Int = 8_192) {
        self.maximumFrameBytes = max(8, maximumFrameBytes)
        self.maximumBufferedBytes = max(maximumFrameBytes, maximumBufferedBytes)
    }

    func feed(
        _ fragment: Data,
        source: String,
        scope: Scope = .realtime
    ) -> [Data] {
        guard !fragment.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        if scopes[source] != scope {
            // The old partial bytes were received outside this exact serve
            // command. Drop only this characteristic's non-authoritative
            // reassembly cache; other streams remain independent.
            buffers.removeValue(forKey: source)
            scopes[source] = scope
        }
        var buffer = buffers[source, default: []]
        buffer.append(contentsOf: fragment)
        var frames: [Data] = []

        while true {
            guard alignToPlausibleHeader(&buffer) else { break }
            guard buffer.count >= 4 else { break }

            let declaredLength = Int(buffer[1]) | (Int(buffer[2]) << 8)
            let totalLength = declaredLength + 4
            guard buffer.count >= totalLength else { break }

            let payload = buffer[4..<declaredLength]
            let actualCRC = UInt32(buffer[declaredLength])
                | (UInt32(buffer[declaredLength + 1]) << 8)
                | (UInt32(buffer[declaredLength + 2]) << 16)
                | (UInt32(buffer[declaredLength + 3]) << 24)
            guard crc32(payload) == actualCRC else {
                // A dropped/corrupt fragment can leave an apparent header at the
                // front. Advance one byte, then search for the next valid header.
                buffer.removeFirst()
                continue
            }

            frames.append(Data(buffer.prefix(totalLength)))
            buffer.removeFirst(totalLength)
            while buffer.first == 0 { buffer.removeFirst() }
        }

        if buffer.count > maximumBufferedBytes {
            retainLastPartialHeader(in: &buffer)
        }
        buffers[source] = buffer
        return frames
    }

    func reset(source: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let source {
            buffers.removeValue(forKey: source)
            scopes.removeValue(forKey: source)
        } else {
            buffers.removeAll(keepingCapacity: true)
            scopes.removeAll(keepingCapacity: true)
        }
    }

    func bufferedByteCount(source: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers[source]?.count ?? 0
    }

    private func alignToPlausibleHeader(_ buffer: inout [UInt8]) -> Bool {
        guard !buffer.isEmpty else { return false }
        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0xAA else {
                index += 1
                continue
            }
            guard index + 3 < buffer.count else {
                if index > 0 { buffer.removeFirst(index) }
                return false
            }
            let low = buffer[index + 1]
            let high = buffer[index + 2]
            let declaredLength = Int(low) | (Int(high) << 8)
            let totalLength = declaredLength + 4
            if buffer[index + 3] == crc8([low, high]),
               declaredLength >= 5,
               totalLength <= maximumFrameBytes {
                if index > 0 { buffer.removeFirst(index) }
                return true
            }
            index += 1
        }
        buffer.removeAll(keepingCapacity: true)
        return false
    }

    private func retainLastPartialHeader(in buffer: inout [UInt8]) {
        if let index = buffer.lastIndex(of: 0xAA) {
            buffer = Array(buffer[index...])
            if buffer.count > 3 {
                buffer.removeAll(keepingCapacity: true)
            }
        } else {
            buffer.removeAll(keepingCapacity: true)
        }
    }
}
