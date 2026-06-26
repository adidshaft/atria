import Foundation

enum HistoricalArchive {
    static let didUpdateNotification = Notification.Name("AtriaHistoricalArchiveDidUpdate")
    static let schema = 3
    static let layoutVersion = "strap4_v24_hr_rr_gravity_clock_diagnostic"
    static let relativePath = "Documents/atria-historical/historical-archive.jsonl"

    struct Diagnostics {
        let exists: Bool
        let parseOK: Bool
        let rows: Int
        let bytes: Int
        let schemas: [String]
        let layoutVersions: [String]
        let metricUsableRows: Int
        let currentSessionUsableRows: Int
        let undecodableRows: Int
        let rawPayloadRows: Int
        let unixFirst: UInt32?
        let unixLast: UInt32?
        let correctedUnixFirst: UInt32?
        let correctedUnixLast: UInt32?
        let gravityRows: Int
        let gravityValidatedRows: Int
        let reason: String
    }

    struct MotionWindowDiagnostics {
        let status: String
        let reason: String
        let rows: Int
        let validatedRows: Int
        let coverageSeconds: Int
        let spanSeconds: Int
        let meanVectorDelta: Double?
        let p95VectorDelta: Double?
        let magnitudeMean: Double?
        let magnitudeStdDev: Double?
        let archiveFirstUnix: Int
        let archiveLastUnix: Int
        let nearestSeparationSeconds: Int
        let lowMotionReady: Bool
    }

    struct Record: Codable {
        let schema: Int
        let capturedAt: Date
        let source: String
        let layoutVersion: String
        let sequence: Int
        let command: Int
        let unix7: UInt32
        let subsec11: UInt16
        let flash13: UInt32
        let payloadLength: Int
        let whoofHR17: Int
        let whoofRRNum18: Int
        let whoofRR19: [Int]
        let kRR64: [Int]
        let gravityX36: Double?
        let gravityY40: Double?
        let gravityZ44: Double?
        let gravityMagnitude: Double?
        let gravityValidated: Bool
        let candidateRR: [String]
        let rawPayloadHex: String
        let clockDeviceRef: UInt32?
        let clockWallRef: UInt32?
        let clockDriftSeconds: Int?
        let clockCorrectedUnix7: UInt32?
        let clockCorrectionStatus: String
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let usabilityReason: String
    }

    struct UndecodableFrame: Codable {
        let schema: Int
        let capturedAt: Date
        let source: String
        let payloadLength: Int
        let rawPayloadHex: String
        let currentSessionUsable: Bool
        let metricUsable: Bool
        let usabilityReason: String
    }

    static var fileURL: URL {
        documentsDirectory
            .appendingPathComponent("atria-historical", isDirectory: true)
            .appendingPathComponent("historical-archive.jsonl")
    }

    private static var legacyFileURL: URL {
        documentsDirectory
            .appendingPathComponent("whoop-historical", isDirectory: true)
            .appendingPathComponent("historical-archive.jsonl")
    }

    private static var readableFileURL: URL {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return legacyFileURL
    }

    static func append(_ record: Record) throws -> URL {
        try appendJSONLine(record)
    }

    static func appendUndecodable(payload: [UInt8], reason: String) throws -> URL {
        let frame = UndecodableFrame(schema: schema,
                                     capturedAt: Date(),
                                     source: "0x2f",
                                     payloadLength: payload.count,
                                     rawPayloadHex: hex(payload),
                                     currentSessionUsable: false,
                                     metricUsable: false,
                                     usabilityReason: reason)
        return try appendJSONLine(frame)
    }

