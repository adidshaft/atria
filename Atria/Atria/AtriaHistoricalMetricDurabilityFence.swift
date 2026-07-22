import Foundation

/// Holds metric evidence behind the same durable boundary that gates a WHOOP
/// history ACK. An archive append is not allowed to retire a missing-data gap:
/// only a successful generation-matching flush releases its timestamps.
struct AtriaHistoricalMetricDurabilityFence: Equatable, Sendable {
    struct Fact: Equatable, Sendable {
        let effectiveUnix: UInt32
    }

    private(set) var generation: UInt64?
    private var pendingFacts: [Fact] = []

    mutating func begin(generation newGeneration: UInt64) {
        guard generation == nil || newGeneration > generation! else { return }
        generation = newGeneration
        pendingFacts.removeAll(keepingCapacity: true)
    }

    mutating func recordPersistedMetric(
        generation eventGeneration: UInt64,
        metricUsable: Bool,
        effectiveUnix: UInt32?
    ) {
        guard generation == eventGeneration,
              metricUsable,
              let effectiveUnix else { return }
        pendingFacts.append(Fact(effectiveUnix: effectiveUnix))
    }

    /// Releases every fact accumulated since the preceding durable boundary.
    /// A failed or stale flush releases nothing; a newer `begin` discards the
    /// old generation so callbacks from a dead BLE link cannot leak forward.
    mutating func durableFlushCompleted(
        generation eventGeneration: UInt64,
        succeeded: Bool
    ) -> [Fact] {
        guard generation == eventGeneration, succeeded else { return [] }
        defer { pendingFacts.removeAll(keepingCapacity: true) }
        return pendingFacts
    }

    mutating func invalidate(generation eventGeneration: UInt64) {
        guard generation == eventGeneration else { return }
        pendingFacts.removeAll(keepingCapacity: true)
    }
}
