import Foundation

enum HistoricalArchive {
    static let didUpdateNotification = Notification.Name("AtriaHistoricalArchiveDidUpdate")
    static let schema = 3
    static let layoutVersion = "strap4_v24_hr_rr_gravity_clock_diagnostic"
    // Empty until a generation-specific fixed layout passes an independent
    // HR/RR reference validation. Diagnostic layouts must never feed metrics.
    static let validatedMetricLayoutVersions: Set<String> = []
    static let relativePath = "Documents/atria-historical/historical-archive.jsonl"
    private static let diagnosticsIndexFilename = "historical-archive.diagnostics.json"
    private static let rotationManifestFilename = "historical-archive.manifest.json"
    private static let rotationThresholdBytes = 128 * 1024 * 1024
    private static let maxImmediateDiagnosticsScanBytes = 8 * 1024 * 1024
    private static let segmentsDirectoryName = "segments"
    private static let promotionLock = NSLock()
    private static let diagnosticsIndexLock = NSLock()
    private static let recentGravityCacheLock = NSLock()
#if DEBUG
    private static let fullGravityInstrumentationLock = NSLock()
    private static var fullGravityLoadCount = 0
#endif
    private static let archiveDateFormatter = ISO8601DateFormatter()
    private static var recentGravityCache: RecentGravityCache?
    private static var recentGravityLoadInFlight = false

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

    struct MetricReadinessProbe {
        let ready: Bool
        let rowsScanned: Int
        let metricUsableRows: Int
        let currentSessionUsableRows: Int
        let reason: String
    }

    private struct DiagnosticsIndex: Codable {
        var fileSize: Int
        var modificationTime: TimeInterval
        var rows: Int
        var schemas: [String]
        var layoutVersions: [String]
        var metricUsableRows: Int
        var currentSessionUsableRows: Int
        var undecodableRows: Int
        var rawPayloadRows: Int
        var unixFirst: UInt32?
        var unixLast: UInt32?
        var correctedUnixFirst: UInt32?
        var correctedUnixLast: UInt32?
        var gravityRows: Int
        var gravityValidatedRows: Int
    }

    private struct RotationManifest: Codable {
        var version: Int
        var baseRelativePath: String
        var activeSegmentRelativePath: String
        var createdAt: Date
        var rotationThresholdBytes: Int
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

    struct MotionArchiveSnapshot {
        fileprivate let samples: [GravitySample]

        func diagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
            HistoricalArchive.motionWindowDiagnostics(start: start,
                                                       end: end,
                                                       records: samples)
        }
    }

    struct MotionFeatureSummary: Equatable {
        let stillnessRatio: Double
        let movementIntensity: Double
        let rows: Int
        let validatedRows: Int
        let coverageSeconds: Int
        let maximumGapSeconds: Int
        let firstUnix: Int
        let lastUnix: Int
        let reason: String

        var lowMotionReady: Bool {
            let validatedRatio = rows > 0 ? Double(validatedRows) / Double(rows) : 0
            return validatedRows >= 300
                && validatedRatio >= 0.95
                && coverageSeconds >= 30 * 60
                && maximumGapSeconds <= 5 * 60
                && stillnessRatio >= 0.72
                && movementIntensity <= 0.18
        }
    }

    struct HeartRatePoint: Equatable, Sendable {
        let t: Date
        let bpm: Int
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
        archiveDirectory
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

    private static var diagnosticsIndexURL: URL {
        archiveDirectory.appendingPathComponent(diagnosticsIndexFilename)
    }

    private static var rotationManifestURL: URL {
        archiveDirectory.appendingPathComponent(rotationManifestFilename)
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

    /// Establishes the durability boundary used by the strap-history ACK.
    /// Individual frames are appended serially; synchronizing once at the end
    /// of a transmitted batch keeps the hot path cheap while ensuring the
    /// strap is never told to trim data that exists only in the OS write cache.
    static func synchronizeDurableStorage() throws {
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let url = try writableFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
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

        let attributes = archiveAttributes(for: url)
        let byteCount = attributes.byteCount
        if let index = readDiagnosticsIndex(for: url, attributes: attributes) {
            let segmentIndexes = rotatedSegmentFileURLs().compactMap { segmentURL -> DiagnosticsIndex? in
                let segmentAttributes = archiveAttributes(for: segmentURL)
                if let segmentIndex = readDiagnosticsIndex(for: segmentURL, attributes: segmentAttributes) {
                    return segmentIndex
                }
                guard segmentAttributes.byteCount <= 8 * 1024 * 1024,
                      let segmentIndex = scanDiagnosticsIndex(for: segmentURL, attributes: segmentAttributes) else {
                    return nil
                }
                writeDiagnosticsIndex(segmentIndex, for: segmentURL)
                return segmentIndex
            }
            if !segmentIndexes.isEmpty {
                let aggregate = aggregateDiagnosticsIndex(base: index, segments: segmentIndexes)
                return diagnostics(from: aggregate, reason: "aggregate_index_ok")
            }
            return diagnostics(from: index, reason: index.rows > 0 ? "index_ok" : "empty_archive_index")
        }

        guard attributes.byteCount <= maxImmediateDiagnosticsScanBytes else {
            let probe = quickMetricReadinessProbe()
            return Diagnostics(exists: true,
                               parseOK: true,
                               rows: probe.rowsScanned,
                               bytes: byteCount,
                               schemas: [],
                               layoutVersions: [],
                               metricUsableRows: probe.metricUsableRows,
                               currentSessionUsableRows: probe.currentSessionUsableRows,
                               undecodableRows: 0,
                               rawPayloadRows: 0,
                               unixFirst: nil,
                               unixLast: nil,
                               correctedUnixFirst: nil,
                               correctedUnixLast: nil,
                               gravityRows: 0,
                               gravityValidatedRows: 0,
                               reason: "large_archive_index_missing_probe_\(probe.reason)")
        }

        if let index = scanDiagnosticsIndex(for: url, attributes: attributes) {
            writeDiagnosticsIndex(index, for: url)
            return diagnostics(from: index, reason: index.rows > 0 ? "scanned_index_written" : "empty_archive")
        } else {
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

    static func quickMetricReadinessProbe(maxRows: Int = 20_000) -> MetricReadinessProbe {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return MetricReadinessProbe(ready: false,
                                        rowsScanned: 0,
                                        metricUsableRows: 0,
                                        currentSessionUsableRows: 0,
                                        reason: "missing_archive")
        }
        guard let stream = InputStream(url: url) else {
            return MetricReadinessProbe(ready: false,
                                        rowsScanned: 0,
                                        metricUsableRows: 0,
                                        currentSessionUsableRows: 0,
                                        reason: "read_failed")
        }
        stream.open()
        defer { stream.close() }

        var rowsScanned = 0
        var metricRows = 0
        var currentRows = 0
        var lineBuffer = ""
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        while stream.hasBytesAvailable && rowsScanned < maxRows {
            let readCount = stream.read(&buffer, maxLength: chunkSize)
            if readCount < 0 {
                return MetricReadinessProbe(ready: false,
                                            rowsScanned: rowsScanned,
                                            metricUsableRows: metricRows,
                                            currentSessionUsableRows: currentRows,
                                            reason: "read_failed")
            }
            if readCount == 0 { break }
            lineBuffer += String(decoding: buffer.prefix(readCount), as: UTF8.self)
            while let newlineRange = lineBuffer.range(of: "\n"), rowsScanned < maxRows {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer.removeSubrange(..<newlineRange.upperBound)
                guard !line.isEmpty else { continue }
                rowsScanned += 1
                if let data = line.data(using: .utf8),
                   let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if metricUsable(object: object) { metricRows += 1 }
                    if object["currentSessionUsable"] as? Bool == true { currentRows += 1 }
                }
                if metricRows > 0 {
                    return MetricReadinessProbe(ready: true,
                                                rowsScanned: rowsScanned,
                                                metricUsableRows: metricRows,
                                                currentSessionUsableRows: currentRows,
                                                reason: currentRows > 0 ? "metric_ready" : "metric_ready_without_explicit_current_flag")
                }
            }
        }

        if rowsScanned < maxRows, !lineBuffer.isEmpty {
            rowsScanned += 1
            if let data = lineBuffer.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if metricUsable(object: object) { metricRows += 1 }
                if object["currentSessionUsable"] as? Bool == true { currentRows += 1 }
            }
        }

        return MetricReadinessProbe(ready: metricRows > 0,
                                    rowsScanned: rowsScanned,
                                    metricUsableRows: metricRows,
                                    currentSessionUsableRows: currentRows,
                                    reason: metricRows > 0 ? (currentRows > 0 ? "metric_ready" : "metric_ready_without_explicit_current_flag") : (rowsScanned > 0 ? "not_ready_in_probe_window" : "empty_archive"))
    }

