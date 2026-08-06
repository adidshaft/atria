import Foundation

/// Disk-backed ordered ingress for a WHOOP history generation.
///
/// CoreBluetooth can deliver a complete flash backlog faster than JSON
/// materialization. Keeping that backlog in callback closures makes a slow
/// archive writer an unbounded memory allocation. This journal is deliberately
/// raw and private to one generation: it is only an ingress buffer, never
/// evidence for a HISTORY_END ACK. The existing archive + admission ledger
/// remain the durability and coverage authorities.
final class AtriaWhoop4HistoricalIngressSpool {
    static let productionMaximumBytes: UInt64 = 32 * 1024 * 1024
    /// A crashed history generation has no in-memory reducer or ACK gate to
    /// resume on the next process launch. Keep its raw ingress journal long
    /// enough for diagnosis/retry, but never let that non-authoritative cache
    /// become permanent user storage. The canonical archive and admission
    /// ledger have their own retention policies and are never removed here.
    static let orphanRetention: TimeInterval = 7 * 24 * 60 * 60
    static let productionDirectoryName = "atria-historical/history-ingress-v1"
    static let productionFileName = "whoop-history-ingress-current.bin"

    struct Clock: Equatable, Sendable {
        let device: UInt32
        let wall: UInt32
    }

    enum Event: Equatable, Sendable {
        case frame(payload: [UInt8], clock: Clock?, clockAuthorityEnabled: Bool)
        case metadata(payload: [UInt8], phaseGeneration: UInt64?)
    }

    enum SpoolError: Error, Equatable {
        case capacityExceeded
        case corruptRecord
        case generationMismatch
        case payloadTooLarge
    }

    private static let magic = Data([0x41, 0x54, 0x52, 0x49, 0x48, 0x49, 0x53, 0x31])
    private static let headerBytes = 16
    // Includes the four-byte record length prefix.
    private static let recordHeaderBytes = 20
    private static let maximumPayloadBytes = 4_096

    private let url: URL
    private let generation: UInt64
    private let maximumBytes: UInt64
    private var readOffset: UInt64 = UInt64(headerBytes)
    private var writeOffset: UInt64 = UInt64(headerBytes)
    private var unreadCount = 0
    private var writeHandle: FileHandle?
    private var readHandle: FileHandle?

    /// Reads only the immutable journal header. Callers use this before
    /// reopening a spool left by another process; it never authorizes an ACK
    /// or changes the journal's read state.
    static func generation(at url: URL) throws -> UInt64 {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= headerBytes,
              data.prefix(8) == magic else {
            throw SpoolError.corruptRecord
        }
        return Self.readU64(data, offset: 8)
    }

