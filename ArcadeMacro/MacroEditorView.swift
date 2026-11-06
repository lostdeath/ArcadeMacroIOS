import SwiftUI
import UniformTypeIdentifiers

/// Second tab: build a macro by tapping the picture of the stick.
struct MacroEditorView: View {
    @EnvironmentObject private var store: MacroStore
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var comboMode = false
    @State private var combo: Set<String> = []
    @State private var durationMs = 100
    @State private var lit: Set<String> = []
    @State private var previewTask: Task<Void, Never>?
    @State private var showSend = false
    @State private var exported = false
    @State private var confirmDelete = false
    @State private var editingStep: MacroStep?

    private let presets: [(String, Int)] = [("Tap", 50), ("Quick", 100), ("Hold", 250), ("Long", 500)]

    var body: some View {
        NavigationView {
            List {
                Section { library }
                Section { builder } header: { StepHeading(number: 1, title: "Tap buttons to add steps") }
                Section { sequence } header: {
                    HStack {
                        StepHeading(number: 2, title: "Check the order")
                        Spacer()
                        if !steps.isEmpty { EditButton().font(.subheadline) }
                    }
                }
                Section { sendSection } header: { StepHeading(number: 3, title: "Put it on your stick") }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Macros")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { store.addMacro() } label: { Label("New macro", systemImage: "plus") }
                        Button { store.duplicateSelectedMacro() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                        Button { exported = true } label: { Label("Export as file", systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete macro", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSend) {
                if let macro = store.selectedMacro {
                    SendToStickView(macro: macro).environmentObject(bluetooth)
                }
            }
            .sheet(item: $editingStep) { step in
                StepTimeSheet(step: step) { store.setDuration($0, for: step.id) }
            }
            .alert("Delete this macro?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { store.deleteSelectedMacro() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("It is removed from this phone only. Macros already on the stick stay there.") }
            .fileExporter(isPresented: $exported, document: MacroDocument(data: selectedJSON), contentType: .json, defaultFilename: "\(currentName).json") { _ in }
            .onDisappear { stopPreview() }
        }
        .navigationViewStyle(.stack)
    }

    private var steps: [MacroStep] { store.selectedMacro?.steps ?? [] }
    private var currentName: String { store.selectedMacro?.name ?? "Macro" }

    // MARK: Macro library

    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(store.macros) { m in
                        Button { stopPreview(); store.selectedID = m.id } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(m.name).font(.subheadline.bold()).lineLimit(1)
                                HStack(spacing: 3) {
                                    ForEach(Array(m.steps.prefix(4).enumerated()), id: \.offset) { _, s in StepBadges(step: s.button, size: 16) }
                                    if m.steps.count > 4 { Text("…").font(.caption2) }
                                    if m.steps.isEmpty { Text("empty").font(.caption2).foregroundColor(.secondary) }
                                }
                            }
                            .padding(10)
                            .frame(width: 130, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(m.id == store.selectedID ? Color.red.opacity(0.15) : Color(UIColor.tertiarySystemFill)))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(m.id == store.selectedID ? Color.red : Color.clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                    }
                    Button { store.addMacro() } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill").font(.title2)
                            Text("New").font(.caption.bold())
                        }
                        .frame(width: 70, height: 56)
                        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.red)
                }
                .padding(.vertical, 2)
            }
            HStack {
                Image(systemName: "pencil").foregroundColor(.secondary)
                TextField("Macro name", text: nameBinding).textInputAutocapitalization(.words).font(.headline)
            }
        }
    }

    // MARK: Builder

    private var builder: some View {
        VStack(alignment: .leading, spacing: 12) {
            StickPadView(mode: .steps, lit: comboMode ? combo : lit) { tapped($0) }
                .frame(maxWidth: .infinity)
            Toggle(isOn: $comboMode.animation()) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Press several at once").font(.subheadline.bold())
                    Text(comboMode ? "Tap buttons to select them, then tap Add combo." : "Off: each tap adds one step.").font(.caption).foregroundColor(.secondary)
                }
            }
            .onChange(of: comboMode) { _ in combo = [] }
            if comboMode {
                HStack {
                    Button { addStep(PadStyle.stepName(combo)); combo = [] } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            if combo.isEmpty { Text("Add combo") } else { StepBadges(step: PadStyle.stepName(combo), size: 20) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(combo.isEmpty)
                    Button("Clear") { combo = [] }.buttonStyle(.bordered).disabled(combo.isEmpty)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("How long each press lasts: \(durationMs) ms").font(.subheadline)
                HStack(spacing: 6) {
                    ForEach(presets.indices, id: \.self) { i in
                        let name = presets[i].0
                        let ms = presets[i].1
                        Button { durationMs = ms } label: {
                            VStack(spacing: 0) {
                                Text(name).font(.caption.bold())
                                Text("\(ms)ms").font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(durationMs == ms ? Color.red : Color(UIColor.tertiarySystemFill)))
                            .foregroundColor(durationMs == ms ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Stepper("Fine-tune", value: $durationMs, in: 10...5000, step: 10).font(.caption)
            }
            Button { addStep("Wait") } label: {
                Label("Add a pause (\(durationMs) ms)", systemImage: "pause.circle.fill")
            }
            .buttonStyle(.bordered)
            Text("Tip: put a pause between two presses of the same button, or the stick sees one long press.")
                .font(.caption).foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func tapped(_ name: String) {
        if comboMode {
            let parts = Set(PadStyle.parts(name))
            if parts.isSubset(of: Set(PadStyle.directions)) {
                let current = combo.intersection(PadStyle.directions)
                combo.subtract(PadStyle.directions)
                if current != parts { combo.formUnion(parts) }
            } else if combo.contains(name) { combo.remove(name) } else { combo.insert(name) }
        } else {
            addStep(name)
            flash(Set(PadStyle.parts(name)))
        }
    }

    private func addStep(_ name: String) {
        stopPreview()
        store.append(button: name, duration: durationMs)
    }

    private func flash(_ parts: Set<String>) {
        lit = parts
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { if lit == parts { lit = [] } }
    }

    // MARK: Sequence

    @ViewBuilder private var sequence: some View {
        if steps.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "hand.tap.fill").font(.title).foregroundColor(.red)
                Text("No steps yet. Tap a button on the stick above to add the first one.")
                    .font(.subheadline).foregroundColor(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            ForEach(Array(steps.enumerated()), id: \.element.id) { n, step in
                Button { editingStep = step } label: {
                    HStack(spacing: 12) {
                        Text("\(n + 1)").font(.caption.bold()).foregroundColor(.secondary).frame(width: 22)
                        StepBadges(step: step.button, size: 30)
                        Text(PadStyle.spoken(step.button)).font(.subheadline)
                        Spacer()
                        Label("\(step.durationMs) ms", systemImage: "timer").font(.caption).foregroundColor(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { store.removeSteps(at: $0) }
            .onMove { store.moveSteps(from: $0, to: $1) }
            HStack {
                Button { previewTask == nil ? startPreview() : stopPreview() } label: {
                    Label(previewTask == nil ? "Preview" : "Stop", systemImage: previewTask == nil ? "play.fill" : "stop.fill")
                }
                .buttonStyle(.bordered)
                Spacer()
                Text("Total \(String(format: "%.2f", Double(steps.reduce(0) { $0 + $1.durationMs }) / 1000)) s")
                    .font(.caption).foregroundColor(.secondary)
            }
            if steps.count > StickSettings.maxSteps {
                Label("The stick holds up to \(StickSettings.maxSteps) steps. Remove \(steps.count - StickSettings.maxSteps) to send this macro.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            if let bad = steps.first(where: { StickButtons.stepMask($0.button) == nil }) {
                Label("\(bad.button) can't be used on the stick. Swipe it away to send this macro.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
            Text("Tap a step to change its time. Swipe left to delete. Use Edit to reorder.")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private func startPreview() {
        let list = steps
        previewTask = Task { @MainActor in
            for step in list {
                if Task.isCancelled { break }
                lit = step.button == "Wait" ? [] : Set(PadStyle.parts(step.button))
                try? await Task.sleep(nanoseconds: UInt64(max(step.durationMs, 60)) * 1_000_000)
            }
            lit = []
            previewTask = nil
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        lit = []
    }

    // MARK: Send

    @ViewBuilder private var sendSection: some View {
        Button { stopPreview(); showSend = true } label: {
            Label("Put \"\(currentName)\" on stick", systemImage: "paperplane.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(steps.isEmpty)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        if !bluetooth.stickSupported {
            Label("Connect the bridge on the Stick tab first.", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption).foregroundColor(.secondary)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(get: { store.selectedMacro?.name ?? "" },
                set: { value in if let i = store.selectedIndex { store.macros[i].name = value } })
    }

    private var selectedJSON: Data {
        guard let m = store.selectedMacro else { return Data("{}".utf8) }
        return (try? JSONEncoder().encode(m)) ?? Data("{}".utf8)
    }
}

/// Sheet for changing how long one step lasts.
private struct StepTimeSheet: View {
    let step: MacroStep
    let onSave: (Int) -> Void
    @State private var ms: Int
    @Environment(\.dismiss) private var dismiss

    init(step: MacroStep, onSave: @escaping (Int) -> Void) {
        self.step = step
        self.onSave = onSave
        _ms = State(initialValue: step.durationMs)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                StepBadges(step: step.button, size: 56)
                Text(PadStyle.spoken(step.button)).font(.title2.bold())
                Text("\(ms) ms").font(.system(size: 44, weight: .heavy, design: .rounded))
                Slider(value: Binding(get: { Double(ms) }, set: { ms = Int($0 / 10) * 10 }), in: 10...2000)
                Stepper("Fine-tune", value: $ms, in: 10...5000, step: 10)
                Spacer()
            }
            .padding(24)
            .navigationTitle("Step time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(ms); dismiss() } }
            }
        }
    }
}

struct MacroDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
