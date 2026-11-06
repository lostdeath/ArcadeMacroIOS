import SwiftUI
import CoreBluetooth
import UniformTypeIdentifiers
import UIKit

struct DeviceView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var showCopied = false
    var body: some View {
        NavigationView {
            List {
                Section {
                    Label("Technical Bluetooth details for troubleshooting. You don't need this screen to make macros.", systemImage: "wrench.and.screwdriver")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("iOS game controller") {
                    if bluetooth.systemGameControllers.isEmpty {
                        Text("No controller name reported yet. Make sure the stick is awake and connected in iPhone Bluetooth Settings, then search here.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(bluetooth.systemGameControllers.enumerated()), id: \.offset) { _, name in
                            Label(name, systemImage: "gamecontroller.fill")
                        }
                        Text("Name reported by iOS Game Controller. This confirms the paired gamepad name, but does not identify which BLE scan entry it matches.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(bluetooth.isSearchingForGameControllers ? "Searching for controller…" : "Search for iOS game controller") { bluetooth.discoverSystemGameControllers() }
                        .disabled(bluetooth.isSearchingForGameControllers)
                    if !bluetooth.gameControllerDiscoveryState.isEmpty {
                        Text(bluetooth.gameControllerDiscoveryState).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section { Text(bluetooth.state).font(.subheadline); Button("Scan for Bluetooth devices") { bluetooth.scan() }.disabled(bluetooth.connected != nil || bluetooth.isConnecting)
                    ForEach(bluetooth.devices) { d in
                        Button { bluetooth.connect(d.peripheral) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(d.displayName, systemImage: "gamecontroller")
                                Text("RSSI \(d.rssi) dBm · Advertised services: \(d.advertisedServices.count)").font(.caption2).foregroundStyle(.secondary)
                                if let data = d.manufacturerData { Text("Manufacturer data: \(data)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
                            }
                        }.disabled(bluetooth.connected != nil || bluetooth.isConnecting)
                    }
                    if bluetooth.connected != nil || bluetooth.isConnecting { Button("Cancel / disconnect", role: .destructive) { bluetooth.disconnect() } }
                } header: { Text("Controller") }
                Section("ESP32 bridge") {
                    Text(bluetooth.bridgeStatus).font(.subheadline)
                    Text("Live stick input (hex): \(bluetooth.bridgeInput)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Ping bridge") { bluetooth.pingBridge() }
                        .disabled(!bluetooth.bridgeReady)
                    if !bluetooth.bridgeReady {
                        Text("Connect to ArcadeMacro Bridge to test the phone-to-board link.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("GATT services") {
                    if bluetooth.services.isEmpty { Text("No services discovered yet.").foregroundStyle(.secondary) }
                    ForEach(bluetooth.services, id: \.uuidString) { service in
                        Text(service.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Section("Characteristics") {
                    if bluetooth.rows.isEmpty { Text("Connect to a BLE device to inspect its GATT attributes.").foregroundStyle(.secondary) }
                    ForEach(bluetooth.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.uuid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Service \(row.serviceUUID.uuidString) · \(row.properties)").font(.caption2).foregroundStyle(.secondary)
                            Text("Value: \(row.valueText)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if row.characteristic.properties.contains(.read) { Button("Read") { bluetooth.read(row.uuid) } }
                        }.padding(.vertical, 3)
                    }
                }
                if !bluetooth.log.isEmpty { Section("Activity") { ForEach(Array(bluetooth.log.prefix(12).enumerated()), id: \.offset) { _, s in Text(s).font(.caption) } } }
            }
            .navigationTitle("Advanced")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { UIPasteboard.general.string = bluetooth.diagnosticReport(); showCopied = true } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy Bluetooth report")
                }
            }
            .alert("Bluetooth report copied", isPresented: $showCopied) { Button("OK", role: .cancel) {} } message: { Text("Paste the report into chat to share the discovered services and characteristics.") }
        }
    }
}
