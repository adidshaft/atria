import Foundation

enum FrameCodec {
    static func crc8(_ bytes: [UInt8]) -> UInt8 {
        var c: UInt8 = 0
        for byte in bytes {
            c ^= byte
            for _ in 0..<8 {
                c = (c & 0x80) != 0 ? (c << 1) ^ 0x07 : (c << 1)
            }
        }
        return c
    }

    /// ISO-HDLC / zlib. Matches frames this strap accepts.
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        func reflect8(_ value: UInt8) -> UInt32 {
            var v = value
            var r: UInt8 = 0
            for _ in 0..<8 {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            return UInt32(r)
        }
        func reflect32(_ value: UInt32) -> UInt32 {
            var v = value
            var r: UInt32 = 0
            for _ in 0..<32 {
                r = (r << 1) | (v & 1)
                v >>= 1
            }
            return r
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= reflect8(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : (crc << 1)
            }
        }
        return reflect32(crc) ^ 0xFFFF_FFFF
    }

    static func encode(sequence: UInt8, opcode: UInt8, payload: [UInt8]) -> Data {
        let inner = [0x23, sequence, opcode] + payload
        let length = UInt16(inner.count + 4)
        let lengthBytes = [UInt8(length & 0xFF), UInt8(length >> 8)]
        var out: [UInt8] = [0xAA] + lengthBytes + [crc8(lengthBytes)] + inner
        let crc = crc32(inner)
        out += [
            UInt8(crc & 0xFF),
            UInt8((crc >> 8) & 0xFF),
            UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 24) & 0xFF)
        ]
        return Data(out)
    }

    static func frames(from chunk: Data, residual: inout Data) -> [Data] {
        residual.append(chunk)
        var frames: [Data] = []
        let bytes = [UInt8](residual)
        var index = 0
        while index + 8 <= bytes.count, bytes[index] == 0xAA {
            let declared = Int(bytes[index + 1]) | (Int(bytes[index + 2]) << 8)
            let total = declared + 4
            if total < 8 || total > 4096 {
                index += 1
                continue
            }
            if index + total > bytes.count { break }
            frames.append(Data(bytes[index..<(index + total)]))
            index += total
        }
        residual = Data(bytes.dropFirst(index))
        return frames
    }
}

struct CommandReply: Equatable {
    var opcode: UInt8
    var echo: UInt8
    var status: UInt8
    var body: [UInt8]

    var statusLabel: String {
        switch status {
        case 0x00: return "other"
        case 0x01: return "accepted"
        case 0x02: return "pending"
        case 0x03: return "unsupported"
        default: return String(format: "%02X", status)
        }
    }

    var line: String {
        let bodyHex = body.map { String(format: "%02X", $0) }.joined()
        return String(format: "%02X echo %02X %@ %@", opcode, echo, statusLabel, bodyHex)
    }

    static func parse(frame: Data) -> CommandReply? {
        let bytes = [UInt8](frame)
        guard bytes.count >= 12, bytes[0] == 0xAA, bytes[4] == 0x24 else { return nil }
        let declared = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard declared + 4 <= bytes.count, declared >= 8 else { return nil }
        let payload = Array(bytes[4..<declared])
        guard payload.count >= 5 else { return nil }
        return CommandReply(
            opcode: payload[2],
            echo: payload[3],
            status: payload[4],
            body: Array(payload.dropFirst(5))
        )
    }
}

struct CompactSlice: Equatable {
    var deviceTime: UInt32
    var accelCount: Int
    var gyroCount: Int

    static func parse(frame: Data) -> CompactSlice? {
        let bytes = [UInt8](frame)
        guard bytes.count == 152, bytes[0] == 0xAA, bytes[4] == 0x33 else { return nil }
        let payload = Array(bytes[4..<(bytes.count - 4)])
        guard payload.count >= 24 else { return nil }
        let time = UInt32(payload[4])
            | (UInt32(payload[5]) << 8)
            | (UInt32(payload[6]) << 16)
            | (UInt32(payload[7]) << 24)
        let accel = Int(payload[20]) | (Int(payload[21]) << 8)
        let gyro = Int(payload[22]) | (Int(payload[23]) << 8)
        return CompactSlice(deviceTime: time, accelCount: accel, gyroCount: gyro)
    }
}

enum PacketClass: String {
    case heartRate = "Heart rate"
    case compactIMU = "Compact IMU"
    case backfillIMU = "Backfill IMU"
    case leftoverR10 = "Leftover R10"
    case proprietaryHR = "Proprietary HR"
    case commandReply = "Command reply"
    case historyMark = "History mark"
    case console = "Console"
    case event = "Event"
    case other = "Other"

    static func classify(uuid: String, frame: Data) -> PacketClass {
        let bytes = [UInt8](frame)
        if uuid.hasSuffix("2A37") { return .heartRate }
        guard bytes.count >= 5, bytes[0] == 0xAA else { return .other }
        switch bytes[4] {
        case 0x33 where bytes.count == 152: return .compactIMU
        case 0x34: return .backfillIMU
        case 0x2B: return .leftoverR10
        case 0x28: return .proprietaryHR
        case 0x24: return .commandReply
        case 0x31: return .historyMark
        case 0x32: return .console
        case 0x30: return .event
        default: return .other
        }
    }
}
