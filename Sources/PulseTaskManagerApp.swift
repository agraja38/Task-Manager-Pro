import SwiftUI

@main
struct PulseTaskManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 1320, height: 860)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 620, height: 560)
        }
    }
}
