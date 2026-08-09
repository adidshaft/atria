import CryptoKit
import Foundation

/// Compact, bounded derivative of durably archived WHOOP 4 v24 frames.
///
/// The canonical JSONL archive remains the source of truth. This store exists
/// so a completed hourly motion-bank offload can be verified and projected
/// while iOS keeps the app in the background, without rereading the lifetime
/// archive. Every point is produced by the canonical decoder after the raw
/// frame was admitted and persisted. Duplicate raw payloads are idempotent.
final class AtriaWhoop4MotionTickCompactStore: @unchecked Sendable {
    static let shared = AtriaWhoop4MotionTickCompactStore()
    static let didSynchronizeNotification = Notification.Name(
        "AtriaWhoop4MotionTickCompactStore.didSynchronize"
    )

    struct Point: Hashable, Sendable {
        let timestamp: TimeInterval
        let flash: UInt32
        let tick: Int
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let unknownMotionScalar32: Double?
        let identity: String
    }

    struct MigrationPoint: Sendable {
        let timestamp: TimeInterval
        let flash: UInt32
        let tick: Int
        let gravityX: Double
        let gravityY: Double
        let gravityZ: Double
        let unknownMotionScalar32: Double?
        let rawPayload: [UInt8]
    }

    private static let schema: UInt32 = 1
    private static let recordMagic: UInt32 = 0x3154_4D41 // "AMT1"
    private static let recordSize = 52
    private static let retainedBucketCount: Int64 = 4
    private static let secondsPerBucket: TimeInterval = 86_400

    private let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var handles: [String: FileHandle] = [:]
    private var knownIdentities: Set<Data>?
    private var mutationGeneration: UInt64 = 0
    private var publishedGeneration: UInt64 = 0
    /// Retention changes only when an appended point crosses a UTC-day shard.
    /// Enumerating the directory for every 52-byte historical point turned a
    /// long drain into thousands of redundant Foundation filesystem calls.
    private var preparedRetentionBucket: Int64?

