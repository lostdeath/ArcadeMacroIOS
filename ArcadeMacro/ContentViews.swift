import SwiftUI
import CoreBluetooth
import UniformTypeIdentifiers

struct DeviceView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var selectedUUID = ""
    @State private var hex = ""
    @State private var notice: String?
    var body: some View {
        NavigationView {
            List {
                Section { Text(bluetooth.state).font(.subheadline); Button("Scan for Bluetooth devices") { bluetooth.scan() }.disabled(bluetooth.connected != nil)
                    ForEach(bluetooth.devices, id: \.identifier) { d in Button { bluetooth.connect(d) } label: { Label(d.name ?? "Unnamed device", systemImage: "gamecontroller") } }
                    if bluetooth.connected != nil { Button("Disconnect", role: .destructive) { bluetooth.disconnect() } }
                } header: { Text("Controller") }
                Section("Services and characteristics") {
                    if bluetooth.rows.isEmpty { Text("Connect to a BLE device to inspect its GATT attributes.").foregroundStyle(.secondary) }
                    ForEach(bluetooth.rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.uuid).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Text("Service \(row.serviceUUID.uuidString) · \(row.properties)").font(.caption2).foregroundStyle(.secondary)
                            Text("Value: \(row.valueText)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            HStack { if row.characteristic.properties.contains(.read) { Button("Read") { bluetooth.read(row.uuid) } }; Button("Select for raw write") { selectedUUID = row.uuid } }
                        }.padding(.vertical, 3)
                    }
                }
                Section("Manual raw GATT write") {
                    Text(selectedUUID.isEmpty ? "Select a characteristic above." : "Target: \(selectedUUID)").font(.caption).textSelection(.enabled)
                    TextField("Hex bytes, e.g. 01 A0 FF", text: $hex).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.body, design: .monospaced))
                    Button("Write these bytes") { notice = bluetooth.writeRaw(hex, to: selectedUUID) ?? "Write queued. A raw GATT write is not a macro upload." }
                        .disabled(selectedUUID.isEmpty || hex.isEmpty)
                    Text("The controller's macro packet format has not been confirmed. This tool sends only the exact bytes you enter; it does not translate a macro into device commands.").font(.caption).foregroundStyle(.secondary)
                }
                if !bluetooth.log.isEmpty { Section("Activity") { ForEach(Array(bluetooth.log.prefix(12).enumerated()), id: \.offset) { _, s in Text(s).font(.caption) } } }
            }
            .navigationTitle("8BitDo Macro Lab")
            .alert("Bluetooth", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) { Button("OK") { notice = nil } } message: { Text(notice ?? "") }
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
                    Text("The stick must expose a writable Bluetooth service and its macro packet format must be verified. The Bluetooth tab helps inspect those attributes. Once confirmed, the app can encode this sequence for that protocol.").font(.caption).foregroundStyle(.secondary)
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
    func fileWrapper(configuration: WriteConfiguration) throws { FileWrapper(regularFileWithContents: data) }
}
