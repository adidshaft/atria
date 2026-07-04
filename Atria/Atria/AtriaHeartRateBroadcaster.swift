import CoreBluetooth
import Foundation

struct AtriaHeartRateBroadcastPreference {
    static let storageKey = "atria.heartRateBroadcast.alwaysEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: storageKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: storageKey)
    }
}

@MainActor
final class AtriaHeartRateBroadcaster: NSObject, ObservableObject {
    @Published private(set) var isBroadcasting = false
    @Published private(set) var peripheralState: CBManagerState = .unknown

    static let debugStatusKey = "atria.debug.hrBroadcast.status"
    static let debugSentCountKey = "atria.debug.hrBroadcast.sentCount"
    static let debugLastBPMKey = "atria.debug.hrBroadcast.lastBPM"
    static let debugLastReasonKey = "atria.debug.hrBroadcast.reason"

    private static let serviceUUID = CBUUID(string: "180D")
    private static let measurementUUID = CBUUID(string: "2A37")
    private static let sensorLocationUUID = CBUUID(string: "2A38")

    private lazy var peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
    private var measurementCharacteristic: CBMutableCharacteristic?
    private var lastSentHeartRate: Int?
    private var lastSentAt: Date?
    private var shouldBroadcast = false

    func setEnabled(_ enabled: Bool) {
        shouldBroadcast = enabled
        _ = peripheralManager
        if enabled {
            startIfReady()
        } else {
            stop()
        }
    }

    func publish(heartRate: Int, rrIntervalsMS: [Int] = [], now: Date = Date()) {
        guard shouldBroadcast,
              isBroadcasting,
              heartRate > 0,
              heartRate <= UInt8.max,
              let measurementCharacteristic else { return }
        if lastSentHeartRate == heartRate,
           let lastSentAt,
           now.timeIntervalSince(lastSentAt) < 1 {
            return
        }
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < 1 {
            return
        }

        let payload = Self.measurementPayload(heartRate: heartRate, rrIntervalsMS: rrIntervalsMS)
        guard peripheralManager.updateValue(payload, for: measurementCharacteristic, onSubscribedCentrals: nil) else {
            // Throttle the failure path like the success path: without setting
            // lastSentAt, back-to-back publish calls each retried and rewrote
            // these defaults keys, and unthrottled `atria.*` writes feed the
            // dotted-key KVO storm described in AtriaHomeView.
            lastSentAt = now
            if UserDefaults.standard.string(forKey: Self.debugStatusKey) != "send_backpressure" {
                UserDefaults.standard.set("send_backpressure", forKey: Self.debugStatusKey)
                UserDefaults.standard.set(heartRate, forKey: Self.debugLastBPMKey)
            }
            return
        }
        lastSentHeartRate = heartRate
        lastSentAt = now
        let sentCount = UserDefaults.standard.integer(forKey: Self.debugSentCountKey) + 1
        UserDefaults.standard.set("sent", forKey: Self.debugStatusKey)
        UserDefaults.standard.set(sentCount, forKey: Self.debugSentCountKey)
        UserDefaults.standard.set(heartRate, forKey: Self.debugLastBPMKey)
        AtriaDebugLog("ATRIADBG hr_broadcast status=sent bpm=%d rr=%d", heartRate, rrIntervalsMS.count)
    }

    private func startIfReady() {
        guard shouldBroadcast else { return }
        guard peripheralManager.state == .poweredOn else {
            UserDefaults.standard.set("waiting", forKey: Self.debugStatusKey)
            UserDefaults.standard.set("peripheral_state_\(peripheralManager.state.rawValue)", forKey: Self.debugLastReasonKey)
            AtriaDebugLog("ATRIADBG hr_broadcast status=waiting state=%ld", peripheralManager.state.rawValue)
            return
        }

        let measurement = CBMutableCharacteristic(type: Self.measurementUUID,
                                                  properties: [.notify],
                                                  value: nil,
                                                  permissions: [])
        let location = CBMutableCharacteristic(type: Self.sensorLocationUUID,
                                               properties: [.read],
                                               value: Data([0x02]),
                                               permissions: [.readable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [measurement, location]
        measurementCharacteristic = measurement

        peripheralManager.removeAllServices()
        peripheralManager.add(service)
    }

    private func advertise() {
        guard shouldBroadcast, peripheralManager.state == .poweredOn else { return }
        peripheralManager.stopAdvertising()
        peripheralManager.startAdvertising([
            CBAdvertisementDataLocalNameKey: "Atria HR",
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
        ])
        isBroadcasting = true
        UserDefaults.standard.set("advertising", forKey: Self.debugStatusKey)
        UserDefaults.standard.set("Atria HR", forKey: Self.debugLastReasonKey)
        AtriaDebugLog("ATRIADBG hr_broadcast status=advertising name=Atria_HR")
    }

    private func stop() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        measurementCharacteristic = nil
        lastSentHeartRate = nil
        lastSentAt = nil
        isBroadcasting = false
        UserDefaults.standard.set("stopped", forKey: Self.debugStatusKey)
        AtriaDebugLog("ATRIADBG hr_broadcast status=stopped")
    }

    private static func measurementPayload(heartRate: Int, rrIntervalsMS: [Int]) -> Data {
        var bytes: [UInt8] = [rrIntervalsMS.isEmpty ? 0x00 : 0x10, UInt8(clamping: heartRate)]
        for interval in rrIntervalsMS.prefix(4) {
            let rr = UInt16(clamping: Int((Double(interval) / 1_000.0 * 1_024.0).rounded()))
            bytes.append(UInt8(rr & 0x00ff))
            bytes.append(UInt8((rr & 0xff00) >> 8))
        }
        return Data(bytes)
    }
}

extension AtriaHeartRateBroadcaster: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @MainActor in
            peripheralState = peripheral.state
            if peripheral.state == .poweredOn {
                startIfReady()
            } else if isBroadcasting {
                stop()
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                isBroadcasting = false
                AtriaDebugLog("ATRIADBG hr_broadcast status=service_failed error=%@", String(describing: error))
                return
            }
            advertise()
        }
    }
}