    @discardableResult
    static func promoteMetricUsableRows(reason: String) -> Int {
        promotionLock.lock()
        defer { promotionLock.unlock() }

        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            var updated = 0
            var output: [String] = []
            output.reserveCapacity(content.split(whereSeparator: \.isNewline).count)
            for rawLine in content.split(whereSeparator: \.isNewline) {
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty else { continue }
                guard let data = line.data(using: .utf8),
                      var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    output.append(line)
                    continue
                }
                if object["metricUsable"] as? Bool != true,
                   metricEvidenceValidated(object: object) {
                    object["metricUsable"] = true
                    object["usabilityReason"] = "metric_ready_clock_gravity_rr"
                    updated += 1
                    let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    output.append(String(decoding: encoded, as: UTF8.self))
                } else {
                    output.append(line)
                }
            }
            guard updated > 0 else { return 0 }
            let promoted = output.joined(separator: "\n") + "\n"
            try promoted.write(to: fileURL, atomically: true, encoding: .utf8)
            NotificationCenter.default.post(name: didUpdateNotification, object: nil)
            AtriaDebugLog("ATRIADBG historical_archive_promotion status=updated reason=%@ rows=%d criteria=clock_corrected_gravity_validated_rr_bearing",
                          reason,
                          updated)
            return updated
        } catch {
            AtriaDebugLog("ATRIADBG historical_archive_promotion status=failed reason=%@ error=%@",
                          reason,
                          String(describing: error).replacingOccurrences(of: " ", with: "_"))
            return 0
        }
    }

    private static func currentSessionUsable(object: [String: Any]) -> Bool {
        let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value ?? 0
        let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value ?? 0
        guard max(correctedUnix, rawUnix) > 0 else { return false }
        guard let payloadHex = object["rawPayloadHex"] as? String,
              let payload = bytes(fromHex: payloadHex),
              historicalGravity(payload)?.validated == true else { return false }
        let directRRCount = ((object["whoofRR19"] as? [Any])?.count ?? 0)
            + ((object["kRR64"] as? [Any])?.count ?? 0)
        let candidateRRCount = (object["candidateRR"] as? [Any])?.count ?? 0
        return directRRCount > 0 || candidateRRCount >= 2
    }

    static func metricLayoutValidated(_ layoutVersion: String) -> Bool {
        validatedMetricLayoutVersions.contains(layoutVersion)
    }

    private static func metricUsable(object: [String: Any]) -> Bool {
        guard object["metricUsable"] as? Bool == true else { return false }
        return metricEvidenceValidated(object: object)
    }

    private static func metricEvidenceValidated(object: [String: Any]) -> Bool {
        guard let layoutVersion = object["layoutVersion"] as? String,
              metricLayoutValidated(layoutVersion) else { return false }
        guard object["clockCorrectionStatus"] as? String == "clock_ref_present" else { return false }
        guard object["gravityValidated"] as? Bool == true else { return false }
        return rrValues(object["whoofRR19"]).contains { (300...2000).contains($0) }
            || rrValues(object["kRR64"]).contains { (300...2000).contains($0) }
    }

    private static func rrValues(_ value: Any?) -> [Int] {
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { item in
            if let number = item as? NSNumber { return number.intValue }
            if let int = item as? Int { return int }
            return nil
        }
    }

    static func motionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
        guard !Thread.isMainThread else {
            return emptyMotionWindow(status: "learning", reason: "full_archive_requires_background")
        }
        return makeMotionArchiveSnapshot().diagnostics(start: start, end: end)
    }

    static func makeMotionArchiveSnapshot() -> MotionArchiveSnapshot {
        precondition(!Thread.isMainThread, "Full historical motion decoding must run off the main thread")
        return MotionArchiveSnapshot(samples: loadGravitySamples())
    }

