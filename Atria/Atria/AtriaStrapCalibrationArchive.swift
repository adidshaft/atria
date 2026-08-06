import Foundation

/// A bounded, local-only archive of validated strap motion frames used to
/// calibrate the research step decoder against manually counted walks.
final class AtriaStrapCalibrationArchive: @unchecked Sendable {
    static let schemaVersion = 2
    static let enableArgument = "--atria-enable-step-calibration"
    static let disableArgument = "--atria-disable-step-calibration"
    static let captureUntilDefaultsKey = "atria.strapStepCalibration.captureUntil"
    /// A calibration is an attended controlled walk, not a week-long radio
    /// mode. Raw evidence remains retained for seven days.
    static let defaultArmDuration: TimeInterval = 30 * 60
    static let defaultCaptureDuration: TimeInterval = 7 * 24 * 60 * 60

    private struct PendingRow {
        let receivedAt: Date
        let source: String
        let frame: Data

        var estimatedBytes: Int { frame.count * 2 + source.utf8.count + 48 }
    }

    struct CaptureQuality: Equatable, Sendable {
        let decodedFrames: Int
        let durationMS: Int64
        let coveragePercent: Double
        let continuityBreaks: Int
        let maximumUncoveredGapMS: Int64
        let alignedStartMS: Int64?
        let alignedEndMSExclusive: Int64?

        var isReady: Bool {
            decodedFrames > 0
                && coveragePercent >= 95
                && continuityBreaks == 0
                && maximumUncoveredGapMS < 1_000
        }

        var failureSummary: String {
            if decodedFrames == 0 { return "No strap motion was captured. Repeat this stage." }
            if coveragePercent < 95 {
                return String(format: "Only %.0f%% of strap motion was captured. Repeat this stage.",
                              coveragePercent)
            }
            if continuityBreaks > 0 || maximumUncoveredGapMS >= 1_000 {
                return "The motion stream had a gap. Repeat this stage."
            }
            return "Stage ready"
        }
    }

    static let shared: AtriaStrapCalibrationArchive = {
        let fileManager = FileManager.default
        let root = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return AtriaStrapCalibrationArchive(
            directoryURL: root.appendingPathComponent("atria-step-calibration", isDirectory: true)
        )
    }()

    private let directoryURL: URL
    private let fileManager: FileManager
    private let flushInterval: TimeInterval
    private let maximumBufferedBytes: Int
    private let retentionInterval: TimeInterval
    private let maximumArchiveBytes: Int64
    private let maximumFileBytes: Int64
    private let archivePruneInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.adidshaft.atria.step-calibration", qos: .utility)
    private let launchID = UUID().uuidString.prefix(8).lowercased()

    private var pendingRows: [PendingRow] = []
    private var pendingBytes = 0
    private var flushScheduled = false
    private var currentDayKey: String?
    private var currentFileURL: URL?
    private var currentFileHandle: FileHandle?
    private var recentR10DeviceTimestampsMS: [Int64] = []
    private var lastArchivePruneAt: Date?
    private let recentTimestampRetentionMS: Int64 = 2 * 60 * 60 * 1_000
    private let maximumRecentTimestampCount = 10_000

