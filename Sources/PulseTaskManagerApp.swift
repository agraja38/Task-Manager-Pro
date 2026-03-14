import SwiftUI

@main
struct PulseTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    WindowRouter.shared.openMainWindow = {
                        openWindow(id: "main")
                    }
                }
        }
        .defaultSize(width: 1320, height: 860)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 620, height: 560)
        }
    }
}
