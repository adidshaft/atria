import Foundation

/// Ticket-scoped undo journal for recovered-data recomputation.
///
/// The recompute coordinator deliberately performs several asynchronous steps.
/// A dashboard revision fence alone is insufficient because those steps also
/// update canonical caches and durable projections before the last component
/// reports success. The owner records an inverse operation immediately before
/// each such mutation. A failed or superseded ticket replays the inverses in
/// reverse order; a published ticket discards them.
///
/// This type is main-actor confined because its operations close over
/// main-actor-owned SessionStore state. Ticket identity prevents a late callback
/// from a failed generation from registering an undo against its replacement.
@MainActor
final class AtriaRecoveredDataMutationTransaction {
    typealias Ticket = AtriaRecoveredDataRecomputeCoordinator.Ticket

    private struct Active {
        let ticket: Ticket
        var rollbackOperations: [() -> Void]
        var commitOperations: [() -> Void]
    }

    private var active: Active?

    var activeTicket: Ticket? { active?.ticket }
    var rollbackOperationCount: Int { active?.rollbackOperations.count ?? 0 }

    @discardableResult
    func begin(ticket: Ticket) -> Bool {
        guard active == nil else { return false }
        active = Active(ticket: ticket,
                        rollbackOperations: [],
                        commitOperations: [])
        return true
    }

    /// Defers an externally observable side effect until the exact ticket has
    /// crossed every derived component. Persistence cleanup notifications and
    /// learned duty-cycle hints use this instead of leaking from preparation.
    @discardableResult
    func registerCommit(
        ticket: Ticket,
        _ operation: @escaping () -> Void
    ) -> Bool {
        guard var current = active, current.ticket == ticket else { return false }
        current.commitOperations.append(operation)
        active = current
        return true
    }

    /// Registers an inverse immediately before its matching mutation.
    /// Returns false for stale callbacks so their mutation can be rejected too.
    @discardableResult
    func registerRollback(
        ticket: Ticket,
        _ operation: @escaping () -> Void
    ) -> Bool {
        guard var current = active, current.ticket == ticket else { return false }
        current.rollbackOperations.append(operation)
        active = current
        return true
    }

    /// Discards all inverse operations only when the exact ticket publishes.
    @discardableResult
    func commit(ticket: Ticket) -> Bool {
        guard let current = active, current.ticket == ticket else { return false }
        active = nil
        for operation in current.commitOperations {
            operation()
        }
        return true
    }

    /// Replays inverses newest-first. Clearing active state before invoking
    /// client code makes rollback re-entrant safe and rejects late callbacks.
    @discardableResult
    func rollback(ticket: Ticket) -> Bool {
        guard let current = active, current.ticket == ticket else { return false }
        active = nil
        for operation in current.rollbackOperations.reversed() {
            operation()
        }
        return true
    }
}