    static func diagnostics() -> Diagnostics {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Diagnostics(exists: false,
                               parseOK: true,
                               rows: 0,
                               bytes: 0,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: 0,
                               currentSessionUsableRows: 0,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "missing_archive")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var rows = 0
            var schemas = Set<String>()
            var layouts = Set<String>()
            var metricUsableRows = 0
            var currentSessionUsableRows = 0
            var undecodableRows = 0
            var rawPayloadRows = 0
            var unixFirst: UInt32?
            var unixLast: UInt32?
            var correctedUnixFirst: UInt32?
            var correctedUnixLast: UInt32?
            var gravityRows = 0
            var gravityValidatedRows = 0

            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                rows += 1
                guard let data = line.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return Diagnostics(exists: true,
                                       parseOK: false,
                                       rows: rows,
                                       bytes: byteCount,
                                       schemas: Array(schemas).sorted(),
                                       layoutVersions: Array(layouts).sorted(),
                                       metricUsableRows: metricUsableRows,
                                       currentSessionUsableRows: currentSessionUsableRows,
                                       undecodableRows: undecodableRows,
                                       rawPayloadRows: rawPayloadRows,
                                       unixFirst: unixFirst,
                                       unixLast: unixLast,
                                       correctedUnixFirst: correctedUnixFirst,
                                       correctedUnixLast: correctedUnixLast,
                                       gravityRows: gravityRows,
                                       gravityValidatedRows: gravityValidatedRows,
                                       reason: "invalid_jsonl_row_\(rows)")
                }

