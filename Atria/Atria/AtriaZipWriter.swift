import Foundation

struct AtriaZipWriter {
    private struct Entry {
        let name: String
        let crc32: UInt32
        let size: UInt32
        let offset: UInt32
        let dosTime: UInt16
        let dosDate: UInt16
    }

    private let url: URL
    private let handle: FileHandle
    private var entries: [Entry] = []

    init(url: URL) throws {
        self.url = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
    }

    mutating func addEntry(name: String, write: (FileHandle) throws -> Void) throws {
        precondition(entries.count < 65_535)
        let safeName = name.replacingOccurrences(of: "\\", with: "/")
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atria-zip-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let tempHandle = try FileHandle(forWritingTo: tempURL)
        try write(tempHandle)
        try tempHandle.close()
        let data = try Data(contentsOf: tempURL)
        try? FileManager.default.removeItem(at: tempURL)
        try addEntry(name: safeName, data: data)
    }

    mutating func addEntry(name: String, data: Data) throws {
        precondition(data.count < UInt32.max)
        let safeName = name.replacingOccurrences(of: "\\", with: "/")
        let filename = Data(safeName.utf8)
        let offset = UInt32(try currentOffset())
        let crc = Self.crc32(data)
        let size = UInt32(data.count)
        let dos = Self.dosDateTime(Date())

        try writeUInt32(0x04034b50)
        try writeUInt16(20)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(dos.time)
        try writeUInt16(dos.date)
        try writeUInt32(crc)
        try writeUInt32(size)
        try writeUInt32(size)
        try writeUInt16(UInt16(filename.count))
        try writeUInt16(0)
        try handle.write(contentsOf: filename)
        try handle.write(contentsOf: data)

        entries.append(Entry(name: safeName,
                             crc32: crc,
                             size: size,
                             offset: offset,
                             dosTime: dos.time,
                             dosDate: dos.date))
    }

    mutating func finalize() throws {
        let centralOffset = UInt32(try currentOffset())
        for entry in entries {
            let filename = Data(entry.name.utf8)
            try writeUInt32(0x02014b50)
            try writeUInt16(20)
            try writeUInt16(20)
            try writeUInt16(0)
            try writeUInt16(0)
            try writeUInt16(entry.dosTime)
            try writeUInt16(entry.dosDate)
            try writeUInt32(entry.crc32)
            try writeUInt32(entry.size)
            try writeUInt32(entry.size)
            try writeUInt16(UInt16(filename.count))
            try writeUInt16(0)
            try writeUInt16(0)
            try writeUInt16(0)
            try writeUInt16(0)
            try writeUInt32(0)
            try writeUInt32(entry.offset)
            try handle.write(contentsOf: filename)
        }
        let centralSize = UInt32(try currentOffset()) - centralOffset
        try writeUInt32(0x06054b50)
        try writeUInt16(0)
        try writeUInt16(0)
        try writeUInt16(UInt16(entries.count))
        try writeUInt16(UInt16(entries.count))
        try writeUInt32(centralSize)
        try writeUInt32(centralOffset)
        try writeUInt16(0)
        try handle.close()
    }

    private func currentOffset() throws -> UInt64 {
        try handle.offset()
    }

    private func writeUInt16(_ value: UInt16) throws {
        var little = value.littleEndian
        try handle.write(contentsOf: Data(bytes: &little, count: MemoryLayout<UInt16>.size))
    }

    private func writeUInt32(_ value: UInt32) throws {
        var little = value.littleEndian
        try handle.write(contentsOf: Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }

    private static func dosDateTime(_ date: Date) -> (date: UInt16, time: UInt16) {
        let components = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((components.year ?? 1980) - 1980, 0)
        let month = components.month ?? 1
        let day = components.day ?? 1
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        let second = (components.second ?? 0) / 2
        return (UInt16((year << 9) | (month << 5) | day),
                UInt16((hour << 11) | (minute << 5) | second))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ crcTable[index]
        }
        return crc ^ 0xffff_ffff
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (0xedb8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }
}
