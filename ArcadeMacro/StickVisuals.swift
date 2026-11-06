import SwiftUI
import UIKit

/// Names, colors and icons for the stick's buttons, shared by every screen.
enum PadStyle {
    static let directions = ["Up", "Down", "Left", "Right"]
    static let buttonOrder = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "L3", "R3", "P1", "P2"]

    static func color(_ name: String) -> Color {
        switch name {
        case "A": return Color(red: 0.86, green: 0.20, blue: 0.22)
        case "B": return Color(red: 0.95, green: 0.70, blue: 0.10)
        case "X": return Color(red: 0.20, green: 0.45, blue: 0.90)
        case "Y": return Color(red: 0.18, green: 0.65, blue: 0.35)
        case "L", "R": return Color(white: 0.45)
        case "ZL", "ZR": return Color(white: 0.30)
        case "P1": return Color(red: 0.55, green: 0.30, blue: 0.85)
        case "P2": return Color(red: 0.95, green: 0.45, blue: 0.15)
        case "Wait": return Color(white: 0.62)
        default: return Color(white: 0.22)  // joystick directions
        }
    }

    /// Arrow icon for a set of joystick directions, e.g. ["Down", "Right"] -> arrow.down.right
    static func arrowSymbol(_ dirs: Set<String>) -> String? {
        let v = dirs.contains("Up") ? "up" : dirs.contains("Down") ? "down" : nil
        let h = dirs.contains("Left") ? "left" : dirs.contains("Right") ? "right" : nil
        switch (v, h) {
        case let (v?, h?): return "arrow.\(v).\(h)"
        case let (v?, nil): return "arrow.\(v)"
        case let (nil, h?): return "arrow.\(h)"
        default: return nil
        }
    }

    /// Splits "Down+Right+A" into its parts.
    static func parts(_ step: String) -> [String] {
        step.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Canonical step name from a set of pressed parts: directions first
    /// (vertical, then horizontal), then buttons in a fixed order.
    static func stepName(_ pressed: Set<String>) -> String {
        if pressed.isEmpty { return "Wait" }
        let dirs = directions.filter { pressed.contains($0) }
        let buttons = buttonOrder.filter { pressed.contains($0) }
        return (dirs + buttons).joined(separator: "+")
    }

    /// Plain-English name for a step, for labels and VoiceOver.
    static func spoken(_ step: String) -> String {
        step == "Wait" ? "Pause" : parts(step).joined(separator: " + ")
    }
}

/// A round, colored arcade button. Directions show an arrow; Wait shows a pause icon.
struct ButtonBadge: View {
    let name: String
    var size: CGFloat = 34
    var lit = false

