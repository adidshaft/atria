import Foundation

/// Pure terminal fan-out: one sealed full-flash attempt is evaluated against
/// every other closed local gap. Each result remains independently bound to
/// the exact ledger fingerprint and terminal store identity.
enum AtriaHistoricalTerminalGapReconciliationCoordinator {
    typealias CoverageStore = AtriaHistoricalFullDrainCoverageStore
    typealias Policy = AtriaHistoricalFullDrainCoveragePolicy

    static func evaluate(
        candidates: [AtriaHistoricalGapLedger.RecoveryCandidate],
        excludingGapIdentifier: String,
        authority: CoverageStore.Authority,
        decoderIdentifier: String,
        decoderVersion: Int,
        metricTimestampsUnix: [TimeInterval]
    ) throws -> [CoverageStore.TerminalGapReconciliation] {
        guard let terminal = authority.historyComplete else {
            throw CoverageStore.StoreError.historyCompleteConflict
        }
        return candidates.compactMap { candidate in
            let window = candidate.window
            guard window.id.uuidString.lowercased() != excludingGapIdentifier.lowercased(),
                  let end = window.end else { return nil }
            let gap = CoverageStore.PendingGap(
                gapIdentifier: window.id.uuidString.lowercased(),
                gapLedgerGeneration: candidate.ledgerGeneration,
                gapLedgerSnapshotSHA256: candidate.ledgerSnapshotSHA256,
                startUnix: window.start.timeIntervalSince1970,
                endUnix: end.timeIntervalSince1970,
                reason: window.reason,
                pending: true
            )
            do {
                let proof = try Policy.evaluate(
                    gapIdentifier: gap.gapIdentifier,
                    gapStartUnix: gap.startUnix,
                    gapEndUnix: gap.endUnix,
                    attemptIdentifier: authority.attempt.attemptIdentifier,
                    transportNonce: authority.attempt.transportNonce,
                    transportGeneration: authority.attempt.transportGeneration,
                    stores: terminal.stores,
                    decoderIdentifier: decoderIdentifier,
                    decoderVersion: decoderVersion,
                    metricTimestampsUnix: metricTimestampsUnix,
                    configuration: authority.configuration
                )
                return .init(gap: gap,
                             coverageProof: proof,
                             rejectionReason: nil,
                             resolutionPreparedAtUnix: nil,
                             resolvedAtUnix: nil,
                             status: .coverageProven)
            } catch {
                return .init(gap: gap,
                             coverageProof: nil,
                             rejectionReason: String(describing: error),
                             resolutionPreparedAtUnix: nil,
                             resolvedAtUnix: nil,
                             status: .rejected)
            }
        }.sorted { $0.gap.startUnix < $1.gap.startUnix }
    }
}
