import SwiftUI

/// First tab: get connected, see what's on the stick, test buttons, restore.
struct StickHomeView: View {
    @EnvironmentObject private var bluetooth: BluetoothManager
    @State private var confirmRestore = false
    @State private var showHelp = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    liveStick
                    checklist
                    if bluetooth.stickInSetupMode { setupModeBanner }
                    onStickCard
                    howItWorks
                }
                .padding(16)
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Arcade Macro")
            .alert("Restore the stick to normal?", isPresented: $confirmRestore) {
                Button("Remove all macros", role: .destructive) {
                    if let s = bluetooth.stickSettings { bluetooth.writeStick(s.removingAllMacros()) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every macro from the stick's active profile. Your button layout is not changed.")
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Live picture of the stick

    private var liveStick: some View {
        let pressed = LiveInput.pressed(bluetooth.bridgeInputBytes)
        return VStack(spacing: 8) {
            StickPadView(mode: .display, lit: pressed)
            Text(bluetooth.stickPluggedIn && !bluetooth.stickInSetupMode
                 ? (pressed.isEmpty ? "Press buttons on your stick: they light up here. Press a macro's button to watch it play."
                                    : "Pressed: \(PadStyle.spoken(PadStyle.stepName(pressed)))")
                 : "Connect the bridge and plug in your stick to see your button presses here.")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
    }

    // MARK: Checklist

    private var checklist: some View {
        Card {
            Text("Get ready").font(.title3.bold())
            ChecklistRow(icon: "antenna.radiowaves.left.and.right",
                         title: "Bridge connected",
                         detail: bluetooth.bridgeReady ? "Connected to the ESP32 bridge." :
                            bluetooth.isFindingBridge || bluetooth.isConnecting ? "Looking for the bridge…" :
                            "Power the ESP32 (light turns blue), then tap Connect.",
                         done: bluetooth.bridgeReady,
                         working: bluetooth.isFindingBridge || bluetooth.isConnecting,
                         actionTitle: bluetooth.bridgeReady ? nil : "Connect",
                         action: { bluetooth.connectToBridge() })
            ChecklistRow(icon: "gamecontroller.fill",
                         title: "Stick plugged into bridge",
                         detail: bluetooth.stickPluggedIn ? "Your arcade stick is detected." :
                            "Plug the stick into the ESP32's USB port (not COM), with the stick's switch on S.",
                         done: bluetooth.stickPluggedIn,
                         working: false, actionTitle: nil, action: {})
            ChecklistRow(icon: "square.and.arrow.down.fill",
                         title: "Macros loaded from stick",
                         detail: bluetooth.stickSettings.map { "Profile \"\($0.profileName)\" loaded." } ??
                            "Load what's on the stick before changing macros.",
                         done: bluetooth.stickSettings != nil,
                         working: bluetooth.stickBusy,
                         actionTitle: bluetooth.stickPluggedIn ? (bluetooth.stickSettings == nil ? "Load" : "Reload") : nil,
                         action: { bluetooth.readStick() })
            if !bluetooth.stickMessage.isEmpty {
                Label(bluetooth.stickMessage, systemImage: bluetooth.stickMessage.hasPrefix("Bridge error") ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.footnote)
                    .foregroundColor(bluetooth.stickMessage.hasPrefix("Bridge error") ? .orange : .secondary)
            }
        }
    }

    private var setupModeBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "powerplug.fill").font(.title2).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Unplug and replug your stick to play").font(.subheadline.bold())
                Text("Reading or saving macros puts the stick in 8BitDo setup mode. Unplug its cable from the ESP32 and plug it back in to use it normally and try your macros.")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.orange.opacity(0.15)))
    }

    // MARK: What's on the stick

    private var onStickCard: some View {
        Card {
            HStack {
                Text("On your stick").font(.title3.bold())
                Spacer()
                if let s = bluetooth.stickSettings {
                    Text("\(s.profileName) · \(s.activeModeName)").font(.caption).foregroundColor(.secondary)
                }
            }
            if let settings = bluetooth.stickSettings {
                let macros = settings.macros
                ForEach(0..<StickSettings.maxMacros, id: \.self) { i in
                    SlotSummary(index: i, macro: i < macros.count ? macros[i] : nil)
                }
                Button(role: .destructive) { confirmRestore = true } label: {
                    Label("Restore to normal (remove all macros)", systemImage: "arrow.uturn.backward.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(bluetooth.stickBusy || macros.isEmpty)
                Text(macros.isEmpty ? "The stick is normal: no macros are set." :
                        "Restore puts the stick back the way it came. Your button layout is never changed by this app.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                Text("Load the stick (step 3 above) to see its macros. The stick holds 2 macros per profile.")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var howItWorks: some View {
        Card {
            Button { withAnimation { showHelp.toggle() } } label: {
                HStack {
                    Text("How it works").font(.title3.bold())
                    Spacer()
                    Image(systemName: showHelp ? "chevron.up" : "chevron.down")
                }
            }
            .buttonStyle(.plain)
            if showHelp {
                HelpRow(icon: "hand.tap.fill", color: .red, title: "Build",
                        text: "On the Macros tab, tap buttons on the picture of the stick to add them in order. Pick how long each is held.")
                HelpRow(icon: "paperplane.fill", color: .blue, title: "Send",
                        text: "Tap Put on stick, choose which button plays the macro, and send. The bridge saves it on the stick and double-checks it.")
                HelpRow(icon: "powerplug.fill", color: .orange, title: "Replug",
                        text: "Unplug the stick from the ESP32 and plug it back in.")
                HelpRow(icon: "play.circle.fill", color: .green, title: "Play",
                        text: "Press the macro's button. The stick presses the whole sequence for you. Watch it light up at the top of this screen.")
                HelpRow(icon: "arrow.uturn.backward.circle.fill", color: .gray, title: "Undo",
                        text: "Restore to normal removes all macros. Your button layout is never changed.")
            }
        }
    }
}

private struct ChecklistRow: View {
    let icon: String
    let title: String
    let detail: String
    let done: Bool
    let working: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color(UIColor.tertiarySystemFill)).frame(width: 36, height: 36)
                if working { ProgressView() }
                else { Image(systemName: done ? "checkmark" : icon).foregroundColor(done ? .white : .primary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if let actionTitle, !working {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
    }
}

/// One of the stick's two macro slots, drawn as trigger -> step badges.
struct SlotSummary: View {
    let index: Int
    let macro: StickMacro?
    var selected = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Text("Macro \(index + 1)").font(.caption2.bold()).foregroundColor(.secondary)
                if let macro { ButtonBadge(name: macro.triggerName, size: 36) }
                else { Circle().strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [4])).foregroundColor(.secondary).frame(width: 36, height: 36) }
            }
            if let macro {
                Image(systemName: "arrow.right").foregroundColor(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(macro.stepNames.enumerated()), id: \.offset) { _, step in
                            StepBadges(step: step, size: 24)
                        }
                    }
                }
            } else {
                Text("Empty").foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14).fill(selected ? Color.red.opacity(0.12) : Color(UIColor.tertiarySystemFill)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? Color.red : Color.clear, lineWidth: 2))
    }
}

private struct HelpRow: View {
    let icon: String
    let color: Color
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundColor(color).frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(text).font(.footnote).foregroundColor(.secondary)
            }
        }
    }
}
