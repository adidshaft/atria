import CoreBluetooth
import Foundation

struct LogLine: Identifiable, Equatable {
    let id = UUID()
    var time: String
    var kind: String
    var detail: String
}

struct PendingCommand {
    var name: String
    var opcode: UInt8
    var payload: [UInt8]
}

final class StrapLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Idle"
    @Published var deviceName = "—"
    @Published var heartRate: Int?
    @Published var battery: Int?
    @Published var lastReply = "No command yet"
    @Published var compactCount = 0
    @Published var backfillCount = 0
    @Published var leftoverCount = 0
    @Published var proprietaryHRCount = 0
    @Published var heartRateCount = 0
    @Published var lines: [LogLine] = []
    @Published var connected = false
    @Published var notifiesReady = false

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var tx: CBCharacteristic?
    private var batteryChar: CBCharacteristic?
    private var sequence: UInt8 = 1
    private var writeInFlight = false
    private var queue: [PendingCommand] = []
    private var pendingNotifies: [CBCharacteristic] = []
    private var notifyInFlight = false
    private var expectedNotifies = 0
    private var readyNotifies = 0
    private var servicesAwaitingCharacteristics = 0
    private var residuals: [CBUUID: Data] = [:]
    private var stopR10Armed = false
    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    private let captureURL: URL = {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StrapProtocol", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return folder.appendingPathComponent("session-\(stamp).jsonl")
    }()

    let txUUID = CBUUID(string: "61080002-8D6D-82B8-614A-1C8CB0F8DCC6")
    let notifyUUIDs: Set<CBUUID> = [
        CBUUID(string: "61080003-8D6D-82B8-614A-1C8CB0F8DCC6"),
        CBUUID(string: "61080004-8D6D-82B8-614A-1C8CB0F8DCC6"),
        CBUUID(string: "61080005-8D6D-82B8-614A-1C8CB0F8DCC6"),
        CBUUID(string: "61080007-8D6D-82B8-614A-1C8CB0F8DCC6"),
        CBUUID(string: "2A37")
    ]
    let batteryUUID = CBUUID(string: "2A19")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func connect() {
        guard central.state == .poweredOn else {
            status = "Bluetooth is off"
            return
        }
        status = "Scanning"
        notifiesReady = false
        central.scanForPeripherals(withServices: nil)
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        status = "Disconnected"
        connected = false
        notifiesReady = false
    }

    func runInit() {
        enqueue("Hello", 0x23, [0x00])
        enqueue("Name", 0x4C, [0x00])
        enqueue("Range", 0x22, [0x00])
        enqueue("Alarm", 0x43, [0x01])
    }

    func startHistory() { enqueue("History", 0x16, [0x00]) }
    func abortHistory() { enqueue("Abort history", 0x14, [0x00]) }
    func enableCompact() { enqueue("Compact on", 0x6A, [0x01]) }
    func disableCompact() { enqueue("Compact off", 0x6A, [0x00]) }
    func enableProprietaryHR() { enqueue("HR stream on", 0x03, [0x01]) }
    func disableProprietaryHR() { enqueue("HR stream off", 0x03, [0x00]) }
    func enableLeftover() {
        stopR10Armed = true
        leftoverCount = 0
        enqueue("R10 on", 0x3F, [0x01])
    }
    func disableLeftover() {
        stopR10Armed = false
        enqueue("R10 off", 0x3F, [0x00])
    }
    func linkValid() { enqueue("Link", 0x01, [0x00]) }
    func readStrapBattery() {
        if let peripheral, let batteryChar {
            peripheral.readValue(for: batteryChar)
        }
        enqueue("Battery", 0x1A, [0x00])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            status = "Bluetooth is off"
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.uppercased().contains("WHO") else { return }
        central.stopScan()
        self.peripheral = peripheral
        deviceName = name
        status = "Connecting \(RSSI)"
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        status = "Discovering"
        note("link", "Connected \(deviceName)")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Connect failed"
        note("error", error?.localizedDescription ?? "connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        tx = nil
        batteryChar = nil
        writeInFlight = false
        notifyInFlight = false
        notifiesReady = false
        expectedNotifies = 0
        readyNotifies = 0
        servicesAwaitingCharacteristics = 0
        pendingNotifies.removeAll()
        queue.removeAll()
        residuals.removeAll()
        status = "Disconnected"
        note("link", error?.localizedDescription ?? "Disconnected")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        servicesAwaitingCharacteristics = services.count
        guard !services.isEmpty else {
            status = "No services"
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == txUUID {
                tx = characteristic
            }
            if characteristic.uuid == batteryUUID {
                batteryChar = characteristic
                if characteristic.properties.contains(.read) {
                    peripheral.readValue(for: characteristic)
                }
            }
            if notifyUUIDs.contains(characteristic.uuid),
               characteristic.properties.contains(.notify),
               !pendingNotifies.contains(where: { $0.uuid == characteristic.uuid }) {
                pendingNotifies.append(characteristic)
            }
        }
        servicesAwaitingCharacteristics = max(0, servicesAwaitingCharacteristics - 1)
        guard servicesAwaitingCharacteristics == 0 else { return }
        expectedNotifies = pendingNotifies.count
        readyNotifies = 0
        status = "Subscribing \(expectedNotifies)"
        pumpNotify()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        notifyInFlight = false
        let state = characteristic.isNotifying ? "on" : "off"
        if let error {
            note("notify", "\(characteristic.uuid.uuidString.prefix(8)) \(state) \(error.localizedDescription)")
        } else {
            note("notify", "\(characteristic.uuid.uuidString.prefix(8)) \(state)")
        }
        if characteristic.isNotifying {
            readyNotifies += 1
        }
        if readyNotifies >= expectedNotifies, expectedNotifies > 0, tx != nil {
            notifiesReady = true
            status = "Ready"
            note("link", "Notifies ready; writes unlocked")
            sendNext()
        }
        pumpNotify()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight = false
        if let error {
            note("write", error.localizedDescription)
        }
        sendNext()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        if characteristic.uuid == batteryUUID, let level = value.first {
            battery = Int(level)
            note("battery", "\(level)%")
            return
        }
        if uuid.hasSuffix("2A37") || !value.starts(with: [0xAA]) {
            ingest(uuid: uuid, frame: value)
            return
        }
        var residual = residuals[characteristic.uuid] ?? Data()
        for frame in FrameCodec.frames(from: value, residual: &residual) {
            ingest(uuid: uuid, frame: frame)
        }
        residuals[characteristic.uuid] = residual
    }

    private func pumpNotify() {
        guard !notifyInFlight, let peripheral, !pendingNotifies.isEmpty else { return }
        let characteristic = pendingNotifies.removeFirst()
        notifyInFlight = true
        peripheral.setNotifyValue(true, for: characteristic)
    }

    private func enqueue(_ name: String, _ opcode: UInt8, _ payload: [UInt8]) {
        // Never emit 0x9A from this console.
        guard opcode != 0x9A else {
            note("blocked", "refused opcode 9A")
            return
        }
        queue.append(PendingCommand(name: name, opcode: opcode, payload: payload))
        sendNext()
    }

    private func sendNext() {
        guard notifiesReady, !writeInFlight, let peripheral, let tx, !queue.isEmpty else {
            if !notifiesReady, !queue.isEmpty {
                status = "Waiting for notifies"
            }
            return
        }
        let command = queue.removeFirst()
        let frame = FrameCodec.encode(sequence: sequence, opcode: command.opcode, payload: command.payload)
        sequence &+= 1
        writeInFlight = true
        note("tx", "\(command.name) \(frame.map { String(format: "%02X", $0) }.joined())")
        peripheral.writeValue(frame, for: tx, type: .withResponse)
    }

    private func ingest(uuid: String, frame: Data) {
        let kind = PacketClass.classify(uuid: uuid, frame: frame)
        switch kind {
        case .heartRate:
            heartRateCount += 1
            if frame.count >= 2 { heartRate = Int(frame[1]) }
        case .compactIMU:
            compactCount += 1
            if let slice = CompactSlice.parse(frame: frame) {
                note(kind.rawValue, "t=\(slice.deviceTime) accel=\(slice.accelCount) gyro=\(slice.gyroCount)")
            } else {
                note(kind.rawValue, "\(frame.count)B (not compact shape)")
            }
        case .backfillIMU:
            backfillCount += 1
            note(kind.rawValue, "\(frame.count)B")
        case .leftoverR10:
            leftoverCount += 1
            if leftoverCount <= 4 {
                note(kind.rawValue, "\(frame.count)B \(frame.prefix(12).map { String(format: "%02X", $0) }.joined())")
            }
            if stopR10Armed, leftoverCount == 4 {
                stopR10Armed = false
                enqueue("R10 off", 0x3F, [0x00])
            }
        case .proprietaryHR:
            proprietaryHRCount += 1
        case .commandReply:
            if let reply = CommandReply.parse(frame: frame) {
                lastReply = reply.line
                note(kind.rawValue, reply.line)
            } else {
                note(kind.rawValue, "\(frame.count)B")
            }
        case .historyMark:
            acknowledgeHistoryIfNeeded(frame)
            note(kind.rawValue, "\(frame.count)B \(frame.prefix(16).map { String(format: "%02X", $0) }.joined())")
        default:
            let hex = frame.prefix(24).map { String(format: "%02X", $0) }.joined()
            note(kind.rawValue, "\(frame.count)B \(hex)")
        }
        appendCapture(uuid: uuid, kind: kind, frame: frame)
    }

    private func acknowledgeHistoryIfNeeded(_ frame: Data) {
        let bytes = [UInt8](frame)
        guard bytes.count >= 8, bytes[0] == 0xAA, bytes[4] == 0x31 else { return }
        let declared = Int(bytes[1]) | (Int(bytes[2]) << 8)
        guard declared + 4 <= bytes.count else { return }
        let inner = Array(bytes[4..<declared])
        guard inner.count >= 3, inner[0] == 0x31 else { return }
        if inner[2] == 2, inner.count >= 21 {
            enqueue("History ack", 0x17, [0x01] + Array(inner[13..<21]))
        } else if inner[2] == 3 {
            note("History mark", "complete")
        }
    }

    private func note(_ kind: String, _ detail: String) {
        let line = LogLine(time: clock.string(from: Date()), kind: kind, detail: detail)
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 400 {
                self.lines.removeFirst(self.lines.count - 400)
            }
        }
    }

    private func appendCapture(uuid: String, kind: PacketClass, frame: Data) {
        let record: [String: Any] = [
            "t": Date().timeIntervalSince1970,
            "uuid": uuid,
            "kind": kind.rawValue,
            "hex": frame.map { String(format: "%02x", $0) }.joined()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let text = String(data: data, encoding: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: captureURL) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? (text + "\n").write(to: captureURL, atomically: true, encoding: .utf8)
        }
    }
}
