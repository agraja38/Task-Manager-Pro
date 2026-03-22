import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var twoLineStatusView: NSStackView?
    private var latestCPUPercent = 0.0
    private var latestMemoryPercent = 0.0
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("Task Manager Pro stays available as a background monitor.")
        ProcessInfo.processInfo.disableSuddenTermination()
        applyActivationPolicy()
        applyMenuBarMode()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMetricsUpdate(_:)),
            name: .pulseTaskMetricsDidUpdate,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarPreferenceChange(_:)),
            name: .pulseTaskMenuBarPreferencesDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePresentationPreferenceChange(_:)),
            name: .pulseTaskPresentationPreferencesDidChange,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSystemWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func handleMetricsUpdate(_ notification: Notification) {
        latestCPUPercent = notification.userInfo?["cpuPercent"] as? Double ?? 0
        latestMemoryPercent = notification.userInfo?["memoryPercent"] as? Double ?? 0
        updateStatusItemDisplay()
    }

    @objc private func handleMenuBarPreferenceChange(_ notification: Notification) {
        applyMenuBarMode()
    }

    @objc private func handleWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, !isSettingsWindow(window) else { return }
        mainWindow = window
        window.delegate = self
    }

    @objc private func handlePresentationPreferenceChange(_ notification: Notification) {
        applyActivationPolicy()
    }

    @objc private func handleSystemSleep(_ notification: Notification) {
        AppState.shared.handleSystemSleep()
    }

    @objc private func handleSystemWake(_ notification: Notification) {
        AppState.shared.handleSystemWake()
    }

    private func applyActivationPolicy() {
        let showsDockIcon = UserDefaults.standard.object(forKey: "showsDockIcon") as? Bool ?? true
        NSApp.setActivationPolicy(showsDockIcon ? .regular : .accessory)
    }

    private func applyMenuBarMode() {
        let mode = UserDefaults.standard.string(forKey: "menuBarDisplayMode").flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .compact

        if mode == .off {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
            return
        }

        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            item.menu = NSMenu()
            statusItem = item
        }

        rebuildStatusMenu()
        updateStatusItemDisplay()
    }

    private func updateStatusItemDisplay() {
        guard let button = statusItem?.button, let statusItem else { return }

        let mode = UserDefaults.standard.string(forKey: "menuBarDisplayMode").flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .compact
        let cpuText = String(format: "%.0f%%", latestCPUPercent)
        let memoryText = String(format: "%.0f%%", latestMemoryPercent)

        switch mode {
        case .compact:
            statusItem.length = NSStatusItem.variableLength
            removeTwoLineStatusView()
            button.attributedTitle = NSAttributedString(
                string: "CPU \(cpuText) RAM \(memoryText)",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]
            )
            button.image = nil
        case .twoLine:
            statusItem.length = 54
            button.attributedTitle = NSAttributedString(string: "")
            button.image = nil
            installTwoLineStatusView(cpuText: cpuText, memoryText: memoryText, in: button)
        case .off:
            break
        }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        WindowRouter.shared.openMainWindow?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow?.makeKeyAndOrderFront(nil)
            for window in NSApplication.shared.windows where !self.isSettingsWindow(window) {
                self.mainWindow = window
                window.delegate = self
                window.makeKeyAndOrderFront(nil)
                break
            }
        }
    }

    @objc private func checkForUpdates() {
        Task { await AppState.shared.updater.checkForUpdates() }
        openMainWindow()
    }

    @objc private func clearMemory() {
        AppState.shared.clearCache()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func installTwoLineStatusView(cpuText: String, memoryText: String, in button: NSStatusBarButton) {
        let stack: NSStackView
        let cpuLabel: NSTextField
        let memoryLabel: NSTextField

        if
            let existing = twoLineStatusView,
            let first = existing.views.first as? NSTextField,
            let second = existing.views.last as? NSTextField
        {
            stack = existing
            cpuLabel = first
            memoryLabel = second
        } else {
            let first = NSTextField(labelWithString: "")
            let second = NSTextField(labelWithString: "")
            [first, second].forEach {
                $0.alignment = .center
                $0.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                $0.textColor = NSColor.labelColor
                $0.backgroundColor = .clear
                $0.isBordered = false
                $0.isEditable = false
                $0.translatesAutoresizingMaskIntoConstraints = false
            }

            let created = NSStackView(views: [first, second])
            created.orientation = .vertical
            created.alignment = .centerX
            created.distribution = .fillEqually
            created.spacing = -1
            created.translatesAutoresizingMaskIntoConstraints = false

            button.addSubview(created)
            NSLayoutConstraint.activate([
                created.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                created.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                created.widthAnchor.constraint(equalToConstant: 42)
            ])
            twoLineStatusView = created
            stack = created
            cpuLabel = first
            memoryLabel = second
        }

        cpuLabel.stringValue = "CPU \(cpuText)"
        memoryLabel.stringValue = "RAM \(memoryText)"
        stack.isHidden = false
    }

    private func removeTwoLineStatusView() {
        twoLineStatusView?.removeFromSuperview()
        twoLineStatusView = nil
    }

    private func rebuildStatusMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(withTitle: "Open Task Manager Pro", action: #selector(openMainWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Clear Cache", action: #selector(clearMemory), keyEquivalent: "")

        menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Task Manager Pro", action: #selector(quitApp), keyEquivalent: "q")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSettingsWindow(sender) else { return true }
        sender.orderOut(nil)
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return false
    }

    private func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.title.localizedCaseInsensitiveContains("settings")
    }
}
