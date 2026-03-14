import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupStatusItem()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetricsUpdate(_:)),
            name: .pulseTaskMetricsDidUpdate,
            object: nil
        )
    }

    @objc private func handleMetricsUpdate(_ notification: Notification) {
        guard
            let summary = notification.userInfo?["summary"] as? String,
            let button = statusItem?.button
        else { return }

        button.title = summary
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "CPU --  MEM --"
        item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)

        let menu = NSMenu()
        menu.addItem(withTitle: "Open PulseTask Manager", action: #selector(openMainWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Refresh Now", action: #selector(forceRefresh), keyEquivalent: "")
        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit PulseTask Manager", action: #selector(quitApp), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func forceRefresh() {
        AppState.shared.refreshAll()
    }

    @objc private func checkForUpdates() {
        Task { await AppState.shared.updater.checkForUpdates(force: true) }
        openMainWindow()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
