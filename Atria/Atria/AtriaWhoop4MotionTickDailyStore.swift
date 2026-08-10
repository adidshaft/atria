import CryptoKit
import Foundation

/// Durable, bounded publication receipt for verified WHOOP 4 v24 daily motion.
///
/// Raw historical rows remain the decoding authority. This store only keeps the
/// latest already-verified cumulative subtotal for a physiological-day window,
/// so archive retention or an unrelated projection rebuild cannot make a
/// previously published strap-owned count disappear.
final class AtriaWhoop4MotionTickDailyStore: @unchecked Sendable {
    /// App-wide receipt authority. Home and widgets use this cached instance so
    /// frequent live publications do not repeatedly touch the filesystem.
    static let shared = AtriaWhoop4MotionTickDailyStore()
    static let didSaveNotification = Notification.Name(
        "AtriaWhoop4MotionTickDailyStore.didSave"
    )

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

    /// Immutable identity for the exact durable record selected for current-
    /// cycle publication. `capturedThrough` alone is not a revision: a stronger
    /// replay may correct motion/steps while retaining the same evidence clock.
    struct PublicationReceipt: Equatable {
        let evidence: HistoricalArchive.MotionTickDayEvidence
        let sourceIdentifier: String
        let contentRevision: String
    }

    struct CurrentCyclePublication {
        let projectedDays: [
            AtriaHistoricalDailyConsumerProjection.StepDay
        ]
        let receipt: PublicationReceipt?
        /// Non-nil only when the returned current-cycle display row was
        /// selected from `receipt`. A stronger independently projected
        /// canonical row deliberately leaves this nil even though receipt
        /// metadata is still returned for monotonic ordering.
        let displayedReceiptContentRevision: String?
        /// Observed motion with no qualified gait subtotal invalidates an
        /// older partial count even though this receipt displays no number.
        let receiptInvalidatesIndependentPartial: Bool
    }

    private static let schema = 1
    private static let maximumRecords = 32
    private static let maximumBytes = 512_000

    private let directoryURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var cachedRecords: [Record]?

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

    /// 2026-07-31: newest receipt that closed at or before the given wake
    /// boundary. This is disclosure-only evidence for the preceding
    /// physiological cycle: it is returned separately and is never merged into
    /// the current cycle's projected days, so a prior-cycle subtotal cannot
    /// masquerade as today's count. Callers may only name it (value stays
    /// "--") while the open cycle has no receipt of its own.
    func latestReceipt(
        before windowStart: Date,
        strapIdentifiers: [String],
        includeUnqualifiedResearchEvidence: Bool = false
    ) -> HistoricalArchive.MotionTickDayEvidence? {
        guard AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified
                || includeUnqualifiedResearchEvidence else { return nil }
        let identifiers = Set(strapIdentifiers.compactMap(
            Self.canonicalStrapIdentifier
        ))
        guard !identifiers.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return loadRecordsLocked()
            .filter {
                identifiers.contains($0.strapIdentifier)
                    && $0.windowStart < windowStart
                    && $0.windowEnd <= windowStart.addingTimeInterval(1)
            }
            .max { lhs, rhs in
                if abs(lhs.windowStart.timeIntervalSince(
                    rhs.windowStart
                )) >= 1 {
                    return lhs.windowStart < rhs.windowStart
                }
                return Self.isWeaker(lhs, rhs)
            }
            .map(Self.evidence)
    }

    func latestReceipt(
        before windowStart: Date,
        strapIdentifier: String
    ) -> HistoricalArchive.MotionTickDayEvidence? {
        latestReceipt(before: windowStart, strapIdentifiers: [strapIdentifier])
    }

