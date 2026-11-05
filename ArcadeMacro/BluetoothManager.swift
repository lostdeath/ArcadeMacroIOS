import Foundation
import CoreBluetooth
import GameController
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
    var displayName: String { advertisedName ?? peripheral.name ?? "Unnamed BLE · \(String(id.uuidString.suffix(8)))" }
}

final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var state = "Bluetooth is starting…"
    @Published var devices: [BLEDevice] = []
    @Published var connected: CBPeripheral?
    @Published var services: [CBUUID] = []
    @Published var rows: [BLECharacteristic] = []
    @Published var log: [String] = []
    @Published var systemGameControllers: [String] = []
    @Published var gameControllerDiscoveryState = ""
    @Published var isSearchingForGameControllers = false
    private var central: CBCentralManager!
    private var characteristics: [String: CBCharacteristic] = [:]
    private var pendingPeripheral: CBPeripheral?
    private var connectionTimeout: DispatchWorkItem?
    private var gameControllerObservers: [NSObjectProtocol] = []
    private var gameControllerSearchTimeout: DispatchWorkItem?
    var isConnecting: Bool { pendingPeripheral != nil }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        let center = NotificationCenter.default
        gameControllerObservers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refreshSystemGameControllers()
            if !self.systemGameControllers.isEmpty { self.finishGameControllerDiscovery() }
        })
        gameControllerObservers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSystemGameControllers()
        })
        refreshSystemGameControllers()
    }
    private func refreshSystemGameControllers() {
        systemGameControllers = GCController.controllers().map { controller in
            let name = controller.vendorName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let category = controller.productCategory
            if let name, !name.isEmpty { return "\(name) · \(category)" }
            return category
        }
    }
    func discoverSystemGameControllers() {
        gameControllerSearchTimeout?.cancel()
        gameControllerSearchTimeout = nil
        GCController.stopWirelessControllerDiscovery()
        refreshSystemGameControllers()
        if !systemGameControllers.isEmpty {
            gameControllerDiscoveryState = "Connected: \(systemGameControllers.joined(separator: "; "))"
            return
        }
        isSearchingForGameControllers = true
        gameControllerDiscoveryState = "Searching for controllers paired with iOS…"
        let timeout = DispatchWorkItem { [weak self] in self?.finishGameControllerDiscovery() }
        gameControllerSearchTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        GCController.startWirelessControllerDiscovery { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.finishGameControllerDiscovery() }
        }
    }
    private func finishGameControllerDiscovery() {
        guard isSearchingForGameControllers else { return }
        gameControllerSearchTimeout?.cancel()
        gameControllerSearchTimeout = nil
        isSearchingForGameControllers = false
        GCController.stopWirelessControllerDiscovery()
        refreshSystemGameControllers()
        gameControllerDiscoveryState = systemGameControllers.isEmpty
            ? "Search ended. iOS did not report a connected game controller to this app."
            : "Found: \(systemGameControllers.joined(separator: "; "))"
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
        guard central.state == .poweredOn else { state = "Bluetooth is not ready."; return }
        if connected?.identifier == peripheral.identifier { state = "Already connected."; return }
        if pendingPeripheral != nil { return }
        central.stopScan()
        pendingPeripheral = peripheral
        state = "Requesting BLE connection to \(deviceName(peripheral))…"
        log.insert("Requested BLE connection to \(deviceName(peripheral)) [\(shortID(peripheral.identifier))]", at: 0)
        central.connect(peripheral, options: nil)
        let timeout = DispatchWorkItem { [weak self, weak peripheral] in
            guard let self, let peripheral, self.pendingPeripheral?.identifier == peripheral.identifier else { return }
            self.central.cancelPeripheralConnection(peripheral)
            self.pendingPeripheral = nil
            self.state = "BLE connection timed out. The selected device may be a Bluetooth HID/gamepad device that iOS does not expose to this app as a GATT peripheral."
            self.log.insert("BLE connection timed out for \(self.deviceName(peripheral)) [\(self.shortID(peripheral.identifier))]", at: 0)
        }
        connectionTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionTimeout?.cancel(); connectionTimeout = nil; pendingPeripheral = nil
        connected = peripheral; peripheral.delegate = self; services = []; rows = []; characteristics = [:]
        state = "BLE connected to \(deviceName(peripheral)). Discovering services…"; peripheral.discoverServices(nil)
        log.insert("BLE connected to \(deviceName(peripheral)) [\(shortID(peripheral.identifier))]", at: 0)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionTimeout?.cancel(); connectionTimeout = nil; pendingPeripheral = nil
        state = "BLE connection failed: \(error?.localizedDescription ?? "unknown error")"
        log.insert("BLE connection failed for \(deviceName(peripheral)): \(error?.localizedDescription ?? "unknown error")", at: 0)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionTimeout?.cancel(); connectionTimeout = nil
        let wasActive = pendingPeripheral?.identifier == peripheral.identifier || connected?.identifier == peripheral.identifier
        if pendingPeripheral?.identifier == peripheral.identifier { pendingPeripheral = nil }
        if connected?.identifier == peripheral.identifier { connected = nil; services = []; rows = []; characteristics = [:] }
        if wasActive { state = error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected." }
        log.insert("BLE disconnected from \(deviceName(peripheral))", at: 0)
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
        lines.append("iOS game controllers: \(systemGameControllers.isEmpty ? "none" : systemGameControllers.joined(separator: "; "))")
        if !gameControllerDiscoveryState.isEmpty { lines.append("iOS controller search: \(gameControllerDiscoveryState)") }
        lines.append("Connected device: \(connected?.name ?? "none")")
        lines.append("Pending connection: \(pendingPeripheral.map { "\(deviceName($0)) [\(shortID($0.identifier))]" } ?? "none")")
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
    private func deviceName(_ peripheral: CBPeripheral) -> String { peripheral.name ?? "Unnamed BLE device" }
    private func shortID(_ id: UUID) -> String { String(id.uuidString.suffix(8)) }
    func disconnect() {
        connectionTimeout?.cancel(); connectionTimeout = nil
        if let pendingPeripheral { central.cancelPeripheralConnection(pendingPeripheral); self.pendingPeripheral = nil; state = "Connection cancelled." }
        if let connected { central.cancelPeripheralConnection(connected); state = "Disconnecting…" }
    }
}
