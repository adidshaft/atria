import Foundation

/// Issues callback-order tickets on CoreBluetooth's delegate queue. The lock
/// keeps the invariant valid if the queue configuration changes later.
final class AtriaBLECallbackTicketIssuer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextTicket: UInt64 = 1

    func issue() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let ticket = nextTicket
        if nextTicket < UInt64.max {
            nextTicket += 1
        }
        return ticket
    }
}

/// Reorders independently scheduled MainActor applications back into the
/// exact delegate-entry order. Duplicate/stale tickets are ignored. A missing
/// earlier callback holds later work instead of applying metadata/data out of
/// order at a historical batch boundary.
struct AtriaBLEOrderedCallbackBuffer<Element> {
    private(set) var nextExpectedTicket: UInt64 = 1
    private var pending: [UInt64: Element] = [:]

    mutating func enqueue(ticket: UInt64, element: Element) -> [Element] {
        guard ticket >= nextExpectedTicket,
              pending[ticket] == nil else { return [] }
        pending[ticket] = element
        var ready: [Element] = []
        while let element = pending.removeValue(forKey: nextExpectedTicket) {
            ready.append(element)
            if nextExpectedTicket == UInt64.max { break }
            nextExpectedTicket += 1
        }
        return ready
    }
}