#if DEBUG
    static func resetFullGravityLoadCountForTesting() {
        fullGravityInstrumentationLock.lock()
        fullGravityLoadCount = 0
        fullGravityInstrumentationLock.unlock()
    }

    static var fullGravityLoadCountForTesting: Int {
        fullGravityInstrumentationLock.lock()
        let count = fullGravityLoadCount
        fullGravityInstrumentationLock.unlock()
        return count
    }
#endif

    private static func motionWindowDiagnostics(start: Date,
                                                end: Date,
                                                records: [GravitySample]) -> MotionWindowDiagnostics {
        guard end > start else {
            return emptyMotionWindow(status: "learning", reason: "invalid_window")
        }
        let windowStart = start.timeIntervalSince1970
        let windowEnd = end.timeIntervalSince1970
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

    static func motionFeatureSummary(start: Date, end: Date) -> MotionFeatureSummary? {
        guard end > start else { return nil }
        let windowStart = start.timeIntervalSince1970
        let windowEnd = end.timeIntervalSince1970
        let overlapping = loadRecentGravitySamples(start: start, end: end)
            .filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.sequence < $1.sequence
            }
        guard overlapping.count >= 30 else { return nil }
        let validated = overlapping.filter(\.validated)
        var stillRows = 0
        var deltas: [Double] = []
        var previous: GravitySample?
        for sample in validated {
            let delta: Double
            if let previous {
                let dx = sample.x - previous.x
                let dy = sample.y - previous.y
                let dz = sample.z - previous.z
                delta = sqrt(dx * dx + dy * dy + dz * dz)
                deltas.append(delta)
            } else {
                delta = 0
            }
            if delta <= 0.05 {
                stillRows += 1
            }
            previous = sample
        }
        let movementIntensity = mean(deltas) ?? 0
        let timestamps = validated.map(\.timestamp)
        let gaps = zip(timestamps, timestamps.dropFirst()).map { max(0, $1 - $0) }
        let coverage = coverageSeconds(for: timestamps)
        let maximumGap = Int((gaps.max() ?? 0).rounded())
        let validatedRatio = Double(validated.count) / Double(overlapping.count)
        let ready = validated.count >= 300
            && validatedRatio >= 0.95
            && coverage >= 30 * 60
            && maximumGap <= 5 * 60
            && Double(stillRows) / Double(max(validated.count, 1)) >= 0.72
            && movementIntensity <= 0.18
        let reason: String
        if validated.count < 300 || coverage < 30 * 60 {
            reason = "bounded_recent_insufficient_overlap_coverage"
        } else if validatedRatio < 0.95 {
            reason = "bounded_recent_unvalidated_rows"
        } else if maximumGap > 5 * 60 {
            reason = "bounded_recent_internal_gap"
        } else if !ready {
            reason = "bounded_recent_motion_high"
        } else {
            reason = "bounded_recent_timestamp_aligned_low_motion"
        }
        return MotionFeatureSummary(stillnessRatio: Double(stillRows) / Double(max(validated.count, 1)),
                                    movementIntensity: movementIntensity,
                                    rows: overlapping.count,
                                    validatedRows: validated.count,
                                    coverageSeconds: coverage,
                                    maximumGapSeconds: maximumGap,
                                    firstUnix: Int((timestamps.first ?? 0).rounded()),
                                    lastUnix: Int((timestamps.last ?? 0).rounded()),
                                    reason: reason)
    }

    static func boundedMotionWindowDiagnostics(start: Date, end: Date) -> MotionWindowDiagnostics {
        guard let summary = motionFeatureSummary(start: start, end: end) else {
            return emptyMotionWindow(status: "missing", reason: "bounded_recent_no_overlap")
        }
        return MotionWindowDiagnostics(status: summary.lowMotionReady ? "ready" : "insufficient_motion",
                                       reason: summary.reason,
                                       rows: summary.rows,
                                       validatedRows: summary.validatedRows,
                                       coverageSeconds: summary.coverageSeconds,
                                       spanSeconds: max(0, Int(end.timeIntervalSince(start).rounded())),
                                       meanVectorDelta: summary.movementIntensity,
                                       p95VectorDelta: nil,
                                       magnitudeMean: nil,
                                       magnitudeStdDev: nil,
                                       archiveFirstUnix: summary.firstUnix,
                                       archiveLastUnix: summary.lastUnix,
                                       nearestSeparationSeconds: 0,
                                       lowMotionReady: summary.lowMotionReady)
    }

    static func metricHeartRatePoints(since: Date? = nil, limit: Int? = nil) -> [HeartRatePoint] {
        if since == nil, let limit {
            return loadRecentHeartRateSamples(limit: limit)
        }
        if let since {
            return loadRecentHeartRateSamples(since: since, limit: limit ?? 6_000)
        }
        return loadHeartRateSamples(since: since, limit: limit)
    }

    private static func appendJSONLine<T: Encodable>(_ value: T) throws -> URL {
        // Serialize with compactArchive/promoteMetricUsableRows: both rewrite the
        // base file wholesale; an unlocked append during that window would land
        // on the doomed inode and be silently destroyed by the swap.
        promotionLock.lock()
        defer { promotionLock.unlock() }
        let url = try writableFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let previousAttributes = archiveAttributes(for: url)
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
        updateDiagnosticsIndexAfterAppend(object: object,
                                          archiveURL: url,
                                          previousAttributes: previousAttributes)
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        return url
    }

    private static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var archiveDirectory: URL {
        documentsDirectory.appendingPathComponent("atria-historical", isDirectory: true)
    }

    private static var segmentsDirectory: URL {
        archiveDirectory.appendingPathComponent(segmentsDirectoryName, isDirectory: true)
    }

    private static func writableFileURL(now: Date = Date()) throws -> URL {
        let baseAttributes = archiveAttributes(for: fileURL)
        guard baseAttributes.byteCount >= rotationThresholdBytes else {
            return fileURL
        }
        let segmentURL = activeSegmentURL(for: now)
        try FileManager.default.createDirectory(at: segmentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try writeRotationManifest(activeSegmentURL: segmentURL, createdAt: now)
        return segmentURL
    }

    private static func activeSegmentURL(for date: Date = Date()) -> URL {
        segmentsDirectory.appendingPathComponent(activeSegmentFilename(for: date))
    }

    private static func activeSegmentFilename(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        return String(format: "historical-archive-%04d-%02d.jsonl", year, month)
    }

    private static func writeRotationManifest(activeSegmentURL: URL, createdAt: Date) throws {
        let manifest = RotationManifest(version: 1,
                                        baseRelativePath: relativePath,
                                        activeSegmentRelativePath: documentsRelativePath(for: activeSegmentURL),
                                        createdAt: createdAt,
                                        rotationThresholdBytes: rotationThresholdBytes)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: rotationManifestURL, options: .atomic)
    }

    private static func activeSegmentReadableURL() -> URL? {
        if let data = try? Data(contentsOf: rotationManifestURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let manifest = try? decoder.decode(RotationManifest.self, from: data) {
                let url = documentsDirectory.appendingPathComponent(manifest.activeSegmentRelativePath
                    .replacingOccurrences(of: "Documents/", with: ""))
                if FileManager.default.fileExists(atPath: url.path) {
                    return url
                }
            }
        }
        let currentMonth = activeSegmentURL()
        if FileManager.default.fileExists(atPath: currentMonth.path) {
            return currentMonth
        }
        return nil
    }

    private static func rotatedSegmentFileURLs() -> [URL] {
        guard let items = try? FileManager.default.contentsOfDirectory(at: segmentsDirectory,
                                                                       includingPropertiesForKeys: nil,
                                                                       options: [.skipsHiddenFiles]) else {
            return []
        }
        return items
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func recentReadableFileURLs() -> [URL] {
        var urls: [URL] = []
        if let activeSegment = activeSegmentReadableURL() {
            urls.append(activeSegment)
        }
        urls.append(readableFileURL)
        var seen = Set<String>()
        return urls.filter { url in
            guard FileManager.default.fileExists(atPath: url.path),
                  !seen.contains(url.path) else { return false }
            seen.insert(url.path)
            return true
        }
    }

    private static func documentsRelativePath(for url: URL) -> String {
        let documentsPath = documentsDirectory.path
        guard url.path.hasPrefix(documentsPath) else { return url.path }
        let suffix = url.path.dropFirst(documentsPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "Documents/\(suffix)"
    }

    private static func archiveAttributes(for url: URL) -> (byteCount: Int, modificationTime: TimeInterval) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modificationTime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (byteCount, modificationTime)
    }

    private static func diagnosticsIndexURL(for url: URL) -> URL? {
        if url == fileURL {
            return diagnosticsIndexURL
        }
        guard url.deletingLastPathComponent() == segmentsDirectory else { return nil }
        return url.deletingPathExtension().appendingPathExtension("diagnostics.json")
    }

    private static func readDiagnosticsIndex(for url: URL,
                                             attributes: (byteCount: Int, modificationTime: TimeInterval)) -> DiagnosticsIndex? {
        guard let indexURL = diagnosticsIndexURL(for: url),
              let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(DiagnosticsIndex.self, from: data),
              index.fileSize == attributes.byteCount,
              abs(index.modificationTime - attributes.modificationTime) < 0.001 else {
            return nil
        }
        return index
    }

    private static func writeDiagnosticsIndex(_ index: DiagnosticsIndex, for url: URL) {
        guard let indexURL = diagnosticsIndexURL(for: url) else { return }
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    private static func scanDiagnosticsIndex(for url: URL,
                                             attributes: (byteCount: Int, modificationTime: TimeInterval)) -> DiagnosticsIndex? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var index = DiagnosticsIndex(fileSize: attributes.byteCount,
                                     modificationTime: attributes.modificationTime,
                                     rows: 0,
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
                                     gravityValidatedRows: 0)
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            append(object: object, to: &index)
        }
        return index
    }

    private static func aggregateDiagnosticsIndex(base: DiagnosticsIndex,
                                                  segments: [DiagnosticsIndex]) -> DiagnosticsIndex {
        segments.reduce(base) { partial, segment in
            DiagnosticsIndex(fileSize: partial.fileSize + segment.fileSize,
                             modificationTime: max(partial.modificationTime, segment.modificationTime),
                             rows: partial.rows + segment.rows,
                             schemas: sortedUnion(partial.schemas, segment.schemas),
                             layoutVersions: sortedUnion(partial.layoutVersions, segment.layoutVersions),
                             metricUsableRows: partial.metricUsableRows + segment.metricUsableRows,
                             currentSessionUsableRows: partial.currentSessionUsableRows + segment.currentSessionUsableRows,
                             undecodableRows: partial.undecodableRows + segment.undecodableRows,
                             rawPayloadRows: partial.rawPayloadRows + segment.rawPayloadRows,
                             unixFirst: minOptional(partial.unixFirst, segment.unixFirst),
                             unixLast: maxOptional(partial.unixLast, segment.unixLast),
                             correctedUnixFirst: minOptional(partial.correctedUnixFirst, segment.correctedUnixFirst),
                             correctedUnixLast: maxOptional(partial.correctedUnixLast, segment.correctedUnixLast),
                             gravityRows: partial.gravityRows + segment.gravityRows,
                             gravityValidatedRows: partial.gravityValidatedRows + segment.gravityValidatedRows)
        }
    }

    private static func diagnostics(from index: DiagnosticsIndex, reason: String) -> Diagnostics {
        Diagnostics(exists: true,
                    parseOK: true,
                    rows: index.rows,
                    bytes: index.fileSize,
                    schemas: index.schemas,
                    layoutVersions: index.layoutVersions,
                    metricUsableRows: index.metricUsableRows,
                    currentSessionUsableRows: index.currentSessionUsableRows,
                    undecodableRows: index.undecodableRows,
                    rawPayloadRows: index.rawPayloadRows,
                    unixFirst: index.unixFirst,
                    unixLast: index.unixLast,
                    correctedUnixFirst: index.correctedUnixFirst,
                    correctedUnixLast: index.correctedUnixLast,
                    gravityRows: index.gravityRows,
                    gravityValidatedRows: index.gravityValidatedRows,
                    reason: reason)
    }

    private static func updateDiagnosticsIndexAfterAppend(object: [String: Any]?,
                                                          archiveURL: URL,
                                                          previousAttributes: (byteCount: Int, modificationTime: TimeInterval)) {
        guard let indexURL = diagnosticsIndexURL(for: archiveURL) else { return }
        let attributes = archiveAttributes(for: archiveURL)
        diagnosticsIndexLock.lock()
        defer { diagnosticsIndexLock.unlock() }
        guard let object else {
            try? FileManager.default.removeItem(at: indexURL)
            return
        }
        let existingIndex: DiagnosticsIndex?
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(DiagnosticsIndex.self, from: data),
           decoded.fileSize == previousAttributes.byteCount,
           abs(decoded.modificationTime - previousAttributes.modificationTime) < 0.001 {
            existingIndex = decoded
        } else if previousAttributes.byteCount == 0 {
            existingIndex = DiagnosticsIndex(fileSize: 0,
                                             modificationTime: previousAttributes.modificationTime,
                                             rows: 0,
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
                                             gravityValidatedRows: 0)
        } else {
            try? FileManager.default.removeItem(at: indexURL)
            return
        }
        guard var index = existingIndex else { return }
        append(object: object, to: &index)
        index.fileSize = attributes.byteCount
        index.modificationTime = attributes.modificationTime
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: indexURL)
        }
    }

    private static func append(object: [String: Any], to index: inout DiagnosticsIndex) {
        index.rows += 1
        if let schema = object["schema"] {
            index.schemas = sortedUnion(index.schemas, String(describing: schema))
        } else {
            index.schemas = sortedUnion(index.schemas, "missing")
        }
        if let layout = object["layoutVersion"] as? String, !layout.isEmpty {
            index.layoutVersions = sortedUnion(index.layoutVersions, layout)
        } else {
            index.layoutVersions = sortedUnion(index.layoutVersions, "undecodable")
            if object["source"] as? String == "0x2f" {
                index.undecodableRows += 1
            }
        }
        if metricUsable(object: object) {
            index.metricUsableRows += 1
        }
        if object["currentSessionUsable"] as? Bool == true || currentSessionUsable(object: object) {
            index.currentSessionUsableRows += 1
        }
        if let rawPayload = object["rawPayloadHex"] as? String, !rawPayload.isEmpty {
            index.rawPayloadRows += 1
            if let payload = bytes(fromHex: rawPayload),
               let gravity = historicalGravity(payload) {
                index.gravityRows += 1
                if gravity.validated {
                    index.gravityValidatedRows += 1
                }
            }
        }
        if let unixNumber = object["unix7"] as? NSNumber {
            let value = unixNumber.uint32Value
            if value > 0 {
                index.unixFirst = min(index.unixFirst ?? value, value)
                index.unixLast = max(index.unixLast ?? value, value)
            }
        }
        if let correctedNumber = object["clockCorrectedUnix7"] as? NSNumber {
            let value = correctedNumber.uint32Value
            if value > 0 {
                index.correctedUnixFirst = min(index.correctedUnixFirst ?? value, value)
                index.correctedUnixLast = max(index.correctedUnixLast ?? value, value)
            }
        }
    }

    private static func sortedUnion(_ values: [String], _ newValue: String) -> [String] {
        var set = Set(values)
        set.insert(newValue)
        return Array(set).sorted()
    }

    private static func sortedUnion(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs).union(rhs)).sorted()
    }

    private static func minOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return min(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    private static func maxOptional<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            return max(lhs, rhs)
        case let (lhs?, nil):
            return lhs
        case let (nil, rhs?):
            return rhs
        case (nil, nil):
            return nil
        }
    }

    fileprivate struct GravitySample {
        let timestamp: TimeInterval
        let sequence: Int
        let x: Double
        let y: Double
        let z: Double
        let magnitude: Double
        let validated: Bool
    }

    private struct RecentGravityCache {
        let loadedAt: Date
        let targetBytes: UInt64
        let samples: [GravitySample]
        let latestTimestamp: TimeInterval?
    }

    private struct GravityRecord {
        let record: Record
        let unix: UInt32
        let gravity: (x: Double, y: Double, z: Double, magnitude: Double, validated: Bool)
    }

    private static func loadGravitySamples() -> [GravitySample] {
#if DEBUG
        fullGravityInstrumentationLock.lock()
        fullGravityLoadCount += 1
        fullGravityInstrumentationLock.unlock()
#endif
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return gravitySamples(from: content)
    }

    private static func loadRecentGravitySamples(start: Date, end: Date) -> [GravitySample] {
        guard end > start else { return [] }
        let spanSeconds = max(1, end.timeIntervalSince(start))
        let estimatedRows = Int((spanSeconds / 2.0).rounded(.up)) + 720
        let targetBytes = UInt64(max(4_194_304, min(33_554_432, estimatedRows * 1_024)))

        recentGravityCacheLock.lock()
        if let cache = recentGravityCache,
           cache.targetBytes >= targetBytes,
           recentGravityCacheCovers(cache, end: end) {
            let samples = cache.samples
            recentGravityCacheLock.unlock()
            return samples
        }
        if recentGravityLoadInFlight {
            recentGravityCacheLock.unlock()
            return []
        }
        recentGravityLoadInFlight = true
        recentGravityCacheLock.unlock()

        // Never decode archive JSON from a UI update. Main-thread callers fail
        // closed for this pass while a single utility task prepares the cache.
        if Thread.isMainThread {
            DispatchQueue.global(qos: .utility).async {
                let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
                publishRecentGravityCache(samples: samples, targetBytes: targetBytes)
            }
            return []
        }

        let samples = loadRecentGravitySamplesUncached(targetBytes: targetBytes)
        publishRecentGravityCache(samples: samples, targetBytes: targetBytes)
        return samples
    }

    private static func recentGravityCacheCovers(_ cache: RecentGravityCache, end: Date) -> Bool {
        if cache.samples.isEmpty {
            return Date().timeIntervalSince(cache.loadedAt) < 60
        }
        guard let latestTimestamp = cache.latestTimestamp else { return false }
        // A small tolerance covers the normal archive write/clock cadence. A
        // newer live window triggers a refresh and remains unvalidated until it
        // lands, rather than trusting stale motion evidence.
        return latestTimestamp >= end.timeIntervalSince1970 - 120
    }

    private static func publishRecentGravityCache(samples: [GravitySample], targetBytes: UInt64) {
        recentGravityCacheLock.lock()
        recentGravityCache = RecentGravityCache(loadedAt: Date(),
                                                targetBytes: targetBytes,
                                                samples: samples,
                                                latestTimestamp: samples.last?.timestamp)
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()
    }

