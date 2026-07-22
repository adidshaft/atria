import Foundation

/// Rejects work enqueued by a CoreBluetooth callback after its connection has
/// died. Delegate entry captures the returned epoch synchronously; delayed
/// main-actor work must still match both that epoch and the active peripheral.
struct AtriaBLECallbackEpochFence: Equatable, Sendable {
    private(set) var epoch: UInt64 = 0
    private(set) var activePeripheralID: UUID?

    mutating func activate(peripheralID: UUID) -> UInt64 {
        epoch &+= 1
        activePeripheralID = peripheralID
        return epoch
    }

    @discardableResult
    mutating func invalidate(ifMatching peripheralID: UUID? = nil) -> UInt64 {
        if let peripheralID, activePeripheralID != peripheralID { return epoch }
        epoch &+= 1
        activePeripheralID = nil
        return epoch
    }

    func accepts(
        callbackEpoch: UInt64,
        peripheralID: UUID,
        peripheralConnected: Bool
    ) -> Bool {
        callbackEpoch == epoch
            && peripheralID == activePeripheralID
            && peripheralConnected
    }
}