    init(directoryURL: URL,
         fileManager: FileManager = .default,
         flushInterval: TimeInterval = 2,
         maximumBufferedBytes: Int = 128 * 1_024,
         retentionInterval: TimeInterval = defaultCaptureDuration,
         maximumArchiveBytes: Int64 = 96 * 1_024 * 1_024,
         archivePruneInterval: TimeInterval = 15 * 60) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        self.flushInterval = max(0.05, flushInterval)
        self.maximumBufferedBytes = max(1_024, maximumBufferedBytes)
        self.retentionInterval = max(60, retentionInterval)
        self.maximumArchiveBytes = max(1_024 * 1_024, maximumArchiveBytes)
        self.archivePruneInterval = max(60, archivePruneInterval)
        self.maximumFileBytes = max(1_024 * 1_024,
                                    min(32 * 1_024 * 1_024, self.maximumArchiveBytes / 3))
    }

    static func configuredCaptureUntil(arguments: [String],
                                       defaults: UserDefaults = .standard,
                                       now: Date = Date(),
                                       duration: TimeInterval = defaultArmDuration) -> Date? {
        if arguments.contains(disableArgument) {
            defaults.removeObject(forKey: captureUntilDefaultsKey)
            return nil
        }
        if arguments.contains(enableArgument) {
            let until = now.addingTimeInterval(max(60, duration))
            defaults.set(until.timeIntervalSince1970, forKey: captureUntilDefaultsKey)
            return until
        }
        let stored = defaults.double(forKey: captureUntilDefaultsKey)
        guard stored > now.timeIntervalSince1970 else {
            defaults.removeObject(forKey: captureUntilDefaultsKey)
            return nil
        }
        // Builds before the attended-calibration gate persisted a seven-day
        // radio lease. Never inherit that legacy authority into a new launch:
        // raw evidence may remain for seven days, but motion capture itself is
        // intentionally bounded to one attended calibration window.
        guard stored - now.timeIntervalSince1970 <= max(60, duration) else {
            defaults.removeObject(forKey: captureUntilDefaultsKey)
            return nil
        }
        return Date(timeIntervalSince1970: stored)
    }

    /// Enforces age/byte retention even after calibration capture has ended.
    /// Previously pruning only ran while another frame was being written, so
    /// an inactive archive could occupy its full research allowance forever.
    func scheduleRetentionPrune(now: Date = Date()) {
        queue.async { [weak self] in
            self?.pruneArchiveLocked(now: now, force: true)
        }
    }

    /// Test-only synchronization seam for the maintenance path. Production
    /// callers must use `scheduleRetentionPrune` so pruning never blocks the
    /// foreground or the live motion writer.
    func pruneSynchronouslyForTesting(now: Date) {
        queue.sync { [self] in
            pruneArchiveLocked(now: now, force: true)
        }
    }

    /// Validates framing and CRC, then returns a motion-bearing WHOOP 4 frame.
    /// R10 (0x2B/0x0A) is the observed high-rate stream; 0x33 remains accepted
    /// for firmware variants that expose the smaller realtime IMU packet.
    static func canonicalValidatedMotionFrame(from data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 9, bytes[0] == 0xAA else { return nil }
        let declaredLength = Int(bytes[1]) | (Int(bytes[2]) << 8)
        let frameLength = declaredLength + 4
        guard declaredLength >= 5,
              frameLength <= bytes.count,
              bytes[3] == crc8([bytes[1], bytes[2]]) else { return nil }
        let payload = Array(bytes[4..<declaredLength])
        let isR10 = payload.count >= 2 && payload[0] == 0x2B && payload[1] == 0x0A
        guard isR10 || payload.first == 0x33 else { return nil }
        let expectedCRC = crc32(payload)
        let actualCRC = UInt32(bytes[declaredLength])
            | (UInt32(bytes[declaredLength + 1]) << 8)
            | (UInt32(bytes[declaredLength + 2]) << 16)
            | (UInt32(bytes[declaredLength + 3]) << 24)
        guard expectedCRC == actualCRC else { return nil }
        return Data(bytes[0..<frameLength])
    }

    func recordMotionFrame(_ data: Data, source: String, receivedAt: Date = Date()) {
        guard let frame = Self.canonicalValidatedMotionFrame(from: data) else { return }
        recordValidatedMotionFrame(frame, source: source, receivedAt: receivedAt)
    }

    /// The BLE parser has already checked framing and CRC before this path.
    func recordValidatedMotionFrame(_ frame: Data, source: String, receivedAt: Date) {
        let row = PendingRow(receivedAt: receivedAt,
                             source: Self.sanitizedSource(source),
                             frame: frame)
        let deviceTimestampMS = AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: frame).flatMap {
            $0 > 0 ? Int64($0) * 1_000 : nil
        }
        queue.async { [self] in
            pendingRows.append(row)
            pendingBytes += row.estimatedBytes
            if let deviceTimestampMS {
                recentR10DeviceTimestampsMS.append(deviceTimestampMS)
                pruneRecentTimestampsLocked(latestMS: deviceTimestampMS)
            }
            scheduleFlushLocked()
            if pendingBytes >= maximumBufferedBytes {
                flushLocked()
            }
        }
    }

    func flush() {
        queue.async { [self] in
            flushLocked()
            synchronizeCurrentFileLocked()
        }
    }

    func flushSynchronouslyForTesting() {
        queue.sync { [self] in
            flushLocked()
            synchronizeCurrentFileLocked()
        }
    }

    func closeSynchronouslyForTesting() {
        queue.sync { [self] in
            flushLocked()
            closeCurrentFileLocked()
        }
    }

    /// Flushes the exact raw rows first, then verifies that the selected wall-
    /// clock window has a continuous one-frame-per-second R10 record. The
    /// in-memory timestamp index is intentionally bounded and session-local;
    /// after a process interruption the current stage must be repeated rather
    /// than guessing quality from incomplete state.
    func captureQuality(startMS: Int64, endMS: Int64) -> CaptureQuality {
        queue.sync { [self] in
            flushLocked()
            synchronizeCurrentFileLocked()
            guard endMS > startMS else {
                return CaptureQuality(decodedFrames: 0,
                                      durationMS: 0,
                                      coveragePercent: 0,
                                      continuityBreaks: 0,
                                      maximumUncoveredGapMS: 0,
                                      alignedStartMS: nil,
                                      alignedEndMSExclusive: nil)
            }
            let timestamps = Array(Set(recentR10DeviceTimestampsMS.filter {
                $0 >= startMS && $0 < endMS
            })).sorted()
            let durationMS = endMS - startMS
            let expectedFrames = max(1.0, Double(durationMS) / 1_000)
            let coverage = min(100, Double(timestamps.count) / expectedFrames * 100)
            guard let first = timestamps.first, let last = timestamps.last else {
                return CaptureQuality(decodedFrames: 0,
                                      durationMS: durationMS,
                                      coveragePercent: 0,
                                      continuityBreaks: 0,
                                      maximumUncoveredGapMS: durationMS,
                                      alignedStartMS: nil,
                                      alignedEndMSExclusive: nil)
            }
            var continuityBreaks = 0
            var maximumGap = max(0, first - startMS)
            for (previous, current) in zip(timestamps, timestamps.dropFirst()) {
                let uncovered = max(0, current - previous - 1_000)
                maximumGap = max(maximumGap, uncovered)
                if current - previous > 1_500 { continuityBreaks += 1 }
            }
            maximumGap = max(maximumGap, max(0, endMS - (last + 1_000)))
            return CaptureQuality(decodedFrames: timestamps.count,
                                  durationMS: durationMS,
                                  coveragePercent: coverage,
                                  continuityBreaks: continuityBreaks,
                                  maximumUncoveredGapMS: maximumGap,
                                  alignedStartMS: first,
                                  alignedEndMSExclusive: last + 1_000)
        }
    }

    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushLocked()
        }
    }

    private func pruneRecentTimestampsLocked(latestMS: Int64) {
        let cutoff = latestMS - recentTimestampRetentionMS
        if let firstRetained = recentR10DeviceTimestampsMS.firstIndex(where: { $0 >= cutoff }),
           firstRetained > 0 {
            recentR10DeviceTimestampsMS.removeFirst(firstRetained)
        }
        if recentR10DeviceTimestampsMS.count > maximumRecentTimestampCount {
            recentR10DeviceTimestampsMS.removeFirst(
                recentR10DeviceTimestampsMS.count - maximumRecentTimestampCount
            )
        }
    }

    private func flushLocked() {
        guard !pendingRows.isEmpty else { return }
        let rows = pendingRows
        pendingRows.removeAll(keepingCapacity: true)
        pendingBytes = 0

        do {
            var index = 0
            var rotatedForSize = false
            while index < rows.count {
                let dayKey = Self.utcDayKey(for: rows[index].receivedAt)
                var end = index + 1
                while end < rows.count, Self.utcDayKey(for: rows[end].receivedAt) == dayKey {
                    end += 1
                }
                try prepareCurrentFileLocked(dayKey: dayKey,
                                             firstTimestampMS: Self.unixMilliseconds(rows[index].receivedAt))
                let text = rows[index..<end].map(Self.csvRow).joined()
                let data = Data(text.utf8)
                if let handle = currentFileHandle,
                   Int64(try handle.offset()) + Int64(data.count) > maximumFileBytes {
                    closeCurrentFileLocked()
                    rotatedForSize = true
                    try prepareCurrentFileLocked(
                        dayKey: dayKey,
                        firstTimestampMS: Self.unixMilliseconds(rows[index].receivedAt)
                    )
                }
                try currentFileHandle?.write(contentsOf: data)
                index = end
            }
            try currentFileHandle?.synchronize()
            if let newest = rows.last?.receivedAt {
                pruneArchiveLocked(now: newest, force: rotatedForSize)
            }
        } catch {
            pendingRows.insert(contentsOf: rows, at: 0)
            pendingBytes += rows.reduce(0) { $0 + $1.estimatedBytes }
            closeCurrentFileLocked()
            AtriaDebugLog("ATRIADBG strap_step_calibration status=write_failed pending_rows=%d error=%@",
                          pendingRows.count,
                          String(describing: error))
        }
    }

    private func prepareCurrentFileLocked(dayKey: String, firstTimestampMS: Int64) throws {
        if currentDayKey == dayKey, currentFileHandle != nil { return }
        closeCurrentFileLocked()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let filename = "strap-imu-\(dayKey)-\(firstTimestampMS)-\(launchID).csv"
        let url = directoryURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: url.path) {
            let header = "schema_version,received_at_unix_ms,source,packet_type,record_type,raw_frame_hex\n"
            try Data(header.utf8).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        currentDayKey = dayKey
        currentFileURL = url
        currentFileHandle = handle
        pruneArchiveLocked(now: Date(timeIntervalSince1970: Double(firstTimestampMS) / 1_000),
                           force: true)
    }

    private func synchronizeCurrentFileLocked() {
        do {
            try currentFileHandle?.synchronize()
        } catch {
            AtriaDebugLog("ATRIADBG strap_step_calibration status=sync_failed error=%@",
                          String(describing: error))
        }
    }

    private func closeCurrentFileLocked() {
        synchronizeCurrentFileLocked()
        try? currentFileHandle?.close()
        currentFileHandle = nil
        currentFileURL = nil
        currentDayKey = nil
    }

    private func pruneArchiveLocked(now: Date, force: Bool = false) {
        if !force, let lastArchivePruneAt,
           now.timeIntervalSince(lastArchivePruneAt) >= 0,
           now.timeIntervalSince(lastArchivePruneAt) < archivePruneInterval {
            return
        }
        lastArchivePruneAt = now
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let candidates = files.filter {
            $0.pathExtension == "csv" && $0.lastPathComponent.hasPrefix("strap-imu-")
        }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        var retained: [(url: URL, modified: Date, bytes: Int64)] = []
        for url in candidates {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            if modified < cutoff, url != currentFileURL {
                try? fileManager.removeItem(at: url)
                continue
            }
            retained.append((url, modified, Int64(values?.fileSize ?? 0)))
        }
        retained.sort { $0.modified < $1.modified }
        var totalBytes = retained.reduce(Int64(0)) { $0 + $1.bytes }
        for item in retained where totalBytes > maximumArchiveBytes && item.url != currentFileURL {
            if (try? fileManager.removeItem(at: item.url)) != nil {
                totalBytes -= item.bytes
            }
        }
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func utcDayKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    private static func sanitizedSource(_ source: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        let scalars = source.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(scalars.prefix(48))
    }

    /// `String(format:)` for every byte was visible in the physical-device
    /// Time Profiler while calibration capture was armed. Build lowercase hex
    /// directly from UTF-8 pairs so this utility-queue archive remains cheap
    /// enough to run beside the live step pipeline.
    private static let lowercaseHexPairs: [UInt8] = {
        let digits = Array("0123456789abcdef".utf8)
        var pairs: [UInt8] = []
        pairs.reserveCapacity(256 * 2)
        for value in UInt16(0)...UInt16(255) {
            pairs.append(digits[Int(value >> 4)])
            pairs.append(digits[Int(value & 0x0F)])
        }
        return pairs
    }()

    private static func lowercaseHex(_ data: Data) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 2)
        for value in data {
            let index = Int(value) * 2
            bytes.append(lowercaseHexPairs[index])
            bytes.append(lowercaseHexPairs[index + 1])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func lowercaseHexByte(_ value: UInt8) -> String {
        let index = Int(value) * 2
        return String(decoding: lowercaseHexPairs[index...(index + 1)], as: UTF8.self)
    }

    private static func csvRow(_ row: PendingRow) -> String {
        let hex = lowercaseHex(row.frame)
        let packetType = row.frame.count > 4 ? lowercaseHexByte(row.frame[4]) : ""
        let recordType = row.frame.count > 5 ? lowercaseHexByte(row.frame[5]) : ""
        return "\(schemaVersion),\(unixMilliseconds(row.receivedAt)),\(row.source),\(packetType),\(recordType),\(hex)\n"
    }
}
