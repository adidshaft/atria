import Foundation

/// Amortized-O(1) FIFO used on the BLE callback path. `Array.removeFirst()`
/// copies every queued element and becomes quadratic when a strap serves a
/// large retained history in one connection epoch.
struct AtriaFIFOBuffer<Element> {
    private var storage: [Element] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }
    var first: Element? { head < storage.count ? storage[head] : nil }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    @discardableResult
    mutating func popFirst() -> Element? {
        guard head < storage.count else { return nil }
        let element = storage[head]
        head += 1
        compactIfNeeded()
        return element
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        head = 0
    }

    private mutating func compactIfNeeded() {
        guard head > 0 else { return }
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 4_096, head * 2 >= storage.count {
            storage.removeFirst(head)
            head = 0
        }
    }
}
