import SwiftUI

@main
struct ArcadeMacroApp: App {
    @StateObject private var bluetooth = BluetoothManager()
    @StateObject private var macros = MacroStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                StickHomeView()
                    .tabItem { Label("Stick", systemImage: "gamecontroller.fill") }
                MacroEditorView()
                    .tabItem { Label("Macros", systemImage: "square.grid.3x2.fill") }
                DeviceView()
                    .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            }
            .environmentObject(bluetooth)
            .environmentObject(macros)
            .tint(.red)
        }
    }
}
