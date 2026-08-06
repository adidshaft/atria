import CryptoKit
import Foundation

/// Independently durable exact replay keys for a sealed raw chunk.
///
/// The live derived identity index intentionally expires after 14 days. This
/// immutable shard does not: it is the restart-safe truth required before raw
/// retirement and is queried alongside retained raw/catalog history.
struct AtriaHistoricalReplayIdentityShard: Codable, Equatable, Sendable {
    static let currentSchema = 1
    static let algorithmVersion = "exact-history-identity-v2-shard-v1"
    static let configurationSHA256: String = {
        SHA256.hash(data: Data(algorithmVersion.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }()
    /// A sealed raw catalog chunk is capped at 32 MiB. The retained shard must
    /// be materially smaller than the source it replaces; otherwise retirement
    /// fails closed and raw remains authoritative.
    static let maximumRetainedArtifactBytes = 24 * 1_024 * 1_024
    static let minimumSmallArtifactAllowanceBytes = 64 * 1_024
    static let maximumArtifactToRawNumerator: UInt64 = 3
    static let maximumArtifactToRawDenominator: UInt64 = 4

    struct Source: Codable, Equatable, Sendable {
        let chunkID: String
        let rawSHA256: String
        let rawRowCount: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let stableKey: String
        let observedAtUnix: TimeInterval
    }

    enum ShardError: Error, Equatable {
        case sourceMissing
        case sourceDigestMismatch
        case tornTrailingRow
        case rowCountMismatch(expected: Int, actual: Int)
        case missingExactIdentity(row: Int)
        case duplicateIdentity
        case invalidArtifact
        case retainedArtifactTooLarge(maximum: UInt64, actual: UInt64)
    }

    let schema: Int
    let source: Source
    let entries: [Entry]

    func contains(stableKey: String) -> Bool {
        entries.binarySearch { $0.stableKey < stableKey }
            .map { entries[$0].stableKey == stableKey } ?? false
    }

    static func build(sourceURL: URL,
                      source: AtriaHistoricalAggregateChunk.Source) throws -> AtriaHistoricalReplayIdentityShard {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ShardError.sourceMissing
        }
        guard try AtriaHistoricalJSONLInput.identity(at: sourceURL).sha256 == source.rawSHA256 else {
            throw ShardError.sourceDigestMismatch
        }
        var entries: [Entry] = []
        entries.reserveCapacity(source.rawRowCount)
        var row = 0
        try streamLines(at: sourceURL) { line in
            guard let identity = AtriaHistoricalArchiveDurableStore.decoratedIdentity(from: line) else {
                throw ShardError.missingExactIdentity(row: row)
            }
            entries.append(.init(stableKey: identity.key,
                                 observedAtUnix: identity.observedAtUnix))
            row += 1
        }
        guard row == source.rawRowCount else {
            throw ShardError.rowCountMismatch(expected: source.rawRowCount, actual: row)
        }
        entries.sort { $0.stableKey < $1.stableKey }
        guard Set(entries.map(\.stableKey)).count == entries.count else {
            throw ShardError.duplicateIdentity
        }
        return .init(schema: currentSchema,
                     source: .init(chunkID: source.chunkID,
                                   rawSHA256: source.rawSHA256,
                                   rawRowCount: source.rawRowCount),
                     entries: entries)
    }

    func encodedArtifact() throws -> Data {
        guard schema == Self.currentSchema,
              entries.count == source.rawRowCount,
              Set(entries.map(\.stableKey)).count == entries.count,
              entries == entries.sorted(by: { $0.stableKey < $1.stableKey }) else {
            throw ShardError.invalidArtifact
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decodeAndVerify(_ artifact: Data,
                                sourceURL: URL,
                                source: AtriaHistoricalAggregateChunk.Source) throws -> AtriaHistoricalReplayIdentityShard {
        let decoded = try decodeRetainedArtifact(artifact, source: source)
        let rebuilt = try build(sourceURL: sourceURL, source: source)
        guard decoded == rebuilt,
              try decoded.encodedArtifact() == artifact else {
            throw ShardError.invalidArtifact
        }
        return decoded
    }

    /// Publishes the first genuine consumer artifact used by raw retirement.
    /// Nonempty schema-v2 raw cannot claim an empty replay-identity result.
    static func publishReceipt(
        sourceURL: URL,
        source: AtriaHistoricalAggregateChunk.Source,
        ledger: AtriaHistoricalConsumerReceiptLedger,
        settledAt: Date
    ) throws -> AtriaHistoricalConsumerReceiptLedger.Published {
        let shard = try build(sourceURL: sourceURL, source: source)
        let artifact = try shard.encodedArtifact()
        let maximum = maximumRetainedBytes(forRawBytes: source.rawByteCount)
        guard UInt64(artifact.count) <= maximum else {
            throw ShardError.retainedArtifactTooLarge(
                maximum: maximum,
                actual: UInt64(artifact.count)
            )
        }
        let ledgerSource = AtriaHistoricalConsumerReceiptLedger.Source(
            chunkID: source.chunkID,
            rawSHA256: source.rawSHA256,
            firstTimestamp: source.firstTimestamp,
            lastTimestamp: source.lastTimestamp
        )
        return try ledger.publish(.init(
            source: ledgerSource,
            kind: .replayIdentity,
            consumerSchemaVersion: currentSchema,
            algorithmVersion: algorithmVersion,
            configurationSHA256: configurationSHA256,
            dependencyStart: source.firstTimestamp,
            dependencyEnd: source.lastTimestamp,
            completionWatermark: source.lastTimestamp,
            outcome: .materialized,
            recordCount: shard.entries.count,
            artifact: artifact,
            settledAt: settledAt
        ))
    }

    static func verifyReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        sourceURL: URL,
        source: AtriaHistoricalAggregateChunk.Source
    ) throws -> Bool {
        guard try verifyRetainedReceipt(receipt,
                                        artifact: artifact,
                                        source: source) else {
            return false
        }
        let rebuilt = try build(sourceURL: sourceURL, source: source)
        return try rebuilt.encodedArtifact() == artifact
    }

    /// Verifies the independently retained replay shard after raw retirement.
    /// Before deletion `verifyReceipt` additionally rebuilds this shard from
    /// raw. After a crash between raw unlink and catalog retirement, the
    /// transaction manifest plus this canonical, source-bound artifact are the
    /// only restart-safe evidence available; accepting arbitrary receipt-shaped
    /// bytes here would defeat exact replay protection.
    static func verifyRetainedReceipt(
        _ receipt: AtriaHistoricalConsumerReceiptLedger.Receipt,
        artifact: Data,
        source: AtriaHistoricalAggregateChunk.Source
    ) throws -> Bool {
        guard receipt.kind == .replayIdentity,
              receipt.consumerSchemaVersion == currentSchema,
              receipt.algorithmVersion == algorithmVersion,
              receipt.configurationSHA256 == configurationSHA256,
              receipt.source.chunkID == source.chunkID,
              receipt.source.rawSHA256 == source.rawSHA256,
              receipt.source.firstTimestamp == source.firstTimestamp,
              receipt.source.lastTimestamp == source.lastTimestamp,
              receipt.dependencyStart == source.firstTimestamp,
              receipt.dependencyEnd == source.lastTimestamp,
              receipt.completionWatermark >= source.lastTimestamp,
              receipt.outcome == .materialized,
              receipt.recordCount == source.rawRowCount,
              UInt64(artifact.count) == receipt.artifactByteCount else {
            return false
        }
        let decoded = try decodeRetainedArtifact(artifact, source: source)
        guard decoded.schema == currentSchema,
              decoded.source == .init(chunkID: source.chunkID,
                                      rawSHA256: source.rawSHA256,
                                      rawRowCount: source.rawRowCount),
              decoded.entries.count == source.rawRowCount,
              decoded.entries == decoded.entries.sorted(by: {
                  $0.stableKey < $1.stableKey
              }),
              Set(decoded.entries.map(\.stableKey)).count == decoded.entries.count,
              decoded.entries.allSatisfy({
                  !$0.stableKey.isEmpty && $0.observedAtUnix.isFinite
              }),
              try decoded.encodedArtifact() == artifact else {
            throw ShardError.invalidArtifact
        }
        return true
    }

    static func decodeRetainedArtifact(
        _ artifact: Data,
        source: AtriaHistoricalAggregateChunk.Source
    ) throws -> Self {
        let maximum = maximumRetainedBytes(forRawBytes: source.rawByteCount)
        guard UInt64(artifact.count) <= maximum else {
            throw ShardError.retainedArtifactTooLarge(
                maximum: maximum,
                actual: UInt64(artifact.count)
            )
        }
        let decoded: Self
        do {
            decoded = try JSONDecoder().decode(Self.self, from: artifact)
        } catch {
            throw ShardError.invalidArtifact
        }
        guard decoded.source == .init(chunkID: source.chunkID,
                                      rawSHA256: source.rawSHA256,
                                      rawRowCount: source.rawRowCount) else {
            throw ShardError.invalidArtifact
        }
        return decoded
    }

    static func maximumRetainedBytes(forRawBytes rawBytes: UInt64) -> UInt64 {
        let proportional = rawBytes.multipliedReportingOverflow(
            by: maximumArtifactToRawNumerator
        )
        let scaled = proportional.overflow
            ? UInt64.max
            : proportional.partialValue / maximumArtifactToRawDenominator
        return min(UInt64(maximumRetainedArtifactBytes),
                   max(UInt64(minimumSmallArtifactAllowanceBytes), scaled))
    }

    private static func streamLines(at url: URL,
                                    visit: (Data) throws -> Void) throws {
        do {
            try AtriaHistoricalJSONLInput.forEachLine(
                at: url,
                includeTrailingNewline: true,
                consume: visit
            )
        } catch AtriaHistoricalSealedJSONLCompression.TransactionError.tornTrailingRow {
            throw ShardError.tornTrailingRow
        }
    }
}

private extension Array {
    /// First index whose element does not satisfy `isOrderedBeforeTarget`.
    func binarySearch(isOrderedBeforeTarget: (Element) -> Bool) -> Int? {
        guard !isEmpty else { return nil }
        var lower = 0
        var upper = count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if isOrderedBeforeTarget(self[middle]) {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return lower < count ? lower : nil
    }
}
