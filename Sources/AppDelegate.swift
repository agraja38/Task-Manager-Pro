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
    private var fanStatusVerticalStack: NSStackView?
    private var fanAnimationTimer: Timer?
    private var fanAnimationFrameIndex = 0
    private lazy var fanAnimationFrames: [NSImage] = Self.makeFanAnimationFrames()
    private lazy var fanIdleImage: NSImage? = Self.makeTemplateFanBaseImage()
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
            stopFanAnimation()
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
            fanStatusItem?.button?.attributedTitle = NSAttributedString(string: "")
            removeFanStatusView()
            stopFanAnimation()
            return
        }

        let tempDisplay = AppState.shared.fanMenuTemperatureDisplay()
        let temperatureText = tempDisplay.value.map { String(format: "%.0f°C", $0) } ?? "--"
        let rpmText = "\(fan.rpm) rpm"
        let displayMode = AppState.shared.fanMenuDisplayMode
        let isSpinning = fan.rpm > 0

        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
        button.image = nil
        button.imagePosition = .noImage
        installFanStatusView(in: button, rpmText: rpmText, temperatureText: temperatureText, displayMode: displayMode)

        let tintColor = NSColor.labelColor
        button.contentTintColor = tintColor
        fanStatusIconView?.contentTintColor = tintColor

        if isSpinning {
            startFanAnimation()
        } else {
            stopFanAnimation()
        }
        renderFanAnimationFrame()
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

    private func installFanStatusView(in button: NSStatusBarButton, rpmText: String, temperatureText: String, displayMode: FanMenuDisplayMode) {
        let container: NSStackView
        let iconView: NSImageView
        let singleLabel: NSTextField
        let topLabel: NSTextField
        let bottomLabel: NSTextField
        let verticalStack: NSStackView

        if
            let existing = fanStatusView,
            let existingIcon = fanStatusIconView,
            let existingSingle = fanStatusSingleLineLabel,
            let existingTop = fanStatusTopLabel,
            let existingBottom = fanStatusBottomLabel,
            let existingVerticalStack = fanStatusVerticalStack
        {
            container = existing
            iconView = existingIcon
            singleLabel = existingSingle
            topLabel = existingTop
            bottomLabel = existingBottom
            verticalStack = existingVerticalStack
        } else {
            let createdIcon = NSImageView()
            createdIcon.image = fanIdleImage
            createdIcon.contentTintColor = .labelColor
            createdIcon.imageScaling = .scaleProportionallyDown
            createdIcon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                createdIcon.widthAnchor.constraint(equalToConstant: 13),
                createdIcon.heightAnchor.constraint(equalToConstant: 13)
            ])

            let createdSingle = NSTextField(labelWithString: "")
            createdSingle.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            createdSingle.textColor = .labelColor
            createdSingle.backgroundColor = .clear
            createdSingle.isBordered = false
            createdSingle.isEditable = false
            createdSingle.lineBreakMode = .byWordWrapping
            createdSingle.maximumNumberOfLines = 1
            createdSingle.setContentCompressionResistancePriority(.required, for: .horizontal)

            let createdTop = NSTextField(labelWithString: "")
            let createdBottom = NSTextField(labelWithString: "")
            [createdTop, createdBottom].forEach {
                $0.alignment = .center
                $0.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
                $0.textColor = .labelColor
                $0.backgroundColor = .clear
                $0.isBordered = false
                $0.isEditable = false
                $0.lineBreakMode = .byClipping
                $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            }

            let createdVerticalStack = NSStackView(views: [createdTop, createdBottom])
            createdVerticalStack.orientation = .vertical
            createdVerticalStack.alignment = .centerX
            createdVerticalStack.distribution = .fillEqually
            createdVerticalStack.spacing = -1

            let created = NSStackView(views: [createdIcon, createdSingle, createdVerticalStack])
            created.orientation = .horizontal
            created.alignment = .centerY
            created.spacing = 4
            created.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4)
            created.translatesAutoresizingMaskIntoConstraints = false

            button.addSubview(created)
            NSLayoutConstraint.activate([
                created.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
                created.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
                created.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                created.heightAnchor.constraint(lessThanOrEqualTo: button.heightAnchor)
            ])

            fanStatusView = created
            fanStatusIconView = createdIcon
            fanStatusSingleLineLabel = createdSingle
            fanStatusTopLabel = createdTop
            fanStatusBottomLabel = createdBottom
            fanStatusVerticalStack = createdVerticalStack

            container = created
            iconView = createdIcon
            singleLabel = createdSingle
            topLabel = createdTop
            bottomLabel = createdBottom
            verticalStack = createdVerticalStack
        }

        singleLabel.stringValue = "\(rpmText) / \(temperatureText)"
        topLabel.stringValue = rpmText
        bottomLabel.stringValue = temperatureText
        singleLabel.isHidden = displayMode != .singleLine
        verticalStack.isHidden = displayMode != .twoLine
        container.isHidden = false
        container.layoutSubtreeIfNeeded()

        let singleWidth = (singleLabel.stringValue as NSString).size(withAttributes: [.font: singleLabel.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]).width
        let topWidth = (topLabel.stringValue as NSString).size(withAttributes: [.font: topLabel.font ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)]).width
        let bottomWidth = (bottomLabel.stringValue as NSString).size(withAttributes: [.font: bottomLabel.font ?? NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)]).width
        let textWidth = displayMode == .singleLine ? singleWidth : max(topWidth, bottomWidth)
        fanStatusItem?.length = ceil(textWidth) + (displayMode == .singleLine ? 28 : 30)
    }

    private func removeFanStatusView() {
        fanStatusView?.removeFromSuperview()
        fanStatusView = nil
        fanStatusIconView = nil
        fanStatusSingleLineLabel = nil
        fanStatusTopLabel = nil
        fanStatusBottomLabel = nil
        fanStatusVerticalStack = nil
        stopFanAnimation()
    }

    private func startFanAnimation() {
        guard fanAnimationTimer == nil else { return }
        let animationTimer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.fanAnimationFrameIndex = (self.fanAnimationFrameIndex + 1) % max(self.fanAnimationFrames.count, 1)
                self.renderFanAnimationFrame()
            }
        }
        RunLoop.main.add(animationTimer, forMode: .common)
        fanAnimationTimer = animationTimer
    }

    private func renderFanAnimationFrame() {
        let image = currentFanAnimationImage()
        fanStatusIconView?.image = image?.asTemplateImage()
    }

    private func currentFanAnimationImage() -> NSImage? {
        guard !fanAnimationFrames.isEmpty else { return fanIdleImage }
        return fanAnimationTimer == nil ? fanIdleImage : fanAnimationFrames[fanAnimationFrameIndex]
    }

    private func stopFanAnimation() {
        fanAnimationTimer?.invalidate()
        fanAnimationTimer = nil
        fanAnimationFrameIndex = 0
        renderFanAnimationFrame()
    }

    private static func makeFanAnimationFrames() -> [NSImage] {
        guard let baseImage = makeTemplateFanBaseImage() else {
            return []
        }

        return stride(from: 0.0, to: Double.pi * 2, by: Double.pi / 4).compactMap { angle in
            baseImage.rotated(by: angle)?.asTemplateImage()
        }
    }

    private static func makeTemplateFanBaseImage() -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        let image = NSImage(
            systemSymbolName: "fan.fill",
            accessibilityDescription: "Fan Controller"
        )?.withSymbolConfiguration(configuration)
        image?.isTemplate = true
        return image
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

private extension NSImage {
    func asTemplateImage() -> NSImage {
        let copy = self.copy() as? NSImage ?? self
        copy.isTemplate = true
        return copy
    }

    func rotated(by radians: Double) -> NSImage? {
        let result = NSImage(size: size)
        result.lockFocus()
        guard let context = NSGraphicsContext.current?.cgContext else {
            result.unlockFocus()
            return nil
        }

        context.translateBy(x: size.width / 2, y: size.height / 2)
        context.rotate(by: radians)
        context.translateBy(x: -size.width / 2, y: -size.height / 2)
        draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = true
        return result
    }
}