    init(url: URL, generation: UInt64, maximumBytes: UInt64 = productionMaximumBytes) throws {
        self.url = url
        self.generation = generation
        self.maximumBytes = maximumBytes
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try reopen()
        } else {
            try create()
        }
        writeHandle = try FileHandle(forWritingTo: url)
        readHandle = try FileHandle(forReadingFrom: url)
    }

    convenience init(directory: URL, generation: UInt64,
                     maximumBytes: UInt64 = productionMaximumBytes) throws {
        try self.init(url: directory.appendingPathComponent("whoop-history-ingress-\(generation).bin"),
                      generation: generation,
                      maximumBytes: maximumBytes)
    }

    /// Removes only an expired journal left by a *previous process*. Call this
    /// during manager construction, before any live history generation exists.
    /// A spool never authorizes an ACK; an ACK remains conditional on the
    /// canonical archive's durable terminal proof. Therefore this cannot drop
    /// data an ACK depends on. If metadata cannot be read, retain the file
    /// fail-closed and try again at a later launch.
    @discardableResult
    static func removeExpiredOrphan(
        at url: URL,
        now: Date = Date(),
        retention: TimeInterval = orphanRetention,
        fileManager: FileManager = .default
    ) -> Bool {
        guard retention >= 0,
              fileManager.fileExists(atPath: url.path) else { return false }
        do {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey,
                                                            .fileSizeKey,
                                                            .isRegularFileKey])
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= retention else {
                return false
            }
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    var pendingCount: Int { unreadCount }
    var isEmpty: Bool { unreadCount == 0 }
    var bytesOnDisk: UInt64 { writeOffset }

    func append(_ event: Event) throws {
        let encoded = try encode(event)
        let next = writeOffset + UInt64(encoded.count)
        guard next <= maximumBytes else { throw SpoolError.capacityExceeded }
        guard let handle = writeHandle else { throw CocoaError(.fileWriteUnknown) }
        try handle.seek(toOffset: writeOffset)
        try handle.write(contentsOf: encoded)
        writeOffset = next
        unreadCount += 1
        // This spool is an ordered, non-authoritative ingress buffer. The
        // canonical archive/admission flush remains the sole durability
        // boundary before an ACK. Never fsync this cache on the BLE/MainActor
        // callback path: a crash before canonical durability produces no ACK
        // and the strap safely replays the page.
    }

    func popFirst() throws -> Event? {
        guard unreadCount > 0 else { return nil }
        let (event, length) = try readEvent(at: readOffset)
        readOffset += UInt64(length)
        unreadCount -= 1
        return event
    }

    func peekFirst() throws -> Event? {
        guard unreadCount > 0 else { return nil }
        return try readEvent(at: readOffset).event
    }

    private func readEvent(at offset: UInt64) throws -> (event: Event, length: UInt32) {
        guard let handle = readHandle else { throw CocoaError(.fileReadUnknown) }
        try handle.seek(toOffset: offset)
        guard let length = try readU32(handle) else { throw SpoolError.corruptRecord }
        guard length >= Self.recordHeaderBytes,
              offset + UInt64(length) <= writeOffset else {
            throw SpoolError.corruptRecord
        }
        // `length` includes its four-byte prefix. `readU32` above advances the
        // handle, so seek back before reading the complete encoded record.
        // Reading `length` bytes from the post-prefix position shifted every
        // decode by four bytes and made any persisted spool look corrupt.
        try handle.seek(toOffset: offset)
        let record = try handle.read(upToCount: Int(length)) ?? Data()
        guard record.count == Int(length) else { throw SpoolError.corruptRecord }
        return (try decode(record), length)
    }

    /// An explicit boundary ends the generation; no unread event is silently
    /// discarded by this method. Callers must mark admission failed first when
    /// abandoning a nonempty spool.
    func remove() {
        try? writeHandle?.close()
        try? readHandle?.close()
        writeHandle = nil
        readHandle = nil
        try? FileManager.default.removeItem(at: url)
        readOffset = UInt64(Self.headerBytes)
        writeOffset = UInt64(Self.headerBytes)
        unreadCount = 0
    }

    func synchronize() throws {
        guard let handle = writeHandle else { throw CocoaError(.fileWriteUnknown) }
        try handle.synchronize()
    }

    private func create() throws {
        guard maximumBytes >= UInt64(Self.headerBytes) else { throw SpoolError.capacityExceeded }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var header = Self.magic
        header.append(le(generation))
        try handle.write(contentsOf: header)
        // Header durability is not ACK authority. Callers that hand this
        // cache to an off-main orphan vault may explicitly synchronize there.
    }

    private func reopen() throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count >= Self.headerBytes,
              data.prefix(8) == Self.magic,
              Self.readU64(data, offset: 8) == generation else {
            throw SpoolError.generationMismatch
        }
        guard UInt64(data.count) <= maximumBytes else { throw SpoolError.capacityExceeded }
        var offset = Self.headerBytes
        var count = 0
        // A crash can leave a partial final record. It never crossed an ACK
        // boundary, so truncate only that tail and make it retryable.
        while offset < data.count {
            guard offset + 4 <= data.count else { break }
            let length = Int(readU32(data, offset: offset))
            guard length >= Self.recordHeaderBytes, offset + length <= data.count else { break }
            _ = try decode(data.subdata(in: offset..<(offset + length)))
            offset += length
            count += 1
        }
        if offset != data.count {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
            // A torn tail necessarily predates canonical ACK authority.
            // Repeated reopen remains deterministic without blocking the
            // BLE/MainActor path on an inline filesystem sync.
        }
        writeOffset = UInt64(offset)
        readOffset = UInt64(Self.headerBytes)
        unreadCount = count
    }

    private func encode(_ event: Event) throws -> Data {
        let payload: [UInt8]
        let type: UInt8
        let generationField: UInt64
        let clock: Clock?
        let authority: Bool
        switch event {
        case let .frame(bytes, value, enabled):
            payload = bytes; type = 1; generationField = generation; clock = value; authority = enabled
        case let .metadata(bytes, phaseGeneration):
            payload = bytes; type = 2; generationField = phaseGeneration ?? UInt64.max; clock = nil; authority = false
        }
        guard payload.count <= Self.maximumPayloadBytes,
              payload.count <= Int(UInt16.max) else { throw SpoolError.payloadTooLarge }
        var result = Data()
        let clockBytes = clock == nil ? 0 : 8
        let recordBytes = Self.recordHeaderBytes + clockBytes + payload.count
        result.reserveCapacity(recordBytes)
        result.append(le(UInt32(recordBytes)))
        result.append(type)
        result.append(authority ? 1 : 0)
        result.append(le(UInt16(payload.count)))
        result.append(le(generationField))
        result.append(clock == nil ? 0 : 1)
        result.append(0); result.append(0); result.append(0)
        if let clock { result.append(le(clock.device)); result.append(le(clock.wall)) }
        result.append(contentsOf: payload)
        return result
    }

    private func decode(_ record: Data) throws -> Event {
        guard record.count >= Self.recordHeaderBytes,
              Int(readU32(record, offset: 0)) == record.count else { throw SpoolError.corruptRecord }
        let type = record[4]
        let authority = record[5] != 0
        let payloadLength = Int(readU16(record, offset: 6))
        let eventGeneration = Self.readU64(record, offset: 8)
        let hasClock = record[16] != 0
        let clockBytes = hasClock ? 8 : 0
        let payloadOffset = 20 + clockBytes
        guard payloadLength <= Self.maximumPayloadBytes,
              payloadOffset + payloadLength == record.count else { throw SpoolError.corruptRecord }
        let payload = Array(record[payloadOffset..<(payloadOffset + payloadLength)])
        switch type {
        case 1:
            guard eventGeneration == generation else { throw SpoolError.generationMismatch }
            let clock: Clock? = hasClock
                ? .init(device: readU32(record, offset: 20), wall: readU32(record, offset: 24)) : nil
            return .frame(payload: payload, clock: clock, clockAuthorityEnabled: authority)
        case 2:
            guard !hasClock else { throw SpoolError.corruptRecord }
            return .metadata(payload: payload,
                             phaseGeneration: eventGeneration == UInt64.max ? nil : eventGeneration)
        default:
            throw SpoolError.corruptRecord
        }
    }

    private func readU32(_ handle: FileHandle) throws -> UInt32? {
        guard let data = try handle.read(upToCount: 4), data.count == 4 else { return nil }
        return readU32(data, offset: 0)
    }

    private func readU16(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }
    private func readU32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
    private static func readU64(_ data: Data, offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { partial, index in
            partial | (UInt64(data[offset + index]) << UInt64(index * 8))
        }
    }
    private func le(_ value: UInt16) -> Data { Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)]) }
    private func le(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }) }
    private func le(_ value: UInt64) -> Data { Data((0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }) }

    deinit {
        try? writeHandle?.close()
        try? readHandle?.close()
    }
}
