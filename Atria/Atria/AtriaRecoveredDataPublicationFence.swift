import Foundation

/// Main-actor completion fence for revisioned recovered-data publication.
///
/// The archive projection/recompute coordinator decides whether a revision may
/// publish. This type owns only the externally observable revision and waiter
/// lifecycle, keeping continuation and timeout bookkeeping out of SessionStore.
@MainActor
final class AtriaRecoveredDataPublicationFence {
    private struct Waiter {
        let targetRevision: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private(set) var archiveRevision: UInt64 = 0
    private(set) var lastPublishedRevision: UInt64 = 0
    private var waiters: [UUID: Waiter] = [:]

    deinit {
        let continuations = waiters.values.map(\.continuation)
        waiters.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume(returning: false) }
    }

    @discardableResult
    func recordArchiveUpdate() -> UInt64 {
        archiveRevision &+= 1
        return archiveRevision
    }

    /// Waits for the newest revision currently known to the fence. A caller
    /// observing no newer revision has no recovered-data work to await.
    func awaitPublication(
        after priorRevision: UInt64,
        timeout: Duration
    ) async -> Bool {
        let targetRevision = archiveRevision
        guard targetRevision > priorRevision else { return true }
        guard lastPublishedRevision < targetRevision else { return true }

        return await withCheckedContinuation { continuation in
            let id = UUID()
            waiters[id] = Waiter(targetRevision: targetRevision,
                                 continuation: continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishWaiter(id: id, succeeded: false)
            }
        }
    }

    func publish(through revision: UInt64) {
        lastPublishedRevision = max(lastPublishedRevision, revision)
        finishWaiters(through: revision, succeeded: true)
    }

    func fail(through revision: UInt64) {
        finishWaiters(through: revision, succeeded: false)
    }

    func failAll() {
        finishWaiters(through: .max, succeeded: false)
    }

    private func finishWaiter(id: UUID, succeeded: Bool) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: succeeded)
    }

    private func finishWaiters(through revision: UInt64, succeeded: Bool) {
        let ids = waiters.compactMap { id, waiter in
            waiter.targetRevision <= revision ? id : nil
        }
        ids.forEach { finishWaiter(id: $0, succeeded: succeeded) }
    }
}
