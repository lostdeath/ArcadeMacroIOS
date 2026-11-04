import SwiftUI

@main
struct ArcadeMacroApp: App {
    @StateObject private var bluetooth = BluetoothManager()
    @StateObject private var macros = MacroStore()

    var body: some Scene {
        WindowGroup {
            TabView {
                DeviceView().environmentObject(bluetooth)
                    .tabItem { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
                MacroView().environmentObject(macros)
                    .tabItem { Label("Macros", systemImage: "list.number") }
            }
            .tint(.red)
        }
    }
}
