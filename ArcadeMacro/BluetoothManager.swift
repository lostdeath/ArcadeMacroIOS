import Foundation
import CoreBluetooth
import Combine

struct BLECharacteristic: Identifiable {
    let id = UUID()
    let serviceUUID: CBUUID
    let characteristic: CBCharacteristic
    var valueText: String = "—"
    var uuid: String { characteristic.uuid.uuidString }
    var properties: String {
        var p: [String] = []
        if characteristic.properties.contains(.read) { p.append("Read") }
        if characteristic.properties.contains(.write) { p.append("Write") }
        if characteristic.properties.contains(.writeWithoutResponse) { p.append("Write without response") }
        if characteristic.properties.contains(.notify) { p.append("Notify") }
        if characteristic.properties.contains(.indicate) { p.append("Indicate") }
        return p.isEmpty ? "No accessible properties" : p.joined(separator: ", ")
    }
}

struct BLEDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let advertisedName: String?
    let rssi: Int
    let advertisedServices: [String]
    let manufacturerData: String?
    var displayName: String { advertisedName ?? peripheral.name ?? "Unnamed device" }
}

final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = "Bluetooth is starting…"
    @Published var devices: [BLEDevice] = []
    @Published var connected: CBPeripheral?
    @Published var services: [CBUUID] = []
    @Published var rows: [BLECharacteristic] = []
    @Published var log: [String] = []
    private var central: CBCentralManager!
    private var characteristics: [String: CBCharacteristic] = [:]

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: state = "Bluetooth ready. Scan for nearby devices."
        case .poweredOff: state = "Bluetooth is off. Turn it on in Settings."
        case .unauthorized: state = "Bluetooth permission is not authorized."
        case .unsupported: state = "Bluetooth LE is unavailable on this device."
        case .resetting: state = "Bluetooth is resetting…"
        default: state = "Bluetooth is unavailable."
        }
    }
    func scan() {
        guard central.state == .poweredOn else { return }
        devices = []; services = []; rows = []; characteristics = [:]
        state = "Scanning for 8 seconds…"
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.state = self.devices.isEmpty ? "No BLE devices found. A controller paired as Bluetooth HID may be hidden from apps." : "Scan complete. Tap a device to connect."
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString).sorted()
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        let item = BLEDevice(id: peripheral.identifier, peripheral: peripheral, advertisedName: name, rssi: rssi.intValue, advertisedServices: advertisedServices, manufacturerData: manufacturer)
        if let index = devices.firstIndex(where: { $0.id == item.id }) { devices[index] = item }
        else { devices.append(item) }
        devices.sort {
            let lhsIs8BitDo = $0.displayName.localizedCaseInsensitiveContains("8BitDo")
            let rhsIs8BitDo = $1.displayName.localizedCaseInsensitiveContains("8BitDo")
            return lhsIs8BitDo == rhsIs8BitDo ? $0.rssi > $1.rssi : lhsIs8BitDo
        }
    }
    func connect(_ peripheral: CBPeripheral) {
        central.stopScan(); state = "Connecting to \(peripheral.name ?? "controller")…"
        central.connect(peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = peripheral; peripheral.delegate = self; services = []; rows = []; characteristics = [:]
        state = "Connected. Discovering services…"; peripheral.discoverServices(nil)
        log.insert("Connected to \(peripheral.name ?? peripheral.identifier.uuidString)", at: 0)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = nil; services = []; rows = []; characteristics = [:]
        state = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected."
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { state = "Service discovery failed: \(error.localizedDescription)"; return }
        services = (peripheral.services ?? []).map(\.uuid).sorted { $0.uuidString < $1.uuidString }
        for service in peripheral.services ?? [] { peripheral.discoverCharacteristics(nil, for: service) }
        state = "Services: \(peripheral.services?.count ?? 0). Reading characteristic list…"
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log.insert("Characteristic discovery error: \(error.localizedDescription)", at: 0); return }
        for c in service.characteristics ?? [] {
            characteristics[c.uuid.uuidString] = c
            rows.append(BLECharacteristic(serviceUUID: service.uuid, characteristic: c))
            if c.properties.contains(.read) { peripheral.readValue(for: c) }
            if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
        }
        rows.sort { $0.serviceUUID.uuidString + $0.uuid < $1.serviceUUID.uuidString + $1.uuid }
        state = "Connected. Found \(rows.count) characteristics."
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { log.insert("Read \(characteristic.uuid): \(error.localizedDescription)", at: 0); return }
        let value = characteristic.value?.map { String(format: "%02X", $0) }.joined(separator: " ") ?? "(empty)"
        if let i = rows.firstIndex(where: { $0.uuid == characteristic.uuid.uuidString }) { rows[i].valueText = value }
    }
    func read(_ uuid: String) {
        guard let c = characteristics[uuid], c.properties.contains(.read), let connected else { return }
        connected.readValue(for: c)
    }
    func diagnosticReport() -> String {
        var lines = ["8BitDo Macro Lab Bluetooth report", "State: \(state)"]
        lines.append("Connected device: \(connected?.name ?? "none")")
        lines.append("Discovered devices:")
        lines.append(contentsOf: devices.map { device in
            let services = device.advertisedServices.isEmpty ? "none" : device.advertisedServices.joined(separator: ",")
            let manufacturer = device.manufacturerData ?? "none"
            return "- \(device.displayName) RSSI=\(device.rssi) dBm id=\(device.id.uuidString) advertisedServices=\(services) manufacturerData=\(manufacturer)"
        })
        lines.append("Services:")
        lines.append(contentsOf: services.map { "- \($0.uuidString)" })
        lines.append("Characteristics:")
        lines.append(contentsOf: rows.map { "- service=\($0.serviceUUID.uuidString) characteristic=\($0.uuid) properties=\($0.properties) value=\($0.valueText)" })
        return lines.joined(separator: "\n")
    }
    func disconnect() { if let connected { central.cancelPeripheralConnection(connected) } }
}
