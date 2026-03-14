import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var latestCPUPercent = 0.0
    private var latestMemoryPercent = 0.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyActivationPolicy()
        applyMenuBarMode()
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
    }

    @objc private func handleMetricsUpdate(_ notification: Notification) {
        latestCPUPercent = notification.userInfo?["cpuPercent"] as? Double ?? 0
        latestMemoryPercent = notification.userInfo?["memoryPercent"] as? Double ?? 0
        updateStatusItemDisplay()
    }

    @objc private func handleMenuBarPreferenceChange(_ notification: Notification) {
        applyMenuBarMode()
    }

    @objc private func handlePresentationPreferenceChange(_ notification: Notification) {
        applyActivationPolicy()
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

            let menu = NSMenu()
            menu.addItem(withTitle: "Open Task Manager Pro", action: #selector(openMainWindow), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "")
            menu.addItem(NSMenuItem.separator())
            menu.addItem(withTitle: "Quit Task Manager Pro", action: #selector(quitApp), keyEquivalent: "q")
            item.menu = menu
            statusItem = item
        }

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
            button.attributedTitle = NSAttributedString(
                string: "C \(cpuText) M \(memoryText)",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]
            )
            button.image = nil
        case .twoLine:
            statusItem.length = 54
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            button.attributedTitle = NSAttributedString(
                string: "C \(cpuText)\nM \(memoryText)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                    .paragraphStyle: paragraph
                ]
            )
            button.image = nil
            button.frame = NSRect(x: 0, y: 0, width: 54, height: button.frame.height)
        case .off:
            break
        }
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let visibleWindows = NSApplication.shared.windows.filter { !$0.isMiniaturized && $0.canBecomeKey }
        if visibleWindows.isEmpty {
            WindowRouter.shared.openMainWindow?()
        }
        for window in NSApplication.shared.windows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func checkForUpdates() {
        Task { await AppState.shared.updater.checkForUpdates() }
        openMainWindow()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
