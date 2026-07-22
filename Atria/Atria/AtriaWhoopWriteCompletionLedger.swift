/// Single-flight identity for CoreBluetooth writes performed with response.
///
/// `didWriteValueFor` reports only the characteristic, not the bytes that
/// completed. A timeout makes the connection ambiguous: queueing another write
/// would let a late callback for the first command confirm the second one. One
/// outstanding entry is therefore the maximum safe correlation state.
struct AtriaWhoopWriteCompletionLedger: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let sequence: UInt8
        let command: UInt8
        let payload: [UInt8]

        init(sequence: UInt8, command: UInt8, payload: [UInt8] = []) {
            self.sequence = sequence
            self.command = command
            self.payload = payload
        }
    }

    private(set) var pending: [Entry] = []

    var hasPendingWrite: Bool {
        !pending.isEmpty
    }

    @discardableResult
    mutating func enqueue(sequence: UInt8,
                          command: UInt8,
                          payload: [UInt8] = []) -> Bool {
        guard pending.isEmpty else { return false }
        pending.append(Entry(sequence: sequence,
                             command: command,
                             payload: payload))
        return true
    }

    mutating func completeNext() -> Entry? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
    }
}
