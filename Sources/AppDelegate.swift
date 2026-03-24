import AppKit
import QuartzCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var fanStatusItem: NSStatusItem?
    private var twoLineStatusView: NSStackView?
    private var fanStatusView: NSStackView?
    private var fanStatusIconView: NSImageView?
    private var fanStatusSingleLineLabel: NSTextField?
    private var fanStatusTopLabel: NSTextField?
    private var fanStatusBottomLabel: NSTextField?
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
        updateFanStatusItemDisplay()
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
        let showsFanController = UserDefaults.standard.object(forKey: "showsFanControllerMenuBarItem") as? Bool ?? false

        if mode == .off {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        } else {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                item.menu = NSMenu()
                statusItem = item
            }

            rebuildStatusMenu()
            updateStatusItemDisplay()
        }

        if showsFanController && AppState.shared.showsAdvancedTelemetryWidgets {
            if fanStatusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
                item.menu = NSMenu()
                fanStatusItem = item
            }
            rebuildFanStatusMenu()
            updateFanStatusItemDisplay()
        } else if let fanStatusItem {
            NSStatusBar.system.removeStatusItem(fanStatusItem)
            self.fanStatusItem = nil
            removeFanStatusView()
        }
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

    private func updateFanStatusItemDisplay() {
        guard let button = fanStatusItem?.button, let fan = AppState.shared.selectedFanForMenu() else {
            fanStatusItem?.button?.title = ""
            fanStatusItem?.button?.image = nil
            removeFanStatusView()
            return
        }

        let tempDisplay = AppState.shared.fanMenuTemperatureDisplay()
        let temperatureText = tempDisplay.value.map { "\(Int($0.rounded()))C" } ?? "--"
        let rpmText = "\(fan.rpm)rpm"
        let displayMode = AppState.shared.fanMenuDisplayMode

        button.title = ""
        button.image = nil
        fanStatusItem?.length = displayMode == .singleLine ? NSStatusItem.variableLength : 58
        installFanStatusView(in: button, rpmText: rpmText, temperatureText: temperatureText, displayMode: displayMode, isSpinning: fan.rpm > 0)
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

    private func installFanStatusView(in button: NSStatusBarButton, rpmText: String, temperatureText: String, displayMode: FanMenuDisplayMode, isSpinning: Bool) {
        let container: NSStackView
        let iconView: NSImageView
        let singleLabel: NSTextField
        let topLabel: NSTextField
        let bottomLabel: NSTextField

        if
            let existing = fanStatusView,
            let existingIcon = fanStatusIconView,
            let existingSingle = fanStatusSingleLineLabel,
            let existingTop = fanStatusTopLabel,
            let existingBottom = fanStatusBottomLabel
        {
            container = existing
            iconView = existingIcon
            singleLabel = existingSingle
            topLabel = existingTop
            bottomLabel = existingBottom
        } else {
            let createdIcon = NSImageView()
            createdIcon.image = NSImage(systemSymbolName: "fan.fill", accessibilityDescription: "Fan Controller")
            createdIcon.contentTintColor = .labelColor
            createdIcon.translatesAutoresizingMaskIntoConstraints = false
            createdIcon.wantsLayer = true
            NSLayoutConstraint.activate([
                createdIcon.widthAnchor.constraint(equalToConstant: 12),
                createdIcon.heightAnchor.constraint(equalToConstant: 12)
            ])

            let createdSingle = NSTextField(labelWithString: "")
            createdSingle.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            createdSingle.textColor = .labelColor
            createdSingle.backgroundColor = .clear
            createdSingle.isBordered = false
            createdSingle.isEditable = false
            createdSingle.lineBreakMode = .byClipping

            let createdTop = NSTextField(labelWithString: "")
            let createdBottom = NSTextField(labelWithString: "")
            [createdTop, createdBottom].forEach {
                $0.alignment = .left
                $0.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                $0.textColor = .labelColor
                $0.backgroundColor = .clear
                $0.isBordered = false
                $0.isEditable = false
            }

            let verticalStack = NSStackView(views: [createdTop, createdBottom])
            verticalStack.orientation = .vertical
            verticalStack.alignment = .leading
            verticalStack.distribution = .fillEqually
            verticalStack.spacing = -1

            let created = NSStackView(views: [createdIcon, createdSingle, verticalStack])
            created.orientation = .horizontal
            created.alignment = .centerY
            created.spacing = 5
            created.translatesAutoresizingMaskIntoConstraints = false

            button.addSubview(created)
            NSLayoutConstraint.activate([
                created.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                created.centerYAnchor.constraint(equalTo: button.centerYAnchor)
            ])

            fanStatusView = created
            fanStatusIconView = createdIcon
            fanStatusSingleLineLabel = createdSingle
            fanStatusTopLabel = createdTop
            fanStatusBottomLabel = createdBottom

            container = created
            iconView = createdIcon
            singleLabel = createdSingle
            topLabel = createdTop
            bottomLabel = createdBottom
        }

        singleLabel.stringValue = "\(rpmText) / \(temperatureText)"
        topLabel.stringValue = rpmText
        bottomLabel.stringValue = temperatureText
        singleLabel.isHidden = displayMode != .singleLine
        topLabel.superview?.isHidden = displayMode != .twoLine
        container.isHidden = false

        if isSpinning {
            startFanIconAnimationIfNeeded(iconView)
        } else {
            stopFanIconAnimation(iconView)
        }
    }

    private func removeFanStatusView() {
        fanStatusView?.removeFromSuperview()
        fanStatusView = nil
        fanStatusIconView = nil
        fanStatusSingleLineLabel = nil
        fanStatusTopLabel = nil
        fanStatusBottomLabel = nil
    }

    private func startFanIconAnimationIfNeeded(_ imageView: NSImageView) {
        guard imageView.layer?.animation(forKey: "spin") == nil else { return }
        imageView.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = Double.pi * 2
        animation.duration = 0.8
        animation.repeatCount = .infinity
        imageView.layer?.add(animation, forKey: "spin")
    }

    private func stopFanIconAnimation(_ imageView: NSImageView) {
        imageView.layer?.removeAnimation(forKey: "spin")
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

    private func rebuildFanStatusMenu() {
        guard let menu = fanStatusItem?.menu else { return }
        menu.removeAllItems()

        menu.addItem(withTitle: "Open Fan Controls", action: #selector(openThermalsWindow), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let autoItem = NSMenuItem(title: "Auto", action: #selector(applyAutomaticFanControl), keyEquivalent: "")
        autoItem.target = self
        menu.addItem(autoItem)

        let fullBlastItem = NSMenuItem(title: "Full Blast", action: #selector(applyFullBlastFanControl), keyEquivalent: "")
        fullBlastItem.target = self
        menu.addItem(fullBlastItem)

        for preset in AppState.shared.fanPresets {
            let item = NSMenuItem(title: preset.name, action: #selector(applyFanPresetFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id.uuidString
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Task Manager Pro", action: #selector(quitApp), keyEquivalent: "q")
    }

    @objc private func applyFanPresetFromMenu(_ sender: NSMenuItem) {
        guard
            let idString = sender.representedObject as? String,
            let id = UUID(uuidString: idString),
            let preset = AppState.shared.fanPresets.first(where: { $0.id == id })
        else {
            return
        }

        AppState.shared.applyFanPreset(preset)
    }

    @objc private func openThermalsWindow() {
        AppState.shared.selectedSection = .thermals
        openMainWindow()
    }

    @objc private func applyAutomaticFanControl() {
        AppState.shared.setAutomaticFanControl()
    }

    @objc private func applyFullBlastFanControl() {
        AppState.shared.setFullBlastFanControl()
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
