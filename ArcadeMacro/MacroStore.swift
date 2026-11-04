import Foundation
import Combine
import GameController

struct MacroStep: Codable, Identifiable {
    var id = UUID()
    var button: String
    var durationMs: Int
}
struct GameMacro: Codable, Identifiable {
    var id = UUID()
    var name: String
    var steps: [MacroStep] = []
}
final class MacroStore: ObservableObject {
    @Published var macros: [GameMacro] = [] { didSet { save() } }
    @Published var selectedID: UUID?
    @Published var recording = false
    private let key = "saved-macros-v1"
    private var buttonDownAt: [String: Date] = [:]
    private var controllerObservers: [NSObjectProtocol] = []
    init() {
        if let data = UserDefaults.standard.data(forKey: key), let decoded = try? JSONDecoder().decode([GameMacro].self, from: data) { macros = decoded }
        if macros.isEmpty { macros = [GameMacro(name: "New Macro")] }
        selectedID = macros.first?.id
    }
    var selectedIndex: Int? { macros.firstIndex { $0.id == selectedID } }
    func save() { if let data = try? JSONEncoder().encode(macros) { UserDefaults.standard.set(data, forKey: key) } }
    func addMacro() { let m = GameMacro(name: "Macro \(macros.count + 1)"); macros.append(m); selectedID = m.id }
    func append(button: String, duration: Int = 100) { guard let i = selectedIndex else { return }; macros[i].steps.append(MacroStep(button: button, durationMs: duration)) }
    func removeStep(_ id: UUID) { guard let i = selectedIndex else { return }; macros[i].steps.removeAll { $0.id == id } }
    func toggleRecording() {
        if recording { stopRecording(); return }
        recording = true
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
        controllerObservers = [
            NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in self?.bindControllers() },
            NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in self?.bindControllers() }
        ]
        bindControllers()
    }
    private func bindControllers() {
        for controller in GCController.controllers() {
            if let pad = controller.extendedGamepad {
                bind(pad.buttonA, name: "A"); bind(pad.buttonB, name: "B"); bind(pad.buttonX, name: "X"); bind(pad.buttonY, name: "Y")
                bind(pad.leftShoulder, name: "L"); bind(pad.rightShoulder, name: "R"); bind(pad.leftTrigger, name: "ZL"); bind(pad.rightTrigger, name: "ZR")
                bind(pad.buttonMenu, name: "Start")
                if let options = pad.buttonOptions { bind(options, name: "Select") }
                bind(pad.dpad.up, name: "Up"); bind(pad.dpad.down, name: "Down"); bind(pad.dpad.left, name: "Left"); bind(pad.dpad.right, name: "Right")
            } else if let pad = controller.microGamepad {
                bind(pad.buttonA, name: "A"); bind(pad.buttonX, name: "X")
                bind(pad.dpad.up, name: "Up"); bind(pad.dpad.down, name: "Down"); bind(pad.dpad.left, name: "Left"); bind(pad.dpad.right, name: "Right")
            }
        }
    }
    private func bind(_ input: GCControllerButtonInput, name: String) {
        input.valueChangedHandler = { [weak self] _, _, pressed in
            guard let self, self.recording else { return }
            if pressed { self.buttonDownAt[name] = Date() }
            else if let start = self.buttonDownAt.removeValue(forKey: name) {
                self.append(button: name, duration: max(10, Int(Date().timeIntervalSince(start) * 1000)))
            }
        }
    }
    private func stopRecording() {
        recording = false
        for observer in controllerObservers { NotificationCenter.default.removeObserver(observer) }
        controllerObservers.removeAll(); buttonDownAt.removeAll()
        for controller in GCController.controllers() {
            controller.extendedGamepad?.valueChangedHandler = nil
            controller.microGamepad?.valueChangedHandler = nil
        }
    }
}