#if DEBUG
    static func resetRecentGravityCacheForTesting() {
        recentGravityCacheLock.lock()
        recentGravityCache = nil
        recentGravityLoadInFlight = false
        recentGravityCacheLock.unlock()
    }
#endif

    private static func loadRecentGravitySamplesUncached(targetBytes: UInt64) -> [GravitySample] {
        var samples: [GravitySample] = []
        for url in recentReadableFileURLs().reversed() {
            guard let content = tailContent(from: url, targetBytes: targetBytes) else { continue }
            samples.append(contentsOf: gravitySamples(from: content))
        }
        return samples.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.sequence < rhs.sequence
        }
    }

    private static func gravitySamples(from content: String) -> [GravitySample] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [GravityRecord] = []
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let record = try? decoder.decode(Record.self, from: data) else { continue }
            let unix = record.clockCorrectedUnix7 ?? record.unix7
            guard unix > 0,
                  let payload = bytes(fromHex: record.rawPayloadHex),
                  let gravity = historicalGravity(payload) else { continue }
            records.append(GravityRecord(record: record, unix: unix, gravity: gravity))
        }

        let currentUsable = records.filter(\.record.currentSessionUsable)
        let currentAnchor = currentUsable.max { lhs, rhs in
            if lhs.record.capturedAt != rhs.record.capturedAt {
                return lhs.record.capturedAt < rhs.record.capturedAt
            }
            return lhs.unix < rhs.unix
        }

        var samples: [GravitySample] = []
        samples.reserveCapacity(records.count)
        for item in records {
            let timestamp: TimeInterval
            if item.record.currentSessionUsable,
               let anchor = currentAnchor,
               abs(item.record.capturedAt.timeIntervalSince1970 - TimeInterval(item.unix)) > 12 * 60 * 60 {
                timestamp = anchor.record.capturedAt.timeIntervalSince1970
                    - TimeInterval(Int64(anchor.unix) - Int64(item.unix))
            } else {
                timestamp = TimeInterval(item.unix)
            }
            samples.append(GravitySample(timestamp: timestamp,
                                         sequence: item.record.sequence,
                                         x: item.gravity.x,
                                         y: item.gravity.y,
                                         z: item.gravity.z,
                                         magnitude: item.gravity.magnitude,
                                         validated: item.gravity.validated))
        }
        return samples
    }

    private struct HeartRateArchiveRow {
        let capturedAt: TimeInterval
        let unix: UInt32
        let sequence: Int
        let bpm: Int
        let currentSessionUsable: Bool
    }

    private static func loadHeartRateSamples(since: Date?, limit: Int?) -> [HeartRatePoint] {
        let url = readableFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var records: [HeartRateArchiveRow] = []
        records.reserveCapacity(min(content.split(whereSeparator: \.isNewline).count, limit ?? Int.max))
        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  metricUsable(object: object),
                  let bpmNumber = object["whoofHR17"] as? NSNumber else { continue }
            let bpm = bpmNumber.intValue
            guard (35...240).contains(bpm) else { continue }
            let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value
            let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value
            guard let unix = correctedUnix ?? rawUnix, unix > 0 else { continue }
            let capturedAt = (object["capturedAt"] as? String).flatMap(Self.iso8601TimeInterval(from:))
                ?? TimeInterval(unix)
            records.append(HeartRateArchiveRow(capturedAt: capturedAt,
                                               unix: unix,
                                               sequence: (object["sequence"] as? NSNumber)?.intValue ?? 0,
                                               bpm: bpm,
                                               currentSessionUsable: currentSessionUsable(object: object)))
        }

        let currentUsable = records.filter(\.currentSessionUsable)
        let currentAnchor = currentUsable.max { lhs, rhs in
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt < rhs.capturedAt
            }
            return lhs.unix < rhs.unix
        }
        let lowerBound = since?.timeIntervalSince1970 ?? 0
        var points: [HeartRatePoint] = []
        points.reserveCapacity(min(records.count, limit ?? records.count))
        for item in records {
            let timestamp: TimeInterval
            if item.currentSessionUsable,
               let anchor = currentAnchor,
               abs(item.capturedAt - TimeInterval(item.unix)) > 12 * 60 * 60 {
                timestamp = anchor.capturedAt
                    - TimeInterval(Int64(anchor.unix) - Int64(item.unix))
            } else {
                timestamp = TimeInterval(item.unix)
            }
            guard timestamp >= lowerBound else { continue }
            points.append(HeartRatePoint(t: Date(timeIntervalSince1970: timestamp),
                                         bpm: item.bpm))
        }
        let sorted = points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }
        guard let limit, sorted.count > limit else { return sorted }
        return Array(sorted.suffix(limit))
    }

    private static func loadRecentHeartRateSamples(limit: Int) -> [HeartRatePoint] {
        guard limit > 0 else { return [] }
        let targetBytes = UInt64(max(1_048_576, min(16_777_216, limit * 768)))
        var points: [HeartRatePoint] = []
        points.reserveCapacity(limit)
        for url in recentReadableFileURLs() {
            if points.count >= limit { break }
            guard let content = tailContent(from: url, targetBytes: targetBytes) else { continue }
            for rawLine in content.split(whereSeparator: \.isNewline).reversed() {
                if points.count >= limit { break }
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let point = fastHeartRatePoint(from: line) else { continue }
                points.append(point)
            }
        }
        return Array(points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }.suffix(limit))
    }

    private static func loadRecentHeartRateSamples(since: Date, limit: Int) -> [HeartRatePoint] {
        guard limit > 0 else { return [] }
        let lowerBound = since.timeIntervalSince1970
        let targetBytes = UInt64(max(4_194_304, min(33_554_432, limit * 1_024)))
        var points: [HeartRatePoint] = []
        points.reserveCapacity(limit)
        for url in recentReadableFileURLs() {
            if points.count >= limit { break }
            guard let content = tailContent(from: url, targetBytes: targetBytes) else { continue }
            for rawLine in content.split(whereSeparator: \.isNewline).reversed() {
                if points.count >= limit { break }
                let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let point = fastHeartRatePoint(from: line),
                      point.t.timeIntervalSince1970 >= lowerBound else { continue }
                points.append(point)
            }
        }
        return Array(points.sorted { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t < rhs.t }
            return lhs.bpm < rhs.bpm
        }.suffix(limit))
    }

    private static func tailContent(from url: URL, targetBytes: UInt64) -> String? {
        guard FileManager.default.fileExists(atPath: url.path),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        let startOffset = fileSize > targetBytes ? fileSize - targetBytes : 0
        try? handle.seek(toOffset: startOffset)
        let data = handle.readDataToEndOfFile()
        guard var content = String(data: data, encoding: .utf8), !content.isEmpty else { return nil }
        if startOffset > 0, let firstNewline = content.firstIndex(where: \.isNewline) {
            content.removeSubrange(content.startIndex...firstNewline)
        }
        return content
    }

    private static func fastHeartRatePoint(from line: String) -> HeartRatePoint? {
        guard !line.isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              metricUsable(object: object),
              let bpmNumber = object["whoofHR17"] as? NSNumber else { return nil }
        let bpm = bpmNumber.intValue
        guard (35...240).contains(bpm) else { return nil }
        let correctedUnix = (object["clockCorrectedUnix7"] as? NSNumber)?.uint32Value
        let rawUnix = (object["unix7"] as? NSNumber)?.uint32Value
        let unix = correctedUnix ?? rawUnix
        let capturedAt = (object["capturedAt"] as? String).flatMap(Self.iso8601TimeInterval(from:))
        let timestamp: TimeInterval
        if currentSessionUsable(object: object),
           let capturedAt,
           let unix,
           abs(capturedAt - TimeInterval(unix)) > 12 * 60 * 60 {
            timestamp = capturedAt
        } else if let unix, unix > 0 {
            timestamp = TimeInterval(unix)
        } else if let capturedAt {
            timestamp = capturedAt
        } else {
            return nil
        }
        return HeartRatePoint(t: Date(timeIntervalSince1970: timestamp), bpm: bpm)
    }

    private static func iso8601TimeInterval(from raw: String) -> TimeInterval? {
        archiveDateFormatter.date(from: raw)?.timeIntervalSince1970
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

    // MARK: - Archive compaction (docs/24 §14.1 step 2)
    //
    // Streams the BASE aggregate file once: rows whose timestamps (BOTH the
    // strap-clock anchored time AND the wall-clock capture time) are older than
    // the cutoff — and that fall outside every pinned confirmed-sleep/workout
    // window — are folded into per-minute summary rows; everything else is kept
    // raw. Order: write summaries, write the kept-raw temp file, VERIFY it,
    // atomically swap, then drop the stale diagnostics sidecar. Appends never
    // race this rewrite (at >=128 MiB they already go to the rotated segment);
    // promoteMetricUsableRows is serialized via promotionLock. Hard invariant:
    // the kept set must retain metricUsable AND currentSessionUsable rows, or
    // the compaction ABORTS — the metric-ready greens may never regress.

    static let minuteSummarySchema = 1

    struct MinuteSummary: Codable {
        let schema: Int
        /// Anchored (strap-clock corrected) minute start, unix seconds.
        let minuteStart: Int
        let samples: Int
        let minHR: Int
        let maxHR: Int
        let hrSum: Int
        let rrCount: Int
        let gravitySamples: Int
        let metricUsableSamples: Int
    }

    struct CompactionResult {
        let status: String
        let scannedRows: Int
        let keptRows: Int
        let compactedRows: Int
        let summaryRows: Int
        let bytesBefore: Int
        let bytesAfter: Int
    }

    private static func minuteSummariesURL(forAnchoredMonth date: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: date)
        let name = String(format: "minutes-%04d-%02d.jsonl", components.year ?? 0, components.month ?? 0)
        return fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func compactArchive(olderThanDays: Int = 30,
                               pinnedWindows: [(start: Date, end: Date)],
                               reason: String,
                               now: Date = Date()) -> CompactionResult {
        promotionLock.lock()
        defer { promotionLock.unlock() }

        let sourceURL = fileURL
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return CompactionResult(status: "skipped_no_base_file", scannedRows: 0, keptRows: 0,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: 0, bytesAfter: 0)
        }
        let bytesBefore = archiveAttributes(for: sourceURL).byteCount
        let cutoff = now.addingTimeInterval(-TimeInterval(olderThanDays) * 24 * 60 * 60)
        let pinPadding: TimeInterval = 24 * 60 * 60
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        func isPinned(_ instant: Date) -> Bool {
            pinnedWindows.contains { window in
                instant >= window.start.addingTimeInterval(-pinPadding)
                    && instant <= window.end.addingTimeInterval(pinPadding)
            }
        }

        let tempURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("historical-archive.compacting.jsonl")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        guard let keepHandle = try? FileHandle(forWritingTo: tempURL),
              let stream = InputStream(url: sourceURL) else {
            return CompactionResult(status: "failed_io_setup", scannedRows: 0, keptRows: 0,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        stream.open()
        defer { stream.close() }

        var scanned = 0
        var kept = 0
        var compacted = 0
        var keptMetricUsable = 0
        var keptCurrentUsable = 0
        var minuteBuckets: [Int: (samples: Int, minHR: Int, maxHR: Int, hrSum: Int, rrCount: Int, gravity: Int, metric: Int)] = [:]
        var carry = Data()
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var failed = false

        func processLine(_ lineData: Data) {
            guard !lineData.isEmpty else { return }
            scanned += 1
            func keepRaw() {
                keepHandle.write(lineData)
                keepHandle.write(Data([0x0a]))
                kept += 1
            }
            guard let record = try? decoder.decode(Record.self, from: lineData) else {
                // Undecodable frames and unknown shapes stay raw — they are rare
                // and this compactor must never destroy what it cannot summarize.
                keepRaw()
                return
            }
            let anchoredUnix = TimeInterval(record.clockCorrectedUnix7 ?? record.unix7)
            let anchoredDate = Date(timeIntervalSince1970: anchoredUnix)
            let isOldByBothClocks = anchoredDate < cutoff && record.capturedAt < cutoff
            if !isOldByBothClocks || isPinned(anchoredDate) || isPinned(record.capturedAt) {
                if record.metricUsable { keptMetricUsable += 1 }
                if record.currentSessionUsable { keptCurrentUsable += 1 }
                keepRaw()
                return
            }
            compacted += 1
            let minute = Int(anchoredUnix) / 60 * 60
            var bucket = minuteBuckets[minute] ?? (0, Int.max, 0, 0, 0, 0, 0)
            bucket.samples += 1
            if record.whoofHR17 > 0 {
                bucket.minHR = Swift.min(bucket.minHR, record.whoofHR17)
                bucket.maxHR = Swift.max(bucket.maxHR, record.whoofHR17)
                bucket.hrSum += record.whoofHR17
            }
            bucket.rrCount += record.whoofRR19.count
            if record.gravityValidated { bucket.gravity += 1 }
            if record.metricUsable { bucket.metric += 1 }
            minuteBuckets[minute] = bucket
        }

        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            guard read >= 0 else { failed = true; break }
            if read == 0 { break }
            carry.append(contentsOf: buffer[0..<read])
            while let newline = carry.firstIndex(of: 0x0a) {
                processLine(carry.subdata(in: carry.startIndex..<newline))
                carry.removeSubrange(carry.startIndex...newline)
            }
        }
        if !failed, !carry.isEmpty {
            processLine(carry)
        }
        try? keepHandle.close()

        guard !failed else {
            try? FileManager.default.removeItem(at: tempURL)
            return CompactionResult(status: "failed_stream_read", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        guard compacted > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            return CompactionResult(status: "noop_nothing_to_compact", scannedRows: scanned, keptRows: kept,
                                    compactedRows: 0, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Green invariant: never leave the base file without usable raw rows.
        guard keptMetricUsable > 0, keptCurrentUsable > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=aborted reason=green_invariant kept_metric_usable=%d kept_current_usable=%d",
                          keptMetricUsable,
                          keptCurrentUsable)
            return CompactionResult(status: "aborted_green_invariant", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Verify the kept file parses to the expected row count before swap.
        let verified = quickRowCount(at: tempURL)
        guard verified == kept else {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=aborted reason=verify_mismatch expected=%d actual=%d",
                          kept,
                          verified)
            return CompactionResult(status: "aborted_verify_mismatch", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: 0, bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }

        // Summaries FIRST (so a crash after summary-write but before swap only
        // duplicates summaries, never loses raw), then the atomic swap.
        var summaryRows = 0
        let encoder = JSONEncoder()
        var summariesByURL: [URL: Data] = [:]
        for (minute, bucket) in minuteBuckets.sorted(by: { $0.key < $1.key }) {
            let summary = MinuteSummary(schema: minuteSummarySchema,
                                        minuteStart: minute,
                                        samples: bucket.samples,
                                        minHR: bucket.minHR == Int.max ? 0 : bucket.minHR,
                                        maxHR: bucket.maxHR,
                                        hrSum: bucket.hrSum,
                                        rrCount: bucket.rrCount,
                                        gravitySamples: bucket.gravity,
                                        metricUsableSamples: bucket.metric)
            guard let data = try? encoder.encode(summary) else { continue }
            let url = minuteSummariesURL(forAnchoredMonth: Date(timeIntervalSince1970: TimeInterval(minute)))
            summariesByURL[url, default: Data()].append(data)
            summariesByURL[url]?.append(0x0a)
            summaryRows += 1
        }
        for (url, data) in summariesByURL {
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }

        do {
            _ = try FileManager.default.replaceItemAt(sourceURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            AtriaDebugLog("ATRIADBG archive_compaction status=failed reason=swap error=%@",
                          error.localizedDescription)
            return CompactionResult(status: "failed_swap", scannedRows: scanned, keptRows: kept,
                                    compactedRows: compacted, summaryRows: summaryRows,
                                    bytesBefore: bytesBefore, bytesAfter: bytesBefore)
        }
        // Stale sidecar would zero the diagnostics via its fileSize+mtime key;
        // remove it so readers rebuild an index for the new file.
        if let sidecarURL = diagnosticsIndexURL(for: sourceURL) {
            try? FileManager.default.removeItem(at: sidecarURL)
        }
        NotificationCenter.default.post(name: didUpdateNotification, object: nil)
        let bytesAfter = archiveAttributes(for: sourceURL).byteCount
        AtriaDebugLog("ATRIADBG archive_compaction status=ok reason=%@ scanned=%d kept=%d compacted=%d summary_rows=%d bytes_before=%d bytes_after=%d kept_metric_usable=%d kept_current_usable=%d",
                      reason,
                      scanned,
                      kept,
                      compacted,
                      summaryRows,
                      bytesBefore,
                      bytesAfter,
                      keptMetricUsable,
                      keptCurrentUsable)
        return CompactionResult(status: "ok", scannedRows: scanned, keptRows: kept,
                                compactedRows: compacted, summaryRows: summaryRows,
                                bytesBefore: bytesBefore, bytesAfter: bytesAfter)
    }

    private static func quickRowCount(at url: URL) -> Int {
        guard let stream = InputStream(url: url) else { return -1 }
        stream.open()
        defer { stream.close() }
        var count = 0
        let chunkSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var lastByte: UInt8 = 0x0a
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: chunkSize)
            guard read > 0 else { break }
            for index in 0..<read where buffer[index] == 0x0a {
                count += 1
            }
            lastByte = buffer[read - 1]
        }
        if lastByte != 0x0a { count += 1 }
        return count
    }

}

enum AtriaHistoricalGravity {
    static func decode(payload: [UInt8], version: Int? = nil) -> (x: Double, y: Double, z: Double, magnitude: Double, validated: Bool)? {
        HistoricalArchive.historicalGravity(payload)
    }
}
