import Foundation

/// The 8BitDo Arcade Stick 80FE settings block (564 bytes) as read through the
/// ESP32 bridge. Layout matches the official software's
/// `ultimate_info_record_t_ArcadeStick`; see esp32/model-80FE-notes.md.
/// The app only edits the macro section of the active slot. The bridge
/// firmware rejects any change outside the macro sections.
struct StickSettings: Equatable {
    static let size = 564
    static let slotBase = 4, slotSize = 280, macroOffset = 36, macroSize = 168
    static let validFlag: UInt32 = 0x2019_1212
    static let maxMacros = 2, maxSteps = 18, defaultStepMs: UInt16 = 51

    var bytes: [UInt8]

    init?(bytes: [UInt8]) {
        guard bytes.count == Self.size else { return nil }
        self.bytes = bytes
    }

    /// 0 = Switch (S) mode slot, 1 = Windows (X) mode slot.
    var activeSlot: Int { min(Int(bytes[3]), 1) }
    var activeModeName: String { activeSlot == 0 ? "Switch (S)" : "Windows (X)" }

    var profileName: String {
        let base = Self.slotBase + activeSlot * Self.slotSize + 4
        let raw = Data(bytes[base..<base + 32])
        let name = String(data: raw, encoding: .utf16LittleEndian)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? ""
        return name.isEmpty ? "(unnamed)" : name
    }

    private var macroBase: Int { Self.slotBase + activeSlot * Self.slotSize + Self.macroOffset }

    var macros: [StickMacro] {
        let base = macroBase
        let count = min(Int(bytes[base + 4]), Self.maxMacros)
        return (0..<count).map { k in
            let r = base + 8 + k * 80
            let trigger = u32(r)
            let stepCount = min(Int(bytes[r + 76]), Self.maxSteps)
            let steps = (0..<stepCount).map { i in
                StickMacro.Step(buttons: u16(r + 40 + i * 2), ms: u16(r + 4 + i * 2))
            }
            return StickMacro(trigger: trigger, steps: steps)
        }
    }

    mutating func setMacros(_ list: [StickMacro]) {
        let base = macroBase
        for i in base..<base + Self.macroSize { bytes[i] = 0 }
        put32(Self.validFlag, at: base)
        bytes[base + 4] = UInt8(min(list.count, Self.maxMacros))
        for (k, macro) in list.prefix(Self.maxMacros).enumerated() {
            let r = base + 8 + k * 80
            put32(macro.trigger, at: r)
            for i in 0..<Self.maxSteps {
                let step = i < macro.steps.count ? macro.steps[i] : nil
                put16(step?.ms ?? Self.defaultStepMs, at: r + 4 + i * 2)
                put16(step?.buttons ?? 0, at: r + 40 + i * 2)
            }
            bytes[r + 76] = UInt8(min(macro.steps.count, Self.maxSteps))
        }
    }

    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
    private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
    private mutating func put16(_ v: UInt16, at i: Int) { bytes[i] = UInt8(v & 0xFF); bytes[i + 1] = UInt8(v >> 8) }
    private mutating func put32(_ v: UInt32, at i: Int) { put16(UInt16(v & 0xFFFF), at: i); put16(UInt16(v >> 16), at: i + 2) }
}

struct StickMacro: Equatable {
    struct Step: Equatable { var buttons: UInt16; var ms: UInt16 }
    var trigger: UInt32
    var steps: [Step]

    var summary: String {
        let seq = steps.map { "\(StickButtons.stepName($0.buttons)) \($0.ms)ms" }.joined(separator: ", ")
        return "\(StickButtons.triggerName(trigger)) → \(seq.isEmpty ? "no steps" : seq)"
    }
}

