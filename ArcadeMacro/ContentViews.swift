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
                Section("Safe macro upload") {
                    Label("Writes are disabled until the complete settings block can be read", systemImage: "lock.shield")
                    Text("An upload must start from the controller's current full settings, replace only the active profile's macro fields, then send the preserved block back. This protects your button mappings. The BLE read/write transport is not confirmed yet.").font(.caption).foregroundStyle(.secondary)
                }
                if !bluetooth.log.isEmpty { Section("Activity") { ForEach(Array(bluetooth.log.prefix(12).enumerated()), id: \.offset) { _, s in Text(s).font(.caption) } } }
            }
            .navigationTitle("8BitDo Macro Lab")
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

struct MacroView: View {
    @EnvironmentObject private var store: MacroStore
    @State private var newButton = "A"
    @State private var duration = 100.0
    @State private var exported = false
    private let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "Start", "Select", "Up", "Down", "Left", "Right"]
    var body: some View {
        NavigationView {
            List {
                Section("Macro") {
                    Picker("Choose macro", selection: Binding(get: { store.selectedID ?? store.macros.first?.id ?? UUID() }, set: { store.selectedID = $0 })) {
                        ForEach(store.macros) { m in Text(m.name).tag(m.id) }
                    }
                    Button("＋ New macro") { store.addMacro() }
                    TextField("Macro name", text: nameBinding).textInputAutocapitalization(.words)
                }
                Section("Record / add steps") {
                    Text("Choose a button and duration, then tap Add step. iOS does not expose physical gamepad button capture to ordinary apps, so recording here means building a timed sequence with the editor.").font(.caption).foregroundStyle(.secondary)
                    Picker("Button", selection: $newButton) { ForEach(buttons, id: \.self) { Text($0) } }.pickerStyle(.menu)
                    HStack { Text("Hold \(Int(duration)) ms"); Slider(value: $duration, in: 20...2000, step: 10) }
                    Button(store.recording ? "Stop recording" : "Record gamepad input") { store.toggleRecording() }
                    Button("Add \(newButton) step") { store.append(button: newButton, duration: Int(duration)) }
                }
                Section("Sequence") {
                    if let i = store.selectedIndex, !store.macros[i].steps.isEmpty {
                        ForEach(Array(store.macros[i].steps.enumerated()), id: \.element.id) { n, step in
                            HStack { Text("\(n + 1).  \(step.button)"); Spacer(); Text("\(step.durationMs) ms").foregroundStyle(.secondary); Button(role: .destructive) { store.removeStep(step.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless) }
                        }
                    } else { Text("No steps yet.").foregroundStyle(.secondary) }
                    Button("Export macro JSON") { exported = true }
                }
                Section("Send to controller") {
                    Label("Macro upload is not enabled yet", systemImage: "exclamationmark.bluetooth")
                    Text("The app must first read the full settings block, update only the selected macro data, and preserve all mappings before writing it back. The Bluetooth tab is for discovering whether iOS can reach the needed report transport.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Macro Editor")
                .fileExporter(isPresented: $exported, document: MacroDocument(data: selectedJSON), contentType: .json, defaultFilename: "macro.json") { _ in }
        }
    }
    private var nameBinding: Binding<String> {
        Binding(get: { guard let i = store.selectedIndex else { return "" }; return store.macros[i].name }, set: { value in guard let i = store.selectedIndex else { return }; store.macros[i].name = value })
    }
    private var selectedJSON: Data {
        guard let i = store.selectedIndex else { return Data("[]".utf8) }
        return (try? JSONEncoder().encode(store.macros[i])) ?? Data("{}".utf8)
    }
}
struct MacroDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
