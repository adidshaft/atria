import Foundation

/// WHOOP 4 recovery drains the strap's bounded flash and resolves only the
/// already-known local interval whose decoded one-hertz coverage passes the
/// durable ≥90% authority. Enabling admission does not claim success: every
/// physical attempt still fails closed unless its own exact coverage proves it.
enum AtriaHistoricalFullDrainCoverageIntegration {
    static let automaticFullDrainRecoveryEnabled = true
    static let exactRangeTransportAuthorityAvailable = false

    /// The persisted-authority resume lane is paused because it is measurably
    /// net-harmful on this transport. Over 5.27 h of continuous draining the
    /// flash cursor advanced at 1.054x realtime (R^2 0.9974) while the lag
    /// behind live shrank by only 11 minutes -- the read pointer is pinned to
    /// the oldest surviving record of a ~14.26-day ring, so the oldest-first
    /// replay closes 0.036 days of lag per day (~309 days to the first
    /// resolvable window). Over the same period the cutovers it performs
    /// created 13 new disconnect gaps totalling 66.4 min of missing live
    /// coverage (45.5% of wall time) while closing zero seconds of the ledger.
    /// Re-enable only once a seek (0x21 read pointer or an exact-range 0x16)
    /// is physically proven to reposition the cursor.
    static let persistedDrainResumeEnabled = false
}

/// Side-effect-free-with-respect-to-BLE coordinator for the durable authority.
/// Callers provide already-observed protocol and storage evidence. The only
/// side effect here is advancing the isolated fsynced authority store.
struct AtriaHistoricalFullDrainCoverageCoordinator {
    typealias Store = AtriaHistoricalFullDrainCoverageStore
    typealias Policy = AtriaHistoricalFullDrainCoveragePolicy

    enum Effect: Equatable, Sendable {
        /// Sending this exact payload is allowed only for the matching permit.
        /// A future adapter must feed the write completion back through
        /// `ackCompleted`; returning this effect does not claim an ACK happened.
        case sendMatchingACK(payload: Data, permit: Store.ACKPermit)
        case historyCompletePersisted
        case coveragePersisted(Policy.CoverageProof)
        case consumerReceiptsPersisted
        case gapResolutionPrepared
        case gapResolutionCommitted
    }

    let store: Store

    func arm(
        gap: Store.PendingGap,
        attempt: Store.Attempt,
        configuration: Policy.Configuration = .production,
        now: Date
    ) throws -> Store.Authority {
        try store.arm(gap: gap,
                      attempt: attempt,
                      configuration: configuration,
                      now: now)
    }

    func historyEndDurablyFsynced(
        identity: Store.EventIdentity,
        boundaryIdentifier: String,
        historyEndPayload: Data,
        expectedACKPayload: Data,
        stores durableStores: Policy.DurableStorePair,
        fsyncedAt: Date
    ) throws -> Effect {
        let permit = try store.recordHistoryEndFsynced(
            identity: identity,
            boundaryIdentifier: boundaryIdentifier,
            historyEndPayload: historyEndPayload,
            expectedACKPayload: expectedACKPayload,
            stores: durableStores,
            fsyncedAt: fsyncedAt
        )
        return .sendMatchingACK(payload: expectedACKPayload, permit: permit)
    }

    @discardableResult
    func ackCompleted(
        identity: Store.EventIdentity,
        permit: Store.ACKPermit,
        actualACKPayload: Data,
        ackAttempt: Int,
        completedAt: Date
    ) throws -> Store.Authority {
        try store.recordMatchingACK(identity: identity,
                                    permit: permit,
                                    actualACKPayload: actualACKPayload,
                                    ackAttempt: ackAttempt,
                                    completedAt: completedAt)
    }

    func historyComplete(
        identity: Store.EventIdentity,
        completionIdentifier: String,
        notificationPayload: Data,
        stores durableStores: Policy.DurableStorePair,
        receivedAt: Date
    ) throws -> Effect {
        _ = try store.recordHistoryComplete(
            identity: identity,
            completionIdentifier: completionIdentifier,
            notificationPayload: notificationPayload,
            stores: durableStores,
            receivedAt: receivedAt
        )
        return .historyCompletePersisted
    }

    /// Decoded timestamps, not frame/row counts, are evaluated and persisted.
    /// The durable raw and identity snapshots must exactly match the terminal
    /// HISTORY_COMPLETE snapshots or the store rejects the proof.
    func proveCoverage(
        identity: Store.EventIdentity,
        decoderIdentifier: String,
        decoderVersion: Int,
        metricTimestampsUnix: [TimeInterval]
    ) throws -> Effect {
        guard let authority = try store.load(),
              let completion = authority.historyComplete else {
            throw Store.StoreError.historyCompleteConflict
        }
        let proof = try Policy.evaluate(
            gapIdentifier: authority.gap.gapIdentifier,
            gapStartUnix: authority.gap.startUnix,
            gapEndUnix: authority.gap.endUnix,
            attemptIdentifier: authority.attempt.attemptIdentifier,
            transportNonce: authority.attempt.transportNonce,
            transportGeneration: authority.attempt.transportGeneration,
            stores: completion.stores,
            decoderIdentifier: decoderIdentifier,
            decoderVersion: decoderVersion,
            metricTimestampsUnix: metricTimestampsUnix,
            configuration: authority.configuration
        )
        _ = try store.recordCoverageProof(identity: identity, proof: proof)
        return .coveragePersisted(proof)
    }

    func consumersCommitted(
        identity: Store.EventIdentity,
        receipts: [Store.ConsumerReceipt],
        committedAt: Date
    ) throws -> Effect {
        _ = try store.recordCommittedConsumers(identity: identity,
                                                receipts: receipts,
                                                committedAt: committedAt)
        return .consumerReceiptsPersisted
    }

    func resolve(
        identity: Store.EventIdentity,
        at resolvedAt: Date
    ) throws -> Effect {
        _ = try store.resolve(identity: identity, at: resolvedAt)
        return .gapResolutionCommitted
    }

    func prepareGapResolution(
        identity: Store.EventIdentity,
        at preparedAt: Date
    ) throws -> Effect {
        _ = try store.prepareGapResolution(identity: identity, at: preparedAt)
        return .gapResolutionPrepared
    }
}
