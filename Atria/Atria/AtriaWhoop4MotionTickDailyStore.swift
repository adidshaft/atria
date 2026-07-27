import Foundation

/// Durable, bounded publication receipt for verified WHOOP 4 v24 daily motion.
///
/// Raw historical rows remain the decoding authority. This store only keeps the
/// latest already-verified cumulative subtotal for a physiological-day window,
/// so archive retention or an unrelated projection rebuild cannot make a
/// previously published strap-owned count disappear.
final class AtriaWhoop4MotionTickDailyStore: @unchecked Sendable {
    private struct Record: Codable, Equatable {
        let schema: Int
        let algorithmVersion: String
        let strapIdentifier: String
        let windowStart: Date
        let windowEnd: Date
        let motionTicks: Int
        let steps: Int
        let knownCoverageSeconds: Int
        let missingCoverageSeconds: Int
        let decodedRows: Int
        let capturedThrough: Date
    }

    private static let schema = 1
    private static let maximumRecords = 32
    private static let maximumBytes = 512_000

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.stateURL = directoryURL.appendingPathComponent(
            "whoop4-motion-tick-days-v1.json"
        )
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            directoryURL: applicationSupport
                .appendingPathComponent("Atria/verified-step-evidence-v1"),
            fileManager: fileManager
        )
    }

    func load(
        strapIdentifier: String,
        windowStart: Date
    ) -> HistoricalArchive.MotionTickDayEvidence? {
        guard let strapIdentifier = Self.canonicalStrapIdentifier(
            strapIdentifier
        ) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let records = loadRecordsLocked()
        return records
            .filter {
                $0.strapIdentifier == strapIdentifier
                    && abs($0.windowStart.timeIntervalSince(windowStart)) < 1
            }
            .max { $0.capturedThrough < $1.capturedThrough }
            .map(Self.evidence)
    }

    /// Saves only stronger cumulative coverage evidence. Step totals may move
    /// downward when a later, more complete replay correctly rejects motion
    /// that an earlier partial window classified as gait.
    @discardableResult
    func save(
        _ evidence: HistoricalArchive.MotionTickDayEvidence,
        strapIdentifier: String
    ) throws -> Bool {
        guard let strapIdentifier = Self.canonicalStrapIdentifier(
            strapIdentifier
        ),
        Self.valid(evidence) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        lock.lock()
        defer { lock.unlock() }
        var records = loadRecordsLocked()
        let matching = records.indices.filter {
            records[$0].strapIdentifier == strapIdentifier
                && abs(records[$0].windowStart.timeIntervalSince(
                    evidence.windowStart
                )) < 1
        }
        if let strongest = matching.map({ records[$0] }).max(by: {
            if $0.knownCoverageSeconds != $1.knownCoverageSeconds {
                return $0.knownCoverageSeconds < $1.knownCoverageSeconds
            }
            return $0.capturedThrough < $1.capturedThrough
        }) {
            guard evidence.knownCoverageSeconds
                    >= strongest.knownCoverageSeconds,
                  evidence.capturedThrough >= strongest.capturedThrough,
                  evidence.knownCoverageSeconds
                        > strongest.knownCoverageSeconds
                    || evidence.capturedThrough > strongest.capturedThrough
                    || evidence.motionTicks != strongest.motionTicks
                    || evidence.steps != strongest.steps else {
                return false
            }
        }
        for index in matching.reversed() {
            records.remove(at: index)
        }
        records.append(
            .init(
                schema: Self.schema,
                algorithmVersion:
                    AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
                strapIdentifier: strapIdentifier,
                windowStart: evidence.windowStart,
                windowEnd: evidence.windowEnd,
                motionTicks: evidence.motionTicks,
                steps: evidence.steps,
                knownCoverageSeconds: evidence.knownCoverageSeconds,
                missingCoverageSeconds: evidence.missingCoverageSeconds,
                decodedRows: evidence.decodedRows,
                capturedThrough: evidence.capturedThrough
            )
        )
        records.sort { $0.windowStart > $1.windowStart }
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        try persistLocked(records)
        return true
    }

    private func loadRecordsLocked() -> [Record] {
        guard fileManager.fileExists(atPath: stateURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: stateURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let decoded = try JSONDecoder().decode([Record].self, from: data)
            guard decoded.allSatisfy(Self.valid),
                  try Self.encode(decoded) == data else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return decoded
        } catch {
            try? fileManager.removeItem(at: stateURL)
            return []
        }
    }

    private func persistLocked(_ records: [Record]) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        let data = try Self.encode(records)
        guard data.count <= Self.maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let temporary = directoryURL.appendingPathComponent(
            ".whoop4-motion-tick-days.\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporary, options: .atomic)
            try fileManager.setAttributes(
                [
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: temporary.path
            )
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.synchronize()
            try handle.close()
            if fileManager.fileExists(atPath: stateURL.path) {
                _ = try fileManager.replaceItemAt(
                    stateURL,
                    withItemAt: temporary
                )
            } else {
                try fileManager.moveItem(at: temporary, to: stateURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func canonicalStrapIdentifier(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }

    private static func valid(_ evidence: HistoricalArchive.MotionTickDayEvidence)
        -> Bool {
        evidence.windowEnd > evidence.windowStart
            && evidence.capturedThrough >= evidence.windowStart
            && evidence.capturedThrough <= evidence.windowEnd
            && evidence.motionTicks >= 0
            && evidence.steps >= 0
            && evidence.knownCoverageSeconds > 0
            && evidence.missingCoverageSeconds >= 0
            && evidence.decodedRows >= 2
    }

    private static func valid(_ record: Record) -> Bool {
        guard record.schema == schema,
              record.algorithmVersion
                == AtriaWhoop4GravityCadenceStepModel.algorithmVersion,
              canonicalStrapIdentifier(record.strapIdentifier)
                == record.strapIdentifier else {
            return false
        }
        return valid(evidence(record))
    }

    private static func evidence(
        _ record: Record
    ) -> HistoricalArchive.MotionTickDayEvidence {
        .init(
            windowStart: record.windowStart,
            windowEnd: record.windowEnd,
            motionTicks: record.motionTicks,
            steps: record.steps,
            knownCoverageSeconds: record.knownCoverageSeconds,
            missingCoverageSeconds: record.missingCoverageSeconds,
            decodedRows: record.decodedRows,
            capturedThrough: record.capturedThrough
        )
    }
}
