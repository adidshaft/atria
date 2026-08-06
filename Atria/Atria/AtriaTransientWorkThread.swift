import Foundation

/// Runs a blocking chunk of allocation-heavy work on a fresh thread that DIES
/// when the work ends, and blocks the caller until it does.
///
/// Why this exists (2026-08-04 memory-balloon endgame): on the device's
/// iOS 27.0 beta, the allocator returns a worker's transient garbage only at
/// THREAD TEARDOWN — not at autoreleasepool drains, not via
/// malloc_zone_pressure_relief, not after naps. Long-lived workers (GCD queue
/// threads, the Swift-concurrency cooperative pool) therefore accumulate every
/// burst they ever ran until the process hits the 3.4GB jetsam ceiling. Any
/// stage that churns tens of thousands of transient allocations (archive
/// scans, projections, verified-consumer reads, step-evidence sweeps) must run
/// through this helper so its garbage has a place to die.
///
/// The caller's execution order is unchanged — this is purely a lifetime
/// boundary for memory, at the cost of one thread spawn (~100µs).
enum AtriaTransientWorkThread {
    static func run(name: String,
                    qualityOfService: QualityOfService = .userInitiated,
                    _ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            body()
            done.signal()
        }
        thread.name = name
        thread.qualityOfService = qualityOfService
        thread.start()
        done.wait()
    }

    /// Same lifetime boundary for work that returns a value.
    static func run<T>(name: String,
                       qualityOfService: QualityOfService = .userInitiated,
                       _ body: @escaping () -> T) -> T {
        var result: T?
        run(name: name, qualityOfService: qualityOfService) {
            result = body()
        }
        // The semaphore wait above guarantees assignment.
        return result!
    }
}