    /// 2026-07-31: most recent durable receipts for relaunch rehydration.
    /// Records are day-keyed (one strongest record per wake window) and
    /// returned newest-first. Consumers must keep the cycle-boundary rules:
    /// only the exact current-window receipt may represent the open day.
    func recentReceipts(
        strapIdentifier: String,
        limit: Int = 14
    ) -> [HistoricalArchive.MotionTickDayEvidence] {
        guard limit > 0, let strapIdentifier = Self.canonicalStrapIdentifier(
            strapIdentifier
        ) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return loadRecordsLocked()
            .filter { $0.strapIdentifier == strapIdentifier }
            .sorted { $0.windowStart > $1.windowStart }
            .prefix(limit)
            .map(Self.evidence)
    }

    /// Every step surface must resolve the same current strap identity.
    /// The saved link is updated on every successful connection and therefore
    /// owns publication after replacement/re-pair. The verified-history
    /// identity is only a fallback before a saved link exists; unioning two
    /// different UUIDs could let a former strap masquerade as today's source.
    static func persistedStrapIdentifiers(
        defaults: UserDefaults = .standard
    ) -> [String] {
        if let saved = defaults.string(
            forKey: AtriaBLEManager.LinkDefaults.savedPeripheralUUID
        ).flatMap(canonicalStrapIdentifier) {
            return [saved]
        }
        if let verified = defaults.string(
            forKey: AtriaBLEManager.OfflineSyncDefaults
                .verifiedHistoryPeripheralID
        ).flatMap(canonicalStrapIdentifier) {
            return [verified]
        }
        return []
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
        ) else {
            AtriaDebugLog(
                "ATRIADBG whoop4_daily_steps status=receipt_rejected detail=invalid_strap_identifier"
            )
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard let validationFailure = Self.validationFailure(evidence) else {
            return try saveValidated(
                evidence,
                strapIdentifier: strapIdentifier
            )
        }
        AtriaDebugLog(
            "ATRIADBG whoop4_daily_steps status=receipt_rejected detail=%@ start=%.3f end=%.3f captured=%.3f ticks=%d steps=%d known=%d missing=%d rows=%d",
            validationFailure,
            evidence.windowStart.timeIntervalSince1970,
            evidence.windowEnd.timeIntervalSince1970,
            evidence.capturedThrough.timeIntervalSince1970,
            evidence.motionTicks,
            evidence.steps,
            evidence.knownCoverageSeconds,
            evidence.missingCoverageSeconds,
            evidence.decodedRows
        )
        throw CocoaError(.fileWriteInvalidFileName)
    }

