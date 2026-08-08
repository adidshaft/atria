import Foundation

/// Cooperative CPU duty-cycle for a background archive-projection pass.
///
/// Archive projection was foreground-only because the recovered scan / HR
/// projection throttle MEMORY (per-stage dying threads, `malloc_zone_pressure_relief`,
/// the recompute fence's inter-cycle rest) but do ZERO CPU throttling — a long
/// background pass ran the worker at ~100% and tripped iOS's sustained-CPU
/// watchdog (`cpu_resource_fatal`). This adds the missing ~50% duty cycle so a
/// background pass stays under the watchdog no matter how long it runs.
///
/// Lifecycle: `begin(budgetSeconds:)` before a guarded background pass, `end()`
/// after. While active, the scan's existing per-chunk progress hook calls
/// `cooperativeCheckpointShouldAbort` — which sleeps the (dying, off-main) scan
/// thread to hold average CPU near 50%. It is a NO-OP when inactive, so the
/// foreground/live scan path is completely unaffected. A hard max-active window
/// deactivates a leaked state so it can never throttle legitimate foreground
/// work; per-pass byte budgets keep any single real scan far under that cap.
final class AtriaBackgroundProjectionThrottle {
    static let shared = AtriaBackgroundProjectionThrottle()

    private let lock = NSLock()
    private var active = false
    private var cancelled = false
    private var beginUptime: TimeInterval = 0
    private var deadline: TimeInterval = 0
    private var sliceStart: TimeInterval = 0
    private var sliceFrames = 0

    /// Matches the orphan-replay cooperative batch (AtriaBLEManager) so both
    /// heavy off-main scans yield on the same cadence.
    private static let cooperativeBatchSize = 64
    /// Backstop: never let a leaked `active` state throttle work longer than any
    /// real BGProcessingTask window. Per-pass byte budgets keep a single scan
    /// pass far under this, so it never fires mid-legitimate-scan.
    private static let maximumActiveWindow: TimeInterval = 600

    func begin(budgetSeconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        active = true
        cancelled = false
        beginUptime = now
        sliceStart = now
        deadline = now + max(0, budgetSeconds)
        sliceFrames = 0
    }

    /// Signal the pass to abort at its next checkpoint (e.g. from a BGTask
    /// expiration handler). CPU safety does not depend on this being honored —
    /// the duty cycle keeps running while active.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    func end() {
        lock.lock(); active = false; cancelled = false; lock.unlock()
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    /// MUST be called only off the main thread (the projection scan runs on a
    /// dying `AtriaTransientWorkThread`). While a background pass is active this
    /// sleeps the worker on a ~50% duty cycle every `cooperativeBatchSize`
    /// candidate lines. Returns `true` when the caller should abort (budget
    /// elapsed or cancelled); callers may ignore it — the process is suspended
    /// when its BGTask window ends, and CPU stays bounded until then.
    @discardableResult
    func cooperativeCheckpointShouldAbort(processedDelta: Int = 1) -> Bool {
        // Never sleep the main thread, even if some future scan path is on-main:
        // the duty cycle is only ever meant for the dying snapshot thread.
        if Thread.isMainThread { return false }
        lock.lock()
        guard active else { lock.unlock(); return false }
        let now = ProcessInfo.processInfo.systemUptime
        // Leaked-state backstop: stop throttling rather than throttle forever.
        if now - beginUptime > Self.maximumActiveWindow {
            active = false
            lock.unlock()
            return true
        }
        let shouldAbort = cancelled || now >= deadline
        sliceFrames += max(0, processedDelta)
        let frames = sliceFrames
        let elapsed = now - sliceStart
        let pause = frames >= Self.cooperativeBatchSize
            ? AtriaBLEManager.orphanHistoryReplayPauseDuration(
                workDuration: elapsed,
                processedFrames: frames)
            : 0
        lock.unlock()
        if pause > 0 {
            Thread.sleep(forTimeInterval: pause)
            lock.lock()
            sliceStart = ProcessInfo.processInfo.systemUptime
            sliceFrames = 0
            lock.unlock()
        }
        return shouldAbort
    }
}