    var body: some View {
        let dirs = Set(PadStyle.parts(name)).intersection(PadStyle.directions)
        ZStack {
            Circle()
                .fill(PadStyle.color(dirs.isEmpty ? name : "dir"))
                .shadow(color: lit ? PadStyle.color(name).opacity(0.9) : .clear, radius: lit ? 8 : 0)
            Circle().stroke(lit ? Color.white : Color.black.opacity(0.25), lineWidth: lit ? 3 : 1)
            if name == "Wait" {
                Image(systemName: "pause.fill").font(.system(size: size * 0.4, weight: .bold))
            } else if let arrow = PadStyle.arrowSymbol(dirs) {
                Image(systemName: arrow).font(.system(size: size * 0.45, weight: .heavy))
            } else {
                Text(name).font(.system(size: size * (name.count > 1 ? 0.32 : 0.42), weight: .heavy, design: .rounded))
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundColor(.white)
        .frame(width: size, height: size)
        .scaleEffect(lit ? 1.15 : 1)
        .animation(.easeOut(duration: 0.12), value: lit)
        .accessibilityLabel(PadStyle.spoken(name))
    }
}

/// One macro step drawn as badges: a joystick arrow (if any) plus each button.
struct StepBadges: View {
    let step: String
    var size: CGFloat = 30

    var body: some View {
        let parts = PadStyle.parts(step)
        let dirs = parts.filter { PadStyle.directions.contains($0) }
        let buttons = parts.filter { !PadStyle.directions.contains($0) }
        HStack(spacing: 4) {
            if !dirs.isEmpty { ButtonBadge(name: dirs.joined(separator: "+"), size: size) }
            ForEach(buttons, id: \.self) { ButtonBadge(name: $0, size: size) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PadStyle.spoken(step))
    }
}

/// A drawing of the arcade stick: 8-way joystick on the left, 8 buttons on the
/// right (Switch layout), and optionally the P1/P2 buttons. Tapping reports a
/// name such as "A", "Up" or "Down+Right".
struct StickPadView: View {
    enum Mode { case steps, trigger, display }
    var mode: Mode
    /// Parts that should glow (e.g. ["Down", "Right", "A"]).
    var lit: Set<String> = []
    var onTap: (String) -> Void = { _ in }

    private let topRow = ["Y", "X", "R", "L"]
    private let bottomRow = ["B", "A", "ZR", "ZL"]
    private let grid: [[String]] = [["Up+Left", "Up", "Up+Right"],
                                    ["Left", "", "Right"],
                                    ["Down+Left", "Down", "Down+Right"]]

    var body: some View {
        VStack(spacing: 10) {
            if mode == .trigger {
                HStack(spacing: 10) {
                    Spacer()
                    Text("Extra buttons").font(.caption2).foregroundColor(.white.opacity(0.6))
                    padButton("P1", size: 36)
                    padButton("P2", size: 36)
                }
            }
            HStack(alignment: .center, spacing: 16) {
                joystick.opacity(mode == .trigger ? 0.3 : 1)
                    .allowsHitTesting(mode == .steps)
                VStack(spacing: 10) {
                    HStack(spacing: 8) { ForEach(topRow, id: \.self) { padButton($0, size: 42) } }
                    HStack(spacing: 8) { ForEach(bottomRow, id: \.self) { padButton($0, size: 42) } }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08)))
    }

    private var litDirections: Set<String> { lit.intersection(PadStyle.directions) }

    private var joystick: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.35)).frame(width: 112, height: 112)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { r in
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { c in
                            let name = grid[r][c]
                            if name.isEmpty {
                                // The ball top
                                Circle()
                                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.4, blue: 0.4), Color(red: 0.7, green: 0.05, blue: 0.1)],
                                                         center: .topLeading, startRadius: 2, endRadius: 30))
                                    .frame(width: 32, height: 32)
                                    .offset(ballOffset)
                                    .animation(.easeOut(duration: 0.1), value: litDirections)
                            } else {
                                let dirs = Set(PadStyle.parts(name))
                                Button { onTap(name) } label: {
                                    ButtonBadge(name: name, size: 30, lit: !litDirections.isEmpty && dirs == litDirections)
                                        .opacity(mode == .display && dirs != litDirections ? 0.35 : 1)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var ballOffset: CGSize {
        let x: CGFloat = litDirections.contains("Left") ? -6 : litDirections.contains("Right") ? 6 : 0
        let y: CGFloat = litDirections.contains("Up") ? -6 : litDirections.contains("Down") ? 6 : 0
        return CGSize(width: x, height: y)
    }

    private func padButton(_ name: String, size: CGFloat) -> some View {
        Button { onTap(name) } label: { ButtonBadge(name: name, size: size, lit: lit.contains(name)) }
            .buttonStyle(.plain)
            .allowsHitTesting(mode != .display)
    }
}

/// Decodes the stick's Switch-mode input report (ID 0x30) into pressed names,
/// so the app can light up the drawing while you press real buttons.
enum LiveInput {
    static func pressed(_ r: [UInt8]) -> Set<String> {
        guard r.count >= 9, r[0] == 0x30 else { return [] }
        var s = Set<String>()
        let right = r[3], shared = r[4], left = r[5]
        if right & 0x01 != 0 { s.insert("Y") }
        if right & 0x02 != 0 { s.insert("X") }
        if right & 0x04 != 0 { s.insert("B") }
        if right & 0x08 != 0 { s.insert("A") }
        if right & 0x40 != 0 { s.insert("R") }
        if right & 0x80 != 0 { s.insert("ZR") }
        if left & 0x01 != 0 { s.insert("Down") }
        if left & 0x02 != 0 { s.insert("Up") }
        if left & 0x04 != 0 { s.insert("Right") }
        if left & 0x08 != 0 { s.insert("Left") }
        if left & 0x40 != 0 { s.insert("L") }
        if left & 0x80 != 0 { s.insert("ZL") }
        _ = shared
        // Some modes send the joystick as the left analog stick instead of the D-pad.
        let x = Int(r[6]) | (Int(r[7] & 0x0F) << 8)
        let y = Int(r[7] >> 4) | (Int(r[8]) << 4)
        if x != 0 || y != 0 {
            if x < 1000 { s.insert("Left") } else if x > 3000 { s.insert("Right") }
            if y < 1000 { s.insert("Down") } else if y > 3000 { s.insert("Up") }
        }
        return s
    }
}

/// A rounded card container used across the app.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(UIColor.secondarySystemGroupedBackground)))
    }
}

/// Big numbered heading: "1  Pick a button".
struct StepHeading: View {
    let number: Int
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(.headline, design: .rounded).weight(.heavy))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.red))
            Text(title).font(.headline)
        }
    }
}