    private func saveValidated(
        _ evidence: HistoricalArchive.MotionTickDayEvidence,
        strapIdentifier: String
    ) throws -> Bool {
        guard Self.valid(evidence) else {
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
        cachedRecords = records
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didSaveNotification,
                                            object: nil)
        }
        return true
    }

    private func loadRecordsLocked() -> [Record] {
        if let cachedRecords {
            return cachedRecords
        }
        guard fileManager.fileExists(atPath: stateURL.path) else {
            cachedRecords = []
            return []
        }
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
            cachedRecords = decoded
            return decoded
        } catch {
            try? fileManager.removeItem(at: stateURL)
            cachedRecords = []
            return []
        }
    }

    /// Merges the exact current physiological-cycle receipt into an async
    /// history projection. Only the matching wake boundary is considered and
    /// the strongest partial coverage wins. Exact canonical totals remain
    /// authoritative (including conflicting totals, which presentation code
    /// deliberately withholds rather than guessing).
    func mergingCurrentCycleReceipt(
        into projectedDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
        strapIdentifier: String,
        windowStart: Date,
        includeUnqualifiedResearchEvidence: Bool = false,
        calendar: Calendar = .current
    ) -> [AtriaHistoricalDailyConsumerProjection.StepDay] {
        mergingCurrentCycleReceipt(
            into: projectedDays,
            strapIdentifiers: [strapIdentifier],
            windowStart: windowStart,
            now: Date(),
            includeUnqualifiedResearchEvidence:
                includeUnqualifiedResearchEvidence,
            calendar: calendar
        )
    }

    /// Resolves the strongest receipt that is safe for the active
    /// physiological cycle. An exact wake-boundary receipt retains exact-day
    /// eligibility. A receipt beginning later in the same physiological cycle
    /// is only a contained subset, so it is rebased as partial lower-bound
    /// evidence with the uncovered prefix counted as missing. The receipt may
    /// cross civil midnight: wake-to-wake ownership, not the calendar date at
    /// presentation time, is authoritative. A receipt that begins before the
    /// current wake boundary is never admitted because its step subtotal may
    /// belong to the preceding cycle.
    func mergingCurrentCycleReceipt(
        into projectedDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
        strapIdentifiers: [String],
        windowStart: Date,
        now: Date,
        includeUnqualifiedResearchEvidence: Bool = false,
        calendar: Calendar = .current
    ) -> [AtriaHistoricalDailyConsumerProjection.StepDay] {
        currentCyclePublication(
            into: projectedDays,
            strapIdentifiers: strapIdentifiers,
            windowStart: windowStart,
            now: now,
            includeUnqualifiedResearchEvidence:
                includeUnqualifiedResearchEvidence,
            calendar: calendar
        ).projectedDays
    }

    /// Returns the presentation merge and the identity of the exact durable
    /// record that produced it from one locked selection. Callers can therefore
    /// order equal-clock corrections without racing a second receipt lookup.
    func currentCyclePublication(
        into projectedDays: [AtriaHistoricalDailyConsumerProjection.StepDay],
        strapIdentifiers: [String],
        windowStart: Date,
        now: Date,
        includeUnqualifiedResearchEvidence: Bool = false,
        calendar: Calendar = .current
    ) -> CurrentCyclePublication {
        guard let record = currentCycleRecord(
            strapIdentifiers: strapIdentifiers,
            windowStart: windowStart,
            now: now,
            includeUnqualifiedResearchEvidence:
                includeUnqualifiedResearchEvidence
        ), let revision = Self.contentRevision(record) else {
            return .init(
                projectedDays: projectedDays,
                receipt: nil,
                displayedReceiptContentRevision: nil,
                receiptInvalidatesIndependentPartial: false
            )
        }
        let evidence = Self.evidence(record)
        let publicationReceipt = PublicationReceipt(
            evidence: evidence,
            sourceIdentifier: record.strapIdentifier,
            contentRevision: revision
        )
        let isExactBoundary =
            abs(record.windowStart.timeIntervalSince(windowStart)) < 1
        let receipt = Self.stepDay(
            evidence: evidence,
            presentationWindowStart: windowStart,
            forcePartial: !isExactBoundary,
            calendar: calendar
        )
        let matching = projectedDays.filter {
            abs($0.dayStart.timeIntervalSince(windowStart)) < 1
        }
        if matching.contains(where: {
            ($0.state == .available || $0.state == .knownEmpty)
                && $0.stepCount != nil
        }) {
            return .init(
                projectedDays: projectedDays,
                receipt: publicationReceipt,
                displayedReceiptContentRevision: nil,
                receiptInvalidatesIndependentPartial: false
            )
        }
        // A stronger cumulative replay can supersede a previously publishable
        // stationary/partial prefix with observed motion whose gait count is
        // still unresolved. Do not let the generic "largest known coverage"
        // comparison resurrect that older row: doing so leaves Home/widgets
        // advertising its stale capture clock even though the durable receipt
        // has explicitly invalidated the count. The exact/known-empty canonical
        // authority above still wins, and `stepDay` keeps the existing fail-
        // closed motion-observed gate intact.
        let receiptInvalidatesOlderPartial =
            record.motionTicks > 0 && record.steps == 0
        let strongestProjected = matching
            .filter { $0.state == .missing && $0.knownCoverageSeconds > 0 }
            .max(by: Self.isWeaker)
        let receiptOwnsDisplayedRow: Bool
        let strongest: AtriaHistoricalDailyConsumerProjection.StepDay
        if receiptInvalidatesOlderPartial {
            strongest = receipt
            receiptOwnsDisplayedRow = true
        } else if let strongestProjected {
            receiptOwnsDisplayedRow = Self.isWeaker(
                strongestProjected,
                receipt
            )
            strongest = receiptOwnsDisplayedRow
                ? receipt : strongestProjected
        } else {
            strongest = receipt
            receiptOwnsDisplayedRow = true
        }
        var merged = projectedDays.filter {
            abs($0.dayStart.timeIntervalSince(windowStart)) >= 1
        }
        merged.append(strongest)
        return .init(
            projectedDays: merged.sorted { $0.dayStart > $1.dayStart },
            receipt: publicationReceipt,
            displayedReceiptContentRevision: receiptOwnsDisplayedRow
                ? revision : nil,
            receiptInvalidatesIndependentPartial:
                receiptInvalidatesOlderPartial
        )
    }

    private func currentCycleRecord(
        strapIdentifiers: [String],
        windowStart: Date,
        now: Date,
        includeUnqualifiedResearchEvidence: Bool
    ) -> Record? {
        guard AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified
                || includeUnqualifiedResearchEvidence else { return nil }
        let identifiers = Set(strapIdentifiers.compactMap(
            Self.canonicalStrapIdentifier
        ))
        guard !identifiers.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let candidates = loadRecordsLocked().filter {
            identifiers.contains($0.strapIdentifier)
                && $0.capturedThrough <= now.addingTimeInterval(5)
        }
        let exact = candidates
            .filter { abs($0.windowStart.timeIntervalSince(windowStart)) < 1 }
            .max(by: Self.isWeaker)
        let contained = candidates
            .filter {
                $0.windowStart >= windowStart
                    && $0.windowStart <= now.addingTimeInterval(5)
                    && $0.capturedThrough >= $0.windowStart
            }
            .max(by: Self.isWeaker)
        return exact ?? contained
    }

    /// Removes only day rows previously synthesized from this store's
    /// now-unqualified v24 receipts. A history snapshot can outlive a model
    /// qualification change in memory; merely refusing to merge a new receipt
    /// would leave that stale row looking like canonical archive evidence on
    /// Home and in the widget.
    ///
    /// Match the complete synthesized signature rather than only the day
    /// boundary so a genuine canonical step receipt for the same day is never
    /// removed.
    func removingUnqualifiedResearchEvidence(
        from projectedDays: [AtriaHistoricalDailyConsumerProjection.StepDay]
    ) -> [AtriaHistoricalDailyConsumerProjection.StepDay] {
        guard !AtriaWhoop4GravityCadenceStepModel
                .releaseDailyAuthorityQualified else {
            return projectedDays
        }
        lock.lock()
        let records = loadRecordsLocked()
        lock.unlock()
        guard !records.isEmpty else { return projectedDays }
        return projectedDays.filter { day in
            !records.contains { record in
                abs(day.dayStart.timeIntervalSince(record.windowStart)) < 1
                    && abs(day.dayEnd.timeIntervalSince(
                        record.capturedThrough
                    )) < 1
                    && day.state == .missing
                    && day.stepCount == nil
                    && day.knownStepDeltaSum == record.steps
                    && day.knownEpochCount
                        == (record.decodedRows > 0 ? 1 : 0)
                    && day.rejectedOrUnknownEpochCount == 0
                    && day.knownCoverageSeconds
                        == record.knownCoverageSeconds
                    && day.missingCoverageSeconds
                        == record.missingCoverageSeconds
            }
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

    private static func contentRevision(_ record: Record) -> String? {
        guard let data = try? encode(record) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func canonicalStrapIdentifier(_ value: String) -> String? {
        UUID(uuidString: value)?.uuidString
    }

    private static func valid(_ evidence: HistoricalArchive.MotionTickDayEvidence)
        -> Bool {
        validationFailure(evidence) == nil
    }

    private static func validationFailure(
        _ evidence: HistoricalArchive.MotionTickDayEvidence
    ) -> String? {
        if evidence.windowEnd <= evidence.windowStart {
            return "invalid_window"
        }
        if evidence.capturedThrough < evidence.windowStart {
            return "captured_before_window"
        }
        if evidence.capturedThrough > evidence.windowEnd {
            return "captured_after_window"
        }
        if evidence.motionTicks < 0 { return "negative_motion_ticks" }
        if evidence.steps < 0 { return "negative_steps" }
        if evidence.knownCoverageSeconds <= 0 {
            return "missing_known_coverage"
        }
        if evidence.missingCoverageSeconds < 0 {
            return "negative_missing_coverage"
        }
        if evidence.decodedRows < 2 { return "insufficient_decoded_rows" }
        return nil
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

    private static func isWeaker(
        _ lhs: Record,
        _ rhs: Record
    ) -> Bool {
        if lhs.knownCoverageSeconds != rhs.knownCoverageSeconds {
            return lhs.knownCoverageSeconds < rhs.knownCoverageSeconds
        }
        if lhs.capturedThrough != rhs.capturedThrough {
            return lhs.capturedThrough < rhs.capturedThrough
        }
        return lhs.decodedRows < rhs.decodedRows
    }

    /// 2026-07-31: internal (not private) so history rehydration can apply the
    /// same weaker-record rule when deduplicating rehydrated prior-day
    /// receipts against projected evidence days.
    static func isWeaker(
        _ lhs: AtriaHistoricalDailyConsumerProjection.StepDay,
        _ rhs: AtriaHistoricalDailyConsumerProjection.StepDay
    ) -> Bool {
        if lhs.knownCoverageSeconds != rhs.knownCoverageSeconds {
            return lhs.knownCoverageSeconds < rhs.knownCoverageSeconds
        }
        if lhs.dayEnd != rhs.dayEnd {
            return lhs.dayEnd < rhs.dayEnd
        }
        return lhs.knownEpochCount < rhs.knownEpochCount
    }

    private static func stepDay(
        evidence: HistoricalArchive.MotionTickDayEvidence,
        presentationWindowStart: Date? = nil,
        forcePartial: Bool = false,
        calendar: Calendar
    ) -> AtriaHistoricalDailyConsumerProjection.StepDay {
        let dayStart = presentationWindowStart ?? evidence.windowStart
        let uncoveredPrefix = max(
            0,
            Int(evidence.windowStart.timeIntervalSince(dayStart).rounded(.up))
        )
        let isComplete = !forcePartial
            && evidence.missingCoverageSeconds == 0
            && evidence.capturedThrough >= evidence.windowEnd
        let components = calendar.dateComponents(
            [.year, .month, .day],
            from: dayStart
        )
        // A nonzero firmware counter with a zero gait subtotal means motion
        // was observed but none of its bursts supported a qualified cadence
        // estimate. It is not a verified zero-step lower bound. Preserve the
        // receipt as unresolved evidence so it cannot suppress a later valid
        // count or masquerade as stationary wear.
        let unresolvedObservedMotion =
            evidence.motionTicks > 0 && evidence.steps == 0
        let publishedKnownCoverage = unresolvedObservedMotion
            ? 0 : evidence.knownCoverageSeconds
        let publishedMissingCoverage = unresolvedObservedMotion
            ? max(
                evidence.missingCoverageSeconds,
                Int(evidence.capturedThrough.timeIntervalSince(dayStart).rounded(.up))
            )
            : evidence.missingCoverageSeconds + uncoveredPrefix
        return .init(
            localDay: String(
                format: "%04d-%02d-%02d",
                components.year ?? 0,
                components.month ?? 0,
                components.day ?? 0
            ),
            dayStart: dayStart,
            dayEnd: evidence.capturedThrough,
            state: isComplete && !unresolvedObservedMotion ? .available : .missing,
            stepCount: isComplete && !unresolvedObservedMotion ? evidence.steps : nil,
            knownStepDeltaSum: evidence.steps,
            knownEpochCount: evidence.decodedRows > 0 ? 1 : 0,
            rejectedOrUnknownEpochCount: 0,
            knownCoverageSeconds: publishedKnownCoverage,
            missingCoverageSeconds: publishedMissingCoverage
        )
    }
}
