import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var twoLineStatusView: NSStackView?
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
            removeTwoLineStatusView()
            button.attributedTitle = NSAttributedString(
                string: "C \(cpuText) M \(memoryText)",
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
        let visibleWindows = NSApplication.shared.windows.filter { !$0.isMiniaturized && $0.canBecomeKey }
        if visibleWindows.isEmpty {
            WindowRouter.shared.openMainWindow?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows {
                    window.makeKeyAndOrderFront(nil)
                }
            }
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

        cpuLabel.stringValue = "C \(cpuText)"
        memoryLabel.stringValue = "M \(memoryText)"
        stack.isHidden = false
    }

    private func removeTwoLineStatusView() {
        twoLineStatusView?.removeFromSuperview()
        twoLineStatusView = nil
    }
}
