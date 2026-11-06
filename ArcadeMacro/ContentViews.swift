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
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var newButton = "A"
    @State private var trigger: UInt32 = 0x0200_0000
    @State private var stickSlot = 0
    @State private var pendingStick: StickSettings?
    @State private var pendingSummary = ""
    @State private var conversionError: String?
    @State private var duration = 100.0
    @State private var exported = false
    private let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "Up", "Down", "Left", "Right", "Wait", "Start", "Select"]
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
                Section("Send to stick (ESP32 bridge)") {
                    if !bluetooth.stickSupported {
                        Label("Connect to ArcadeMacro Bridge on the Bluetooth tab first", systemImage: "antenna.radiowaves.left.and.right")
                        Text("The stick must be plugged into the ESP32's USB port. Bridge firmware v3 or newer is required.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button(bluetooth.stickSettings == nil ? "Read macros from stick" : "Refresh from stick") { bluetooth.readStick() }
                            .disabled(bluetooth.stickBusy)
                        if let settings = bluetooth.stickSettings {
                            Text("Profile: \(settings.profileName) · \(settings.activeModeName) slot").font(.subheadline)
                            let onStick = settings.macros
                            if onStick.isEmpty { Text("No macros on the stick.").foregroundStyle(.secondary) }
                            ForEach(Array(onStick.enumerated()), id: \.offset) { n, m in
                                Text("Stick macro \(n + 1): \(m.summary)").font(.caption)
                            }
                            Picker("Trigger button", selection: $trigger) {
                                ForEach(StickButtons.triggers.indices, id: \.self) { i in Text(StickButtons.triggers[i].name).tag(StickButtons.triggers[i].mask) }
                            }
                            Picker("Stick macro slot", selection: $stickSlot) {
                                Text("Macro 1").tag(0); Text("Macro 2").tag(1)
                            }.pickerStyle(.segmented)
                            Button("Send \"\(currentName)\" to stick") { prepareSend(settings) }
                                .disabled(bluetooth.stickBusy)
                            Button("Restore to normal (remove all macros)", role: .destructive) { prepareRestore(settings) }
                                .disabled(bluetooth.stickBusy || onStick.isEmpty)
                        }
                    }
                    if bluetooth.stickBusy { ProgressView() }
                    if !bluetooth.stickMessage.isEmpty { Text(bluetooth.stickMessage).font(.caption) }
                    Text("Only the macro section of the stick's active profile is changed. Button mappings are protected by the bridge firmware, and every write is read back to check it. Up to 2 macros, 18 steps each; Start and Select can't be used inside stick macros.").font(.caption2).foregroundStyle(.secondary)
                }
            }.navigationTitle("Macro Editor")
                .alert("Change stick macros?", isPresented: Binding(get: { pendingStick != nil }, set: { if !$0 { pendingStick = nil } })) {
                    Button("Write to stick", role: .destructive) {
                        if let s = pendingStick { bluetooth.writeStick(s) }
                        pendingStick = nil
                    }
                    Button("Cancel", role: .cancel) { pendingStick = nil }
                } message: { Text(pendingSummary) }
                .alert("Can't send this macro", isPresented: Binding(get: { conversionError != nil }, set: { if !$0 { conversionError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(conversionError ?? "") }
                .fileExporter(isPresented: $exported, document: MacroDocument(data: selectedJSON), contentType: .json, defaultFilename: "macro.json") { _ in }
        }
    }
    private var currentName: String {
        guard let i = store.selectedIndex else { return "macro" }
        return store.macros[i].name
    }
    private func prepareSend(_ settings: StickSettings) {
        guard let i = store.selectedIndex else { return }
        switch StickButtons.convert(store.macros[i], trigger: trigger) {
        case .failure(let error): conversionError = error.description
        case .success(let macro):
            var list = settings.macros
            let target = min(stickSlot, list.count)
            if target < list.count { list[target] = macro } else { list.append(macro) }
            // One macro per trigger button: drop any other macro using the same trigger.
            list = list.enumerated().filter { $0.offset == target || $0.element.trigger != trigger }.map(\.element)
            var updated = settings
            updated.setMacros(Array(list.prefix(StickSettings.maxMacros)))
            pendingSummary = "Write \"\(currentName)\" to the stick as \(macro.summary)?"
            pendingStick = updated
        }
    }
    private func prepareRestore(_ settings: StickSettings) {
        var updated = settings
        updated.setMacros([])
        pendingSummary = "Remove all macros from the \(settings.profileName) profile? Button mappings are not changed."
        pendingStick = updated
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