/// Button bit values used by the official software for the Arcade Stick.
enum StickButtons {
    static let triggers: [(name: String, mask: UInt32)] = [
        ("P1", 0x0200_0000), ("P2", 0x0400_0000),
        ("A", 0x2000), ("B", 0x1000), ("X", 0x10), ("Y", 0x20),
        ("L", 0x400), ("R", 0x800), ("ZL", 0x4000), ("ZR", 0x8000),
    ]
    /// Buttons allowed inside macro steps (the stick stores 16-bit step masks;
    /// Start/Select/Home aren't supported by the official editor either).
    static let steps: [(name: String, mask: UInt16)] = [
        ("A", 0x2000), ("B", 0x1000), ("X", 0x10), ("Y", 0x20),
        ("L", 0x400), ("R", 0x800), ("ZL", 0x4000), ("ZR", 0x8000),
        ("L3", 0x2), ("R3", 0x4),
        ("Up", 0x200), ("Down", 0x100), ("Left", 0x80), ("Right", 0x40),
    ]

    static func triggerName(_ mask: UInt32) -> String {
        triggers.first { $0.mask == mask }?.name ?? String(format: "0x%X", mask)
    }

    static func stepName(_ mask: UInt16) -> String {
        if mask == 0 { return "Wait" }
        let names = steps.filter { mask & $0.mask != 0 }.map(\.name)
        return names.isEmpty ? String(format: "0x%X", mask) : names.joined(separator: "+")
    }

    /// Accepts "A", "Wait", or combos like "A+B".
    static func stepMask(_ name: String) -> UInt16? {
        if name.caseInsensitiveCompare("Wait") == .orderedSame { return 0 }
        var mask: UInt16 = 0
        for part in name.split(separator: "+") {
            guard let m = steps.first(where: { $0.name.caseInsensitiveCompare(part.trimmingCharacters(in: .whitespaces)) == .orderedSame })?.mask
            else { return nil }
            mask |= m
        }
        return mask
    }

    /// Converts an editor macro to the stick format, or explains why it can't.
    static func convert(_ macro: GameMacro, trigger: UInt32) -> Result<StickMacro, StickConversionError> {
        if macro.steps.isEmpty { return .failure(.empty) }
        if macro.steps.count > StickSettings.maxSteps { return .failure(.tooManySteps(macro.steps.count)) }
        var steps: [StickMacro.Step] = []
        for step in macro.steps {
            guard let mask = stepMask(step.button) else { return .failure(.unsupportedButton(step.button)) }
            steps.append(.init(buttons: mask, ms: UInt16(clamping: max(10, step.durationMs))))
        }
        return .success(StickMacro(trigger: trigger, steps: steps))
    }
}

enum StickConversionError: Error, CustomStringConvertible {
    case empty, tooManySteps(Int), unsupportedButton(String)
    var description: String {
        switch self {
        case .empty: return "This macro has no steps."
        case .tooManySteps(let n): return "The stick holds at most 18 steps per macro; this one has \(n)."
        case .unsupportedButton(let b): return "\(b) can't be used inside a stick macro (Start, Select and Home aren't supported)."
        }
    }
}

extension StickSettings {
    /// Returns settings with `macro` placed in stick macro slot `slot` (0 or 1).
    /// Any other macro that uses the same trigger button is removed, because one
    /// button can only play one macro.
    func placing(_ macro: StickMacro, inSlot slot: Int) -> StickSettings {
        var list = macros
        let target = min(slot, list.count)
        if target < list.count { list[target] = macro } else { list.append(macro) }
        list = list.enumerated().filter { $0.offset == target || $0.element.trigger != macro.trigger }.map(\.element)
        var updated = self
        updated.setMacros(Array(list.prefix(Self.maxMacros)))
        return updated
    }

    /// Settings with every macro removed from the active profile ("restore to normal").
    func removingAllMacros() -> StickSettings {
        var updated = self
        updated.setMacros([])
        return updated
    }
}

extension StickMacro {
    /// Step names in the app's editor format ("A", "Down+Right", "Wait").
    var stepNames: [String] { steps.map { StickButtons.stepName($0.buttons) } }
    var triggerName: String { StickButtons.triggerName(trigger) }
}