                if let schema = object["schema"] {
                    schemas.insert(String(describing: schema))
                } else {
                    schemas.insert("missing")
                }
                if let layout = object["layoutVersion"] as? String, !layout.isEmpty {
                    layouts.insert(layout)
                } else {
                    layouts.insert("undecodable")
                    if object["source"] as? String == "0x2f" {
                        undecodableRows += 1
                    }
                }
                if object["metricUsable"] as? Bool == true {
                    metricUsableRows += 1
                }
                if object["currentSessionUsable"] as? Bool == true {
                    currentSessionUsableRows += 1
                }
                if let rawPayload = object["rawPayloadHex"] as? String, !rawPayload.isEmpty {
                    rawPayloadRows += 1
                    if let payload = bytes(fromHex: rawPayload),
                       let gravity = historicalGravity(payload) {
                        gravityRows += 1
                        if gravity.validated {
                            gravityValidatedRows += 1
                        }
                    }
                }
                if let unixNumber = object["unix7"] as? NSNumber {
                    let value = unixNumber.uint32Value
                    if value > 0 {
                        unixFirst = min(unixFirst ?? value, value)
                        unixLast = max(unixLast ?? value, value)
                    }
                }
                if let correctedNumber = object["clockCorrectedUnix7"] as? NSNumber {
                    let value = correctedNumber.uint32Value
                    if value > 0 {
                        correctedUnixFirst = min(correctedUnixFirst ?? value, value)
                        correctedUnixLast = max(correctedUnixLast ?? value, value)
                    }
                }
            }

            return Diagnostics(exists: true,
                               parseOK: true,
                               rows: rows,
                               bytes: byteCount,
                               schemas: Array(schemas).sorted(),
                               layoutVersions: Array(layouts).sorted(),
                               metricUsableRows: metricUsableRows,
                               currentSessionUsableRows: currentSessionUsableRows,
                               undecodableRows: undecodableRows,
                               rawPayloadRows: rawPayloadRows,
                               unixFirst: unixFirst,
                               unixLast: unixLast,
                               correctedUnixFirst: correctedUnixFirst,
                               correctedUnixLast: correctedUnixLast,
                               gravityRows: gravityRows,
                               gravityValidatedRows: gravityValidatedRows,
                               reason: rows > 0 ? "ok" : "empty_archive")
        } catch {
            return Diagnostics(exists: true,
                               parseOK: false,
                               rows: 0,
                               bytes: byteCount,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: 0,
                               currentSessionUsableRows: 0,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "read_failed")
        }
    }

    static func motionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
        guard end > start else {
            return emptyMotionWindow(status: "learning", reason: "invalid_window")
        }
        let windowStart = start.timeIntervalSince1970
        let windowEnd = end.timeIntervalSince1970
        let records = loadGravitySamples()
        guard !records.isEmpty else {
            return emptyMotionWindow(status: "learning", reason: "no_historical_gravity")
        }
        let archiveFirst = Int(records.map(\.timestamp).min()?.rounded() ?? 0)
        let archiveLast = Int(records.map(\.timestamp).max()?.rounded() ?? 0)
        let nearestSeparation = nearestSeparationSeconds(archiveFirst: TimeInterval(archiveFirst),
                                                         archiveLast: TimeInterval(archiveLast),
                                                         windowStart: windowStart,
                                                         windowEnd: windowEnd)
        let overlapping = records
            .filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.sequence < $1.sequence
            }
        guard !overlapping.isEmpty else {
            let reason: String
            if nearestSeparation >= 24 * 60 * 60 {
                reason = archiveLast < Int(windowStart.rounded()) ? "historical_archive_stale" : "historical_archive_future_or_misaligned"
            } else {
                reason = "no_timestamp_overlap"
            }
            return MotionWindowDiagnostics(status: "learning",
                                           reason: reason,
                                           rows: 0,
                                           validatedRows: 0,
                                           coverageSeconds: 0,
                                           spanSeconds: Int(end.timeIntervalSince(start).rounded()),
                                           meanVectorDelta: nil,
                                           p95VectorDelta: nil,
                                           magnitudeMean: nil,
                                           magnitudeStdDev: nil,
                                           archiveFirstUnix: archiveFirst,
                                           archiveLastUnix: archiveLast,
                                           nearestSeparationSeconds: nearestSeparation,
                                           lowMotionReady: false)
        }

        let validated = overlapping.filter(\.validated)
        guard validated.count >= 2 else {
            return MotionWindowDiagnostics(status: "learning",
                                           reason: "insufficient_validated_gravity",
                                           rows: overlapping.count,
                                           validatedRows: validated.count,
                                           coverageSeconds: coverageSeconds(for: overlapping.map(\.timestamp)),
                                           spanSeconds: Int(end.timeIntervalSince(start).rounded()),
                                           meanVectorDelta: nil,
                                           p95VectorDelta: nil,
                                           magnitudeMean: nil,
                                           magnitudeStdDev: nil,
                                           archiveFirstUnix: archiveFirst,
                                           archiveLastUnix: archiveLast,
                                           nearestSeparationSeconds: nearestSeparation,
                                           lowMotionReady: false)
        }

        let deltas = zip(validated, validated.dropFirst()).map { previous, current in
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let dz = current.z - previous.z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }
        let magnitudes = validated.map(\.magnitude)
        let coverage = coverageSeconds(for: validated.map(\.timestamp))
        let meanDelta = mean(deltas)
        let p95Delta = percentile(deltas, 0.95)
        let magnitudeMean = mean(magnitudes)
        let magnitudeStdDev = stddev(magnitudes, mean: magnitudeMean)
        let enoughCoverage = validated.count >= 300 && coverage >= 30 * 60
        let stableVector = (p95Delta ?? .infinity) <= 0.08
        let stableMagnitude = (magnitudeStdDev ?? .infinity) <= 0.05
        let ready = enoughCoverage && stableVector && stableMagnitude
        let reason: String
        if !enoughCoverage {
            reason = "insufficient_overlap_coverage"
        } else if !stableVector {
            reason = "vector_delta_high"
        } else if !stableMagnitude {
            reason = "magnitude_variance_high"
        } else {
            reason = "timestamp_aligned_low_motion"
        }
        return MotionWindowDiagnostics(status: ready ? "ready" : "learning",
                                       reason: reason,
                                       rows: overlapping.count,
                                       validatedRows: validated.count,
                                       coverageSeconds: coverage,
                                       spanSeconds: Int(end.timeIntervalSince(start).rounded()),
                                       meanVectorDelta: meanDelta,
                                       p95VectorDelta: p95Delta,
                                       magnitudeMean: magnitudeMean,
                                       magnitudeStdDev: magnitudeStdDev,
                                       archiveFirstUnix: archiveFirst,
                                       archiveLastUnix: archiveLast,
                                       nearestSeparationSeconds: nearestSeparation,
                                       lowMotionReady: ready)
    }

    private static func appendJSONLine<T: Encodable>(_ value: T) throws -> URL {
        let url = fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        var line = data
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        return url
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private struct GravitySample {
        let timestamp: TimeInterval
        let sequence: Int
        let x: Double
        let y: Double
        let z: Double
        let magnitude: Double
        let validated: Bool
    }

    private static func loadGravitySamples() -> [GravitySample] {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var samples: [GravitySample] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: data) else { continue }
            let unix = record.clockCorrectedUnix7 ?? record.unix7
            guard unix > 0,
                  let payload = bytes(fromHex: record.rawPayloadHex),
                  let gravity = historicalGravity(payload) else { continue }
            samples.append(GravitySample(timestamp: TimeInterval(unix),
                                         sequence: record.sequence,
                                         x: gravity.x,
                                         y: gravity.y,
                                         z: gravity.z,
                                         magnitude: gravity.magnitude,
                                         validated: gravity.validated))
        }
        return samples
    }

    private static func emptyMotionWindow(status: String, reason: String) -> MotionWindowDiagnostics {
        MotionWindowDiagnostics(status: status,
                                reason: reason,
                                rows: 0,
                                validatedRows: 0,
                                coverageSeconds: 0,
                                spanSeconds: 0,
                                meanVectorDelta: nil,
                                p95VectorDelta: nil,
                                magnitudeMean: nil,
                                magnitudeStdDev: nil,
                                archiveFirstUnix: 0,
                                archiveLastUnix: 0,
                                nearestSeparationSeconds: 0,
                                lowMotionReady: false)
    }

    private static func nearestSeparationSeconds(archiveFirst: TimeInterval,
                                                 archiveLast: TimeInterval,
                                                 windowStart: TimeInterval,
                                                 windowEnd: TimeInterval) -> Int {
        guard archiveFirst > 0, archiveLast > 0 else { return 0 }
        if archiveLast < windowStart {
            return Int((windowStart - archiveLast).rounded())
        }
        if archiveFirst > windowEnd {
            return Int((archiveFirst - windowEnd).rounded())
        }
        return 0
    }

    private static func coverageSeconds(for timestamps: [TimeInterval]) -> Int {
        guard let first = timestamps.min(), let last = timestamps.max(), last >= first else { return 0 }
        return Int((last - first).rounded())
    }

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func stddev(_ values: [Double], mean: Double?) -> Double? {
        guard values.count >= 2, let mean else { return nil }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1)
        return sqrt(variance)
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * clamped).rounded(.down))))
        return sorted[index]
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func historicalGravity(_ payload: [UInt8]) -> (x: Double, y: Double, z: Double, magnitude: Double, validated: Bool)? {
        let version = payload.count > 1 ? Int(payload[1]) : -1
        let x: Double
        let y: Double
        let z: Double
        if version == 25 {
            guard let gx = i16le(payload, 69),
                  let gy = i16le(payload, 71),
                  let gz = i16le(payload, 73) else { return nil }
            x = Double(gx) / 16384.0
            y = Double(gy) / 16384.0
            z = Double(gz) / 16384.0
        } else {
            guard let gx = f32le(payload, 36),
                  let gy = f32le(payload, 40),
                  let gz = f32le(payload, 44) else { return nil }
            x = gx
            y = gy
            z = gz
        }
        let magnitude = sqrt(x * x + y * y + z * z)
        return (x, y, z, magnitude, (0.8...1.2).contains(magnitude))
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private static func f32le(_ bytes: [UInt8], _ offset: Int) -> Double? {
        guard offset + 3 < bytes.count else { return nil }
        let raw = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Double(Float32(bitPattern: raw))
    }

    private static func i16le(_ bytes: [UInt8], _ offset: Int) -> Int16? {
        guard offset + 1 < bytes.count else { return nil }
        let raw = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        return Int16(bitPattern: raw)
    }
}
