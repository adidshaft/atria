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

    /// Physical iPhone 15 Pro evidence under simultaneous BLE history and disk
    /// contention measured 95.923 seconds for the first derived component.
    /// 150 seconds provides 54 seconds (56%) of headroom while remaining finite.
    static let physicalSessionStore = AtriaRecoveredDataTimeoutPolicy(
        projectionLeaseSeconds: 90,
        derivedComponentLeaseSeconds: 150,
        publicationSchedulingGraceSeconds: 30
    )

    func maximumPipelineSeconds(requiredDerivedComponentCount: Int) -> Int {
        projectionLeaseSeconds
            + max(0, requiredDerivedComponentCount) * derivedComponentLeaseSeconds
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
