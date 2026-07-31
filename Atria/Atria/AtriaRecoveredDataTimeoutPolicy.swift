import Foundation

/// Finite leases for the recovered-data publication fence.
///
/// A lease measures lack of progress, not total cascade wall time. Every real
/// derived-component completion renews the derived lease. The publication wait
/// bound covers the worst case where all required components complete just
/// inside their individual leases.
struct AtriaRecoveredDataTimeoutPolicy: Equatable, Sendable {
    let projectionLeaseSeconds: Int
    let derivedComponentLeaseSeconds: Int
    let publicationSchedulingGraceSeconds: Int
    let maximumProjectionLeaseRenewals: Int
    let maximumDerivedStageLeaseRenewals: Int
    let projectionLeaseRenewalMinimumBytes: Int
    let projectionLeaseRenewalMinimumIntervalSeconds: Int

    /// Physical iPhone 15 Pro Release evidence under simultaneous live BLE and
    /// archive I/O measured the recovered projection exceeding the old
    /// 90-second lease, which expired at exactly 90 seconds before completion.
    /// A 150-second projection lease preserves a finite fail-closed watchdog
    /// while providing at least 1.5x headroom over the 95.923-second measured
    /// pipeline milestone. Derived components use the same bounded lease.
    static let physicalSessionStore = AtriaRecoveredDataTimeoutPolicy(
        projectionLeaseSeconds: 150,
        derivedComponentLeaseSeconds: 150,
        publicationSchedulingGraceSeconds: 30,
        maximumProjectionLeaseRenewals: 8,
        maximumDerivedStageLeaseRenewals: 5,
        projectionLeaseRenewalMinimumBytes: 8 * 1_024 * 1_024,
        projectionLeaseRenewalMinimumIntervalSeconds: 75
    )

    func maximumPipelineSeconds(requiredDerivedComponentCount: Int) -> Int {
        (1 + max(0, maximumProjectionLeaseRenewals)) * projectionLeaseSeconds
            + max(0, requiredDerivedComponentCount) * derivedComponentLeaseSeconds
            + max(0, maximumDerivedStageLeaseRenewals) * derivedComponentLeaseSeconds
            + publicationSchedulingGraceSeconds
    }

    func publicationWaitSeconds(
        requestedSeconds: Int,
        requiredDerivedComponentCount: Int
    ) -> Int {
        max(requestedSeconds,
            maximumPipelineSeconds(requiredDerivedComponentCount: requiredDerivedComponentCount))
    }
}