    init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL.standardizedFileURL
        self.fileManager = fileManager
    }

    convenience init(fileManager: FileManager = .default) {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        self.init(
            directoryURL: support.appendingPathComponent(
                "Atria/whoop4-motion-compact-v1",
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    deinit {
        lock.lock()
        let openHandles = Array(handles.values)
        handles.removeAll()
        lock.unlock()
        for handle in openHandles {
            try? handle.close()
        }
    }

    /// Appends only canonical, clock-corrected v24 motion. Returns `true` when
    /// a new compact point was written and `false` for an ineligible/duplicate
    /// frame. A compact-cache failure never changes canonical archive success.
    @discardableResult
    func append(
        record: HistoricalArchive.Record,
        rawPayload: [UInt8],
        strapIdentifier: String
    ) throws -> Bool {
        guard record.sequence
                == Int(AtriaWhoop4HistoricalLayout.v24.rawValue),
              record.clockCorrectionStatus == "clock_ref_present",
              record.gravityValidated,
              let correctedUnix = record.clockCorrectedUnix7,
              record.subsec11 < 32_768,
              let tick = record.motionTickCounter88,
              let gravityX = record.gravityX36,
              let gravityY = record.gravityY40,
              let gravityZ = record.gravityZ44,
              (0...65_535).contains(tick),
              !strapIdentifier.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return false
        }
        let timestamp = TimeInterval(correctedUnix)
            + TimeInterval(record.subsec11) / 32_768
        guard timestamp.isFinite,
              timestamp > 0,
              gravityX.isFinite,
              gravityY.isFinite,
              gravityZ.isFinite else {
            return false
        }
        let digest = Self.identityDigest(
            rawPayload: rawPayload,
            strapIdentifier: strapIdentifier
        )
        let bucket = Self.bucket(for: timestamp)
        let filename = Self.filename(
            strapIdentifier: strapIdentifier,
            bucket: bucket
        )

        lock.lock()
        defer { lock.unlock() }
        try prepareDirectoryLocked(currentBucket: bucket)
        try loadKnownIdentitiesLocked()
        guard knownIdentities?.insert(digest).inserted == true else {
            return false
        }
        do {
            let handle = try handleLocked(filename: filename)
            try handle.write(contentsOf: Self.encode(
                timestamp: timestamp,
                flash: record.flash13,
                tick: tick,
                gravityX: gravityX,
                gravityY: gravityY,
                gravityZ: gravityZ,
                scalar: record.unknownMotionScalar32,
                identityDigest: digest
            ))
            mutationGeneration &+= 1
            return true
        } catch {
            knownIdentities?.remove(digest)
            throw error
        }
    }

    /// One-time foreground migration for canonical rows retained before this
    /// compact derivative existed. The caller has already read and validated
    /// canonical JSONL; this performs no second archive scan and preserves the
    /// same strap+payload idempotency identity as live ingestion.
    @discardableResult
    func appendMigrated(
        _ points: [MigrationPoint],
        strapIdentifier: String
    ) throws -> Int {
        precondition(!Thread.isMainThread)
        guard !points.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return 0
        }
        let eligible = points.filter {
            $0.timestamp.isFinite
                && $0.timestamp > 0
                && (0...65_535).contains($0.tick)
                && $0.gravityX.isFinite
                && $0.gravityY.isFinite
                && $0.gravityZ.isFinite
                && !$0.rawPayload.isEmpty
        }.sorted { $0.timestamp < $1.timestamp }
        guard !eligible.isEmpty else { return 0 }

        lock.lock()
        defer { lock.unlock() }
        try prepareDirectoryLocked(
            currentBucket: Self.bucket(
                for: eligible.last!.timestamp
            )
        )
        try loadKnownIdentitiesLocked()
        var appended = 0
        for point in eligible {
            let digest = Self.identityDigest(
                rawPayload: point.rawPayload,
                strapIdentifier: strapIdentifier
            )
            guard knownIdentities?.insert(digest).inserted == true else {
                continue
            }
            do {
                let filename = Self.filename(
                    strapIdentifier: strapIdentifier,
                    bucket: Self.bucket(for: point.timestamp)
                )
                let handle = try handleLocked(filename: filename)
                try handle.write(contentsOf: Self.encode(
                    timestamp: point.timestamp,
                    flash: point.flash,
                    tick: point.tick,
                    gravityX: point.gravityX,
                    gravityY: point.gravityY,
                    gravityZ: point.gravityZ,
                    scalar: point.unknownMotionScalar32,
                    identityDigest: digest
                ))
                appended += 1
                mutationGeneration &+= 1
            } catch {
                knownIdentities?.remove(digest)
                throw error
            }
        }
        return appended
    }

    /// Flushes the derived shard at the same archive-queue boundary as the
    /// canonical raw store. One main-thread notification follows each newly
    /// durable generation so the current-cycle lower bound can advance even
    /// when no individual recovery ticket has reached 90% yet. Failure leaves
    /// the offload ticket unresolved and publishes nothing.
    func synchronize() throws {
        lock.lock()
        let openHandles = Array(handles.values)
        let synchronizedGeneration = mutationGeneration
        lock.unlock()
        for handle in openHandles {
            try handle.synchronize()
        }
        lock.lock()
        let shouldPublish =
            synchronizedGeneration > publishedGeneration
        if shouldPublish {
            publishedGeneration = synchronizedGeneration
        }
        lock.unlock()
        if shouldPublish {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.didSynchronizeNotification,
                    object: nil
                )
            }
        }
    }

    /// Stable revision for the compact shards intersecting one projection
    /// window. Receipt attempt de-duplication must include this derivative
    /// source: canonical JSONL can remain unchanged while a background history
    /// drain appends newly decoded v24 rows to the compact store.
    func sourceFingerprint(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> String? {
        precondition(!Thread.isMainThread)
        guard end > start,
              !strapIdentifier.isEmpty,
              UUID(uuidString: strapIdentifier) != nil else {
            return nil
        }
        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(
            for: max(
                start.timeIntervalSince1970,
                end.timeIntervalSince1970.nextDown
            )
        )
        lock.lock()
        defer { lock.unlock() }
        let revisions = (firstBucket...lastBucket).map { bucket in
            let filename = Self.filename(
                strapIdentifier: strapIdentifier,
                bucket: bucket
            )
            let url = directoryURL.appendingPathComponent(filename)
            let attributes = try? fileManager.attributesOfItem(
                atPath: url.path
            )
            let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
            return "\(bucket):\(size)"
        }
        let material = [
            String(Self.schema),
            strapIdentifier.uppercased(),
            revisions.joined(separator: ","),
        ].joined(separator: "|")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func transportCoverage(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        precondition(!Thread.isMainThread)
        guard end > start else {
            return .init(
                observedSeconds: 0,
                expectedSeconds: 0,
                densityPercent: 0,
                maximumMissingRunSeconds: 0,
                firstCapturedAt: nil,
                capturedThrough: nil
            )
        }
        let points = read(
            start: start.addingTimeInterval(-1),
            end: end.addingTimeInterval(1),
            strapIdentifier: strapIdentifier
        )
        return Self.transportCoverage(
            points: points,
            start: start,
            end: end
        )
    }

    /// Reads the compact shard once and evaluates every pending exact bank
    /// window against that same durable generation. A full history response can
    /// satisfy many disconnected bank windows; one-ticket-at-a-time reads made
    /// convergence proportional to link churn and repeatedly interrupted HR.
    func transportCoverages(
        tickets: [AtriaWhoop4MotionBankCoverageLedger.OffloadTicket],
        strapIdentifier: String
    ) -> [String: HistoricalArchive.MotionBankTransportCoverage] {
        precondition(!Thread.isMainThread)
        let eligible = tickets.filter {
            $0.strapIdentifier.caseInsensitiveCompare(strapIdentifier)
                == .orderedSame
                && $0.end > $0.start
        }
        guard let first = eligible.map(\.start).min(),
              let last = eligible.map(\.end).max() else {
            return [:]
        }
        let points = read(
            start: first.addingTimeInterval(-1),
            end: last.addingTimeInterval(1),
            strapIdentifier: strapIdentifier
        )
        return Dictionary(uniqueKeysWithValues: eligible.map { ticket in
            (
                ticket.id,
                Self.transportCoverage(
                    points: points,
                    start: ticket.start,
                    end: ticket.end
                )
            )
        })
    }

    private static func transportCoverage(
        points: [Point],
        start: Date,
        end: Date
    ) -> HistoricalArchive.MotionBankTransportCoverage {
        guard end > start else {
            return .init(
                observedSeconds: 0,
                expectedSeconds: 0,
                densityPercent: 0,
                maximumMissingRunSeconds: 0,
                firstCapturedAt: nil,
                capturedThrough: nil
            )
        }
        let firstBucket = Int(floor(start.timeIntervalSince1970))
        let lastBucket = Int(floor(end.timeIntervalSince1970))
        let expected = max(1, lastBucket - firstBucket + 1)
        let matchingTimestamps = points.compactMap { point -> TimeInterval? in
            let bucket = Int(floor(point.timestamp))
            return (firstBucket...lastBucket).contains(bucket)
                ? point.timestamp
                : nil
        }.sorted()
        let seconds = Set(matchingTimestamps.map {
            Int(floor($0))
        })
        var maximumMissingRun = 0
        var currentMissingRun = 0
        for bucket in firstBucket...lastBucket {
            if seconds.contains(bucket) {
                currentMissingRun = 0
            } else {
                currentMissingRun += 1
                maximumMissingRun = max(
                    maximumMissingRun,
                    currentMissingRun
                )
            }
        }
        return .init(
            observedSeconds: seconds.count,
            expectedSeconds: expected,
            densityPercent: min(
                100,
                Int(
                    (Double(seconds.count) / Double(expected) * 100)
                        .rounded()
                )
            ),
            maximumMissingRunSeconds: maximumMissingRun,
            firstCapturedAt: matchingTimestamps.first.map {
                Date(timeIntervalSince1970: $0)
            },
            capturedThrough: matchingTimestamps.last.map {
                Date(timeIntervalSince1970: $0)
            }
        )
    }

    /// Projects one exact confirmed-workout window from the fixed-width
    /// compact shards. These points already carry their accepted corrected
    /// wall timestamps, so one zero offset governs the whole candidate. A
    /// missing boundary remains incomplete: it is never authority to fall back
    /// to lifetime JSONL from a launch, scene, or BLE callback.
    func motionTickWindowRead(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> HistoricalArchive.MotionTickWindowRead {
        precondition(!Thread.isMainThread)
        guard end > start,
              !strapIdentifier.isEmpty else { return .incomplete }
        let tolerance: TimeInterval = 3
        let firstBucket = Self.bucket(
            for: start.addingTimeInterval(-tolerance).timeIntervalSince1970
        )
        let lastBucket = Self.bucket(
            for: end.addingTimeInterval(tolerance).timeIntervalSince1970
        )
        guard firstBucket <= lastBucket,
              lastBucket - firstBucket + 1
                <= Self.retainedBucketCount else {
            return .incomplete
        }
        let points = read(
            start: start.addingTimeInterval(-tolerance),
            end: end.addingTimeInterval(tolerance),
            strapIdentifier: strapIdentifier
        )
        guard points.count >= 2,
              let first = points.min(by: {
                  abs($0.timestamp - start.timeIntervalSince1970)
                      < abs($1.timestamp - start.timeIntervalSince1970)
              }),
              let last = points.min(by: {
                  abs($0.timestamp - end.timeIntervalSince1970)
                      < abs($1.timestamp - end.timeIntervalSince1970)
              }),
              last.timestamp > first.timestamp,
              abs(first.timestamp - start.timeIntervalSince1970)
                <= tolerance,
              abs(last.timestamp - end.timeIntervalSince1970)
                <= tolerance,
              (last.timestamp - first.timestamp)
                / end.timeIntervalSince(start) >= 0.9 else {
            return .incomplete
        }
        let cadencePoints = points.map {
            AtriaWhoop4GravityCadenceStepModel.Point(
                timestamp: $0.timestamp,
                flash: $0.flash,
                tick: $0.tick,
                gravityX: $0.gravityX,
                gravityY: $0.gravityY,
                gravityZ: $0.gravityZ,
                unknownMotionScalar32: $0.unknownMotionScalar32,
                identity: $0.identity
            )
        }
        guard let selected =
            AtriaWhoop4GravityCadenceStepModel.estimateAlignedWindow(
                points: cadencePoints,
                requestedStart: start.timeIntervalSince1970,
                requestedEnd: end.timeIntervalSince1970,
                clockOffsetByIdentity: Dictionary(
                    uniqueKeysWithValues: cadencePoints.map {
                        ($0.identity, 0)
                    }
                ),
                boundaryTolerance: tolerance
            ) else {
            return .completeNoQualifiedEvidence
        }
        let modulus = 65_536
        let delta = selected.last.tick >= selected.first.tick
            ? selected.last.tick - selected.first.tick
            : selected.last.tick + modulus - selected.first.tick
        guard Double(delta) <= max(
            12,
            (selected.last.timestamp - selected.first.timestamp) * 12
        ) else {
            return .completeNoQualifiedEvidence
        }
        return .qualified(
            .init(
                startTick: selected.first.tick,
                endTick: selected.last.tick,
                delta: delta,
                steps: selected.estimate.steps,
                startCapturedAt: Date(
                    timeIntervalSince1970: selected.first.timestamp
                ),
                endCapturedAt: Date(
                    timeIntervalSince1970: selected.last.timestamp
                ),
                coverageFraction: selected.coverageFraction,
                decodedRows: selected.decodedRows
            )
        )
    }

    /// Projects only compact current-cycle points. It performs no canonical
    /// archive enumeration or JSON decoding and is safe on a utility queue
    /// during a locked/background BLE restoration lease.
    func motionTickDayEvidenceRead(
        start: Date,
        end: Date,
        bankCoverage: [DateInterval],
        strapIdentifier: String
    ) -> HistoricalArchive.MotionTickDayEvidenceRead {
        precondition(!Thread.isMainThread)
        guard end > start, !bankCoverage.isEmpty else { return .incomplete }
        let window = DateInterval(start: start, end: end)
        let intervals = Self.merge(bankCoverage.compactMap { interval in
            let clippedStart = max(interval.start, window.start)
            let clippedEnd = min(interval.end, window.end)
            return clippedEnd > clippedStart
                ? DateInterval(start: clippedStart, end: clippedEnd)
                : nil
        })
        guard let firstInterval = intervals.first,
              let lastInterval = intervals.last else {
            return .incomplete
        }
        let tolerance: TimeInterval = 3
        let points = read(
            start: firstInterval.start.addingTimeInterval(-tolerance),
            end: lastInterval.end.addingTimeInterval(tolerance),
            strapIdentifier: strapIdentifier
        )
        guard points.count >= 2 else { return .incomplete }

        typealias CounterPoint =
            AtriaWhoop4MotionTickSequenceReducer.Point
        typealias CadencePoint =
            AtriaWhoop4GravityCadenceStepModel.Point
        var totalTicks = 0
        var totalKnownDuration: TimeInterval = 0
        var totalDecodedRows = 0
        var capturedThrough: Date?
        var cadenceFragments: [[CadencePoint]] = []

        for interval in intervals {
            let nearby = points.filter {
                $0.timestamp >= interval.start.timeIntervalSince1970
                    - tolerance
                    && $0.timestamp <= interval.end.timeIntervalSince1970
                    + tolerance
            }
            guard let first = nearby.min(by: {
                abs($0.timestamp - interval.start.timeIntervalSince1970)
                    < abs(
                        $1.timestamp
                            - interval.start.timeIntervalSince1970
                    )
            }),
            let last = nearby.min(by: {
                abs($0.timestamp - interval.end.timeIntervalSince1970)
                    < abs(
                        $1.timestamp
                            - interval.end.timeIntervalSince1970
                    )
            }),
            abs(first.timestamp - interval.start.timeIntervalSince1970)
                <= tolerance,
            abs(last.timestamp - interval.end.timeIntervalSince1970)
                <= tolerance,
            last.timestamp > first.timestamp else {
                continue
            }
            let members = nearby.filter {
                $0.timestamp >= first.timestamp
                    && $0.timestamp <= last.timestamp
            }.sorted {
                if $0.timestamp != $1.timestamp {
                    return $0.timestamp < $1.timestamp
                }
                return $0.identity < $1.identity
            }
            let counterPoints = members.map {
                CounterPoint(
                    timestamp: $0.timestamp,
                    tick: $0.tick,
                    flash: $0.flash,
                    identity: $0.identity
                )
            }
            let rawInterval = DateInterval(
                start: Date(timeIntervalSince1970: first.timestamp),
                end: Date(timeIntervalSince1970: last.timestamp)
            )
            guard let reduced = AtriaWhoop4MotionTickSequenceReducer.reduce(
                points: counterPoints,
                intervals: [rawInterval],
                boundaryTolerance: 0.001
            ) else {
                continue
            }
            cadenceFragments.append(members.map {
                CadencePoint(
                    timestamp: $0.timestamp,
                    flash: $0.flash,
                    tick: $0.tick,
                    gravityX: $0.gravityX,
                    gravityY: $0.gravityY,
                    gravityZ: $0.gravityZ,
                    unknownMotionScalar32: $0.unknownMotionScalar32,
                    identity: $0.identity
                )
            })
            totalTicks += reduced.ticks
            totalKnownDuration += reduced.knownDuration
            totalDecodedRows += reduced.admittedRows
            capturedThrough = max(
                capturedThrough ?? reduced.capturedThrough,
                reduced.capturedThrough
            )
        }

        guard totalKnownDuration > 0,
              totalDecodedRows >= 2,
              let capturedThrough else {
            return .completeNoQualifiedEvidence
        }
        let estimate = AtriaWhoop4GravityCadenceStepModel
            .estimateCoveredActivityFragments(cadenceFragments)
        let unresolved = estimate?.unresolvedMotionSeconds
            ?? totalKnownDuration
        let totalSeconds = max(
            0,
            Int(end.timeIntervalSince(start).rounded())
        )
        let knownSeconds = max(
            0,
            Int(totalKnownDuration.rounded())
        )
        let qualifiedSeconds = max(
            0,
            min(totalSeconds, knownSeconds)
                - max(0, Int(unresolved.rounded(.up)))
        )
        return .qualified(
            .init(
                windowStart: start,
                windowEnd: end,
                motionTicks: totalTicks,
                steps: estimate?.steps ?? 0,
                knownCoverageSeconds: qualifiedSeconds,
                missingCoverageSeconds: max(
                    0,
                    totalSeconds - qualifiedSeconds
                ),
                decodedRows: totalDecodedRows,
                capturedThrough: min(capturedThrough, end)
            )
        )
    }

    private func read(
        start: Date,
        end: Date,
        strapIdentifier: String
    ) -> [Point] {
        guard end > start,
              UUID(uuidString: strapIdentifier) != nil else {
            return []
        }
        lock.lock()
        defer { lock.unlock() }
        try? handles.values.forEach { try $0.synchronize() }
        let firstBucket = Self.bucket(for: start.timeIntervalSince1970)
        let lastBucket = Self.bucket(for: end.timeIntervalSince1970)
        var byIdentity: [String: Point] = [:]
        if firstBucket <= lastBucket {
            for bucket in firstBucket...lastBucket {
                let url = directoryURL.appendingPathComponent(
                    Self.filename(
                        strapIdentifier: strapIdentifier,
                        bucket: bucket
                    )
                )
                guard let data = try? Data(
                    contentsOf: url,
                    options: .mappedIfSafe
                ) else {
                    continue
                }
                for point in Self.decode(data) where
                    point.timestamp >= start.timeIntervalSince1970
                        && point.timestamp <= end.timeIntervalSince1970 {
                    byIdentity[point.identity] = point
                }
            }
        }
        return byIdentity.values.sorted {
            if $0.timestamp != $1.timestamp {
                return $0.timestamp < $1.timestamp
            }
            return $0.identity < $1.identity
        }
    }

    private func prepareDirectoryLocked(currentBucket: Int64) throws {
        guard preparedRetentionBucket != currentBucket else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let minimumBucket =
            currentBucket - Self.retainedBucketCount + 1
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls {
            guard let bucket = Self.bucket(from: url.lastPathComponent),
                  bucket < minimumBucket else {
                continue
            }
            if let handle = handles.removeValue(forKey: url.path) {
                try? handle.close()
            }
            do {
                try fileManager.removeItem(at: url)
                // The identity index mirrors only retained shards. Keeping
                // digests from deleted buckets would make memory grow for the
                // lifetime of the process and would falsely reject a later
                // canonical rebuild of that payload.
                knownIdentities = nil
            } catch {
                // Retention is best effort. If deletion failed, the shard and
                // its identities remain part of the retained source.
            }
        }
        preparedRetentionBucket = currentBucket
    }

    private func loadKnownIdentitiesLocked() throws {
        guard knownIdentities == nil else { return }
        var identities = Set<Data>()
        let urls = (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )) ?? []
        for url in urls where url.pathExtension == "bin" {
            try repairPartialTailLocked(at: url)
            guard let data = try? Data(
                contentsOf: url,
                options: .mappedIfSafe
            ) else {
                continue
            }
            // A surviving magic word is not enough to establish an identity:
            // the record body may have been torn or corrupted. Index only
            // points accepted by the same full decoder used by projections so
            // canonical migration can repair any rejected record.
            for point in Self.decode(data) {
                guard let identity = Self.identityData(
                    fromHex: point.identity
                ) else { continue }
                identities.insert(identity)
            }
        }
        knownIdentities = identities
    }

    private func handleLocked(filename: String) throws -> FileHandle {
        let url = directoryURL.appendingPathComponent(filename)
        if let existing = handles[url.path] {
            return existing
        }
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try repairPartialTailLocked(at: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        handles[url.path] = handle
        return handle
    }

    /// A process can be killed after only a prefix of one fixed-width record
    /// reaches the filesystem. Never append behind that torn tail: doing so
    /// shifts every later record away from the 52-byte decode boundary. The
    /// compact store is a rebuildable derivative, so truncating only the
    /// incomplete suffix is the loss-minimizing repair.
    private func repairPartialTailLocked(at url: URL) throws {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        let number = attributes[.size] as? NSNumber else {
            return
        }
        let size = number.uint64Value
        let remainder = size % UInt64(Self.recordSize)
        guard remainder > 0 else { return }
        let repairedSize = size - remainder
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: repairedSize)
        try handle.synchronize()
    }

    private static func encode(
        timestamp: TimeInterval,
        flash: UInt32,
        tick: Int,
        gravityX: Double,
        gravityY: Double,
        gravityZ: Double,
        scalar: Double?,
        identityDigest: Data
    ) -> Data {
        var data = Data(capacity: recordSize)
        append(recordMagic, to: &data)
        append(timestamp.bitPattern, to: &data)
        append(flash, to: &data)
        append(UInt32(bitPattern: Int32(tick)), to: &data)
        append(Float(gravityX).bitPattern, to: &data)
        append(Float(gravityY).bitPattern, to: &data)
        append(Float(gravityZ).bitPattern, to: &data)
        append(Float(scalar ?? .nan).bitPattern, to: &data)
        data.append(identityDigest.prefix(16))
        return data
    }

    private static func decode(_ data: Data) -> [Point] {
        guard data.count >= recordSize else { return [] }
        var result: [Point] = []
        result.reserveCapacity(data.count / recordSize)
        for offset in stride(
            from: 0,
            to: data.count - (data.count % recordSize),
            by: recordSize
        ) {
            guard uint32(data, at: offset) == recordMagic else {
                continue
            }
            let timestamp = Double(
                bitPattern: uint64(data, at: offset + 4)
            )
            let flash = uint32(data, at: offset + 12)
            let tick = Int(
                Int32(bitPattern: uint32(data, at: offset + 16))
            )
            let gravityX = Double(
                Float(bitPattern: uint32(data, at: offset + 20))
            )
            let gravityY = Double(
                Float(bitPattern: uint32(data, at: offset + 24))
            )
            let gravityZ = Double(
                Float(bitPattern: uint32(data, at: offset + 28))
            )
            let scalarFloat = Float(
                bitPattern: uint32(data, at: offset + 32)
            )
            let digest = Data(data[(offset + 36)..<(offset + 52)])
            guard timestamp.isFinite,
                  timestamp > 0,
                  (0...65_535).contains(tick),
                  gravityX.isFinite,
                  gravityY.isFinite,
                  gravityZ.isFinite else {
                continue
            }
            result.append(
                .init(
                    timestamp: timestamp,
                    flash: flash,
                    tick: tick,
                    gravityX: gravityX,
                    gravityY: gravityY,
                    gravityZ: gravityZ,
                    unknownMotionScalar32:
                        scalarFloat.isFinite
                            ? Double(scalarFloat) : nil,
                    identity: digest.map {
                        String(format: "%02x", $0)
                    }.joined()
                )
            )
        }
        return result
    }

    private static func append<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) {
            data.append(contentsOf: $0)
        }
    }

    private static func identityDigest(
        rawPayload: [UInt8],
        strapIdentifier: String
    ) -> Data {
        var material = Data(strapIdentifier.uppercased().utf8)
        material.append(0)
        material.append(contentsOf: rawPayload)
        return Data(SHA256.hash(data: material).prefix(16))
    }

    private static func identityData(fromHex value: String) -> Data? {
        guard value.count == 32 else { return nil }
        var result = Data(capacity: 16)
        var index = value.startIndex
        for _ in 0..<16 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else {
                return nil
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data[offset..<(offset + 4)].enumerated().reduce(0) {
            $0 | UInt32($1.element) << UInt32($1.offset * 8)
        }
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data[offset..<(offset + 8)].enumerated().reduce(0) {
            $0 | UInt64($1.element) << UInt64($1.offset * 8)
        }
    }

    private static func bucket(for timestamp: TimeInterval) -> Int64 {
        Int64(floor(timestamp / secondsPerBucket))
    }

    private static func filename(
        strapIdentifier: String,
        bucket: Int64
    ) -> String {
        "v\(schema)-\(strapIdentifier.uppercased())-\(bucket).bin"
    }

    private static func bucket(from filename: String) -> Int64? {
        guard filename.hasPrefix("v\(schema)-"),
              filename.hasSuffix(".bin"),
              let value = filename
                .dropLast(4)
                .split(separator: "-")
                .last else {
            return nil
        }
        return Int64(value)
    }

    private static func merge(_ intervals: [DateInterval])
        -> [DateInterval] {
        let sorted = intervals.filter {
            $0.end > $0.start
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.end < $1.end
        }
        var result: [DateInterval] = []
        for interval in sorted {
            guard let last = result.last else {
                result.append(interval)
                continue
            }
            if interval.start <= last.end {
                result[result.count - 1] = .init(
                    start: last.start,
                    end: max(last.end, interval.end)
                )
            } else {
                result.append(interval)
            }
        }
        return result
    }
}
