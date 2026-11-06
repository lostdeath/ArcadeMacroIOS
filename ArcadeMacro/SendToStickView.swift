import SwiftUI

/// Sheet: choose which button plays the macro and which of the stick's two
/// macro slots to use, then send it through the bridge.
struct SendToStickView: View {
    let macro: GameMacro
    @EnvironmentObject private var bluetooth: BluetoothManager
    @Environment(\.dismiss) private var dismiss
    @State private var trigger = "P1"
    @State private var slot = 0
    @State private var confirm = false
    @State private var problem: String?
    @State private var startWriteCount = -1

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    macroCard
                    if justSent { successCard }
                    else if !bluetooth.stickSupported { notConnectedCard }
                    else if let settings = bluetooth.stickSettings { chooser(settings) }
                    else { loadCard }
                    if bluetooth.stickBusy {
                        HStack(spacing: 10) { ProgressView(); Text(bluetooth.stickMessage).font(.footnote) }
                    } else if bluetooth.stickMessage.hasPrefix("Bridge error") || bluetooth.stickMessage.hasPrefix("No reply") {
                        Label(bluetooth.stickMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundColor(.orange)
                    }
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Put on stick")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Send to stick?", isPresented: $confirm) {
                Button("Send") { send() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\"\(macro.name)\" will be saved as Macro \(slot + 1) and play when you press \(trigger). Only macros are changed; your button layout stays the same.")
            }
            .alert("Can't send this macro", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(problem ?? "") }
        }
        .navigationViewStyle(.stack)
    }

    private var justSent: Bool { startWriteCount >= 0 && bluetooth.stickWriteCount > startWriteCount }

    private var macroCard: some View {
        Card {
            Text(macro.name).font(.title2.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(macro.steps) { StepBadges(step: $0.button, size: 28) }
                }
            }
            Text("\(macro.steps.count) steps").font(.caption).foregroundColor(.secondary)
        }
    }

    private var notConnectedCard: some View {
        Card {
            Label("Bridge not connected", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            Text("Power the ESP32, plug your stick into it, and keep the phone close by. Then tap Connect.")
                .font(.footnote).foregroundColor(.secondary)
            Button { bluetooth.connectToBridge() } label: {
                Label(bluetooth.isFindingBridge || bluetooth.isConnecting ? "Looking…" : "Connect", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bluetooth.isFindingBridge || bluetooth.isConnecting)
        }
    }

    private var loadCard: some View {
        Card {
            Label("Load the stick first", systemImage: "square.and.arrow.down.fill").font(.headline)
            Text(bluetooth.stickPluggedIn ? "The app reads the stick's current macros so it only changes what you choose."
                                         : "Plug the stick into the ESP32's USB port (switch on S), then load.")
                .font(.footnote).foregroundColor(.secondary)
            Button { bluetooth.readStick() } label: {
                Label("Load from stick", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(bluetooth.stickBusy || !bluetooth.stickPluggedIn)
        }
    }

    @ViewBuilder private func chooser(_ settings: StickSettings) -> some View {
        let existing = settings.macros
        VStack(alignment: .leading, spacing: 10) {
            StepHeading(number: 1, title: "Which button plays it?")
            StickPadView(mode: .trigger, lit: [trigger]) { trigger = $0 }
                .frame(maxWidth: .infinity)
            Text(trigger == "P1" || trigger == "P2"
                 ? "\(trigger) is an extra button meant for macros, if your stick has one."
                 : "Pressing \(trigger) will play the macro instead of a normal \(trigger) press.")
                .font(.caption).foregroundColor(.secondary)
        }
        VStack(alignment: .leading, spacing: 10) {
            StepHeading(number: 2, title: "Which macro slot?")
            ForEach(0..<StickSettings.maxMacros, id: \.self) { i in
                Button { slot = i } label: {
                    SlotSummary(index: i, macro: i < existing.count ? existing[i] : nil, selected: slot == i)
                }
                .buttonStyle(.plain)
            }
            if slot < existing.count {
                Label("This replaces what's in Macro \(slot + 1).", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundColor(.secondary)
            }
            if let other = existing.indices.first(where: { $0 != slot && existing[$0].triggerName == trigger }) {
                Label("Macro \(other + 1) also uses \(trigger), so it will be removed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundColor(.orange)
            }
        }
        Button { prepare() } label: {
            Label("Send to stick", systemImage: "paperplane.fill").font(.headline).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(bluetooth.stickBusy)
    }

    private var successCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundColor(.green)
                VStack(alignment: .leading) {
                    Text("Saved on your stick").font(.title3.bold())
                    Text("The bridge read it back and it matches.").font(.footnote).foregroundColor(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "powerplug.fill").font(.title2).foregroundColor(.orange).frame(width: 32)
                Text("Unplug the stick from the ESP32 and plug it back in.").font(.subheadline)
            }
            HStack(alignment: .top, spacing: 12) {
                ButtonBadge(name: trigger, size: 32)
                Text("Press \(trigger) to play \"\(macro.name)\". On the Stick tab you can watch it light up.").font(.subheadline)
            }
        }
    }

    private func prepare() {
        guard let mask = StickButtons.triggers.first(where: { $0.name == trigger })?.mask else { return }
        switch StickButtons.convert(macro, trigger: mask) {
        case .failure(let error): problem = error.description
        case .success: confirm = true
        }
    }

    private func send() {
        guard let settings = bluetooth.stickSettings,
              let mask = StickButtons.triggers.first(where: { $0.name == trigger })?.mask,
              case .success(let stickMacro) = StickButtons.convert(macro, trigger: mask) else { return }
        startWriteCount = bluetooth.stickWriteCount
        bluetooth.writeStick(settings.placing(stickMacro, inSlot: slot))
    }
}
