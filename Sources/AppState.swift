import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var selectedSection: TopSection = .processes
    @Published var cpuGraphMode: CPUGraphMode = UserDefaults.standard.string(forKey: "cpuGraphMode").flatMap(CPUGraphMode.init(rawValue:)) ?? .overall {
        didSet {
            UserDefaults.standard.set(cpuGraphMode.rawValue, forKey: "cpuGraphMode")
        }
    }
    @Published var processFilter: ProcessFilter = .appsOnly
    @Published var sortKey: ProcessSortKey = .cpu
    @Published var searchText = ""
    @Published var visiblePerformanceWidgets: [PerformanceWidgetKind] = AppState.loadVisiblePerformanceWidgets() {
        didSet {
            UserDefaults.standard.set(visiblePerformanceWidgets.map(\.rawValue), forKey: "visiblePerformanceWidgets")
        }
    }
    @Published var performanceWidgetSizes: [PerformanceWidgetKind: PerformanceWidgetSize] = AppState.loadPerformanceWidgetSizes() {
        didSet {
            let rawMap = Dictionary(uniqueKeysWithValues: performanceWidgetSizes.map { ($0.key.rawValue, $0.value.rawValue) })
            UserDefaults.standard.set(rawMap, forKey: "performanceWidgetSizes")
        }
    }
    @Published var selectedPID: Int32?
    @Published var processes: [ProcessSnapshot] = []
    @Published var alerts: [AlertItem] = []
    @Published var latestError = ""
    @Published var currentMetrics = PerformanceSnapshot(
        cpuPercent: 0,
        perCoreCPUPercent: [],
        memoryPercent: 0,
        usedMemoryGB: 0,
        totalMemoryGB: 0,
        diskReadMBps: 0,
        diskWriteMBps: 0,
        networkInKBps: 0,
        networkOutKBps: 0,
        gpuPercent: nil,
        batteryPercent: nil,
        isCharging: nil,
        thermalLevel: "Unknown",
        note: ""
    )
    @Published var cpuHistory: [TimePoint] = []
    @Published var perCoreCPUHistory: [[TimePoint]] = []
    @Published var memoryHistory: [TimePoint] = []
    @Published var diskHistory: [TimePoint] = []
    @Published var networkHistory: [TimePoint] = []
    @Published var gpuHistory: [TimePoint] = []
    @Published var processHistory: [Int32: [TimePoint]] = [:]
    @Published var memoryProcessHistory: [Int32: [TimePoint]] = [:]

    @Published var cpuAlertThreshold = 85.0
    @Published var memoryAlertThreshold = 85.0
    @Published var menuBarDisplayMode: MenuBarDisplayMode = UserDefaults.standard.string(forKey: "menuBarDisplayMode").flatMap(MenuBarDisplayMode.init(rawValue:)) ?? .compact {
        didSet {
            UserDefaults.standard.set(menuBarDisplayMode.rawValue, forKey: "menuBarDisplayMode")
            NotificationCenter.default.post(name: .pulseTaskMenuBarPreferencesDidChange, object: nil, userInfo: ["mode": menuBarDisplayMode.rawValue])
        }
    }
    @Published var appearanceMode: AppearanceMode = UserDefaults.standard.string(forKey: "appearanceMode").flatMap(AppearanceMode.init(rawValue:)) ?? .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            applyAppearanceMode()
        }
    }
    @Published var showsDockIcon: Bool = UserDefaults.standard.object(forKey: "showsDockIcon") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showsDockIcon, forKey: "showsDockIcon")
            NotificationCenter.default.post(name: .pulseTaskPresentationPreferencesDidChange, object: nil, userInfo: ["showsDockIcon": showsDockIcon])
        }
    }

    let updater = UpdaterService()

    private let processService = ProcessMonitorService()
    private let metricsService = SystemMetricsService()
    private var timer: Timer?

    private init() {
        applyAppearanceMode()
        refreshAll()
        startTimers()
    }

    var filteredProcesses: [ProcessSnapshot] {
        let base = processes.filter { process in
            let matchesSearch = searchText.isEmpty ||
                process.name.localizedCaseInsensitiveContains(searchText) ||
                process.bundleIdentifier.localizedCaseInsensitiveContains(searchText) ||
                process.executablePath.localizedCaseInsensitiveContains(searchText)

            let matchesFilter: Bool
            switch processFilter {
            case .all: matchesFilter = true
            case .appsOnly: matchesFilter = process.isApp
            }

            return matchesSearch && matchesFilter
        }

        switch sortKey {
        case .cpu: return base.sorted { $0.cpuUsage > $1.cpuUsage }
        case .memory: return base.sorted { $0.memoryMB > $1.memoryMB }
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .energy: return base.sorted { $0.energyImpact > $1.energyImpact }
        }
    }

    func refreshAll() {
        let appMetadataByPID = Dictionary(uniqueKeysWithValues: NSWorkspace.shared.runningApplications.map { app in
            (
                app.processIdentifier,
                RunningAppMetadata(
                    pid: app.processIdentifier,
                    localizedName: app.localizedName ?? "",
                    bundleIdentifier: app.bundleIdentifier ?? "",
                    executablePath: app.executableURL?.path ?? "",
                    isActive: app.isActive,
                    isFinishedLaunching: app.isFinishedLaunching,
                    isRegularApp: app.activationPolicy == .regular,
                    architecture: app.executableArchitecture == CPU_TYPE_X86_64 ? "Intel" : "Apple Silicon / Native"
                )
            )
        })
        let processService = self.processService
        let metricsService = self.metricsService

        Task.detached(priority: .userInitiated) {
            let processes = processService.fetchProcesses(appMetadataByPID: appMetadataByPID)
            let metrics = metricsService.sample()

            await MainActor.run {
                self.processes = processes
                self.currentMetrics = metrics
                self.appendHistory(snapshot: metrics, processes: processes)
                self.raiseAlertsIfNeeded(processes: processes, metrics: metrics)
                if processes.isEmpty {
                    self.latestError = "Task Manager Pro could not load the process list. Try refreshing again."
                } else if self.latestError.contains("could not load") {
                    self.latestError = ""
                }
                if self.selectedPID == nil || !processes.contains(where: { $0.pid == self.selectedPID }) {
                    self.selectedPID = self.filteredProcesses.first?.pid
                }

                NotificationCenter.default.post(name: .pulseTaskMetricsDidUpdate, object: nil, userInfo: [
                    "cpuPercent": metrics.cpuPercent,
                    "memoryPercent": metrics.memoryPercent
                ])
            }
        }
    }

    func execute(_ action: ProcessAction, for process: ProcessSnapshot) {
        if process.isCritical {
            latestError = "Task Manager Pro blocked the action because \(process.name) looks critical to macOS."
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(action.rawValue) \(process.name)?"
        alert.informativeText = process.isApp
            ? "Task Manager Pro will ask macOS to \(action.rawValue.lowercased()) this app."
            : "Task Manager Pro will send a Unix signal to PID \(process.pid)."
        alert.alertStyle = action == .forceQuit ? .warning : .informational
        alert.addButton(withTitle: action.rawValue)
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try processService.perform(action, on: process)
            latestError = "\(action.rawValue) sent to \(process.name)."
            refreshAll()
        } catch {
            latestError = error.localizedDescription
        }
    }

    func startUpdateFlow() {
        Task { await updater.checkForUpdates() }
    }

    func installAvailableUpdate() {
        Task { await updater.installPreparedUpdate() }
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func applyAppearanceMode() {
        switch appearanceMode {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func appendHistory(snapshot: PerformanceSnapshot, processes: [ProcessSnapshot]) {
        let now = Date()
        cpuHistory = trimmed(cpuHistory + [TimePoint(timestamp: now, value: snapshot.cpuPercent)])
        syncPerCoreHistory(with: snapshot.perCoreCPUPercent, timestamp: now)
        memoryHistory = trimmed(memoryHistory + [TimePoint(timestamp: now, value: snapshot.memoryPercent)])
        diskHistory = trimmed(diskHistory + [TimePoint(timestamp: now, value: snapshot.diskReadMBps + snapshot.diskWriteMBps)])
        networkHistory = trimmed(networkHistory + [TimePoint(timestamp: now, value: snapshot.networkInKBps + snapshot.networkOutKBps)])
        gpuHistory = trimmed(gpuHistory + [TimePoint(timestamp: now, value: snapshot.gpuPercent ?? 0)])

        for process in processes.prefix(20) {
            processHistory[process.pid] = trimmed((processHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.cpuUsage)])
            memoryProcessHistory[process.pid] = trimmed((memoryProcessHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.memoryMB)])
        }
    }

    private func syncPerCoreHistory(with samples: [Double], timestamp: Date) {
        guard !samples.isEmpty else {
            perCoreCPUHistory = []
            return
        }

        if perCoreCPUHistory.count != samples.count {
            perCoreCPUHistory = Array(repeating: [], count: samples.count)
        }

        for (index, sample) in samples.enumerated() {
            perCoreCPUHistory[index] = trimmed(perCoreCPUHistory[index] + [TimePoint(timestamp: timestamp, value: sample)])
        }
    }

    private func trimmed(_ values: [TimePoint], limit: Int = 60) -> [TimePoint] {
        Array(values.suffix(limit))
    }

    private func raiseAlertsIfNeeded(processes: [ProcessSnapshot], metrics: PerformanceSnapshot) {
        var newAlerts: [AlertItem] = []

        if metrics.cpuPercent >= cpuAlertThreshold {
            newAlerts.append(AlertItem(title: "High CPU load", message: String(format: "CPU usage reached %.0f%%.", metrics.cpuPercent), level: "Warning", timestamp: Date()))
        }

        if metrics.memoryPercent >= memoryAlertThreshold {
            newAlerts.append(AlertItem(title: "High memory pressure", message: String(format: "Memory usage reached %.0f%%.", metrics.memoryPercent), level: "Warning", timestamp: Date()))
        }

        if metrics.thermalLevel == "Serious" || metrics.thermalLevel == "Critical" {
            newAlerts.append(AlertItem(title: "Thermal warning", message: "macOS reports the system thermal state as \(metrics.thermalLevel).", level: "Critical", timestamp: Date()))
        }

        if let hung = processes.first(where: { $0.status == "Uninterruptible" || $0.status == "Zombie" }) {
            newAlerts.append(AlertItem(title: "App may be unresponsive", message: "\(hung.name) is in state \(hung.status).", level: "Warning", timestamp: Date()))
        }

        if !newAlerts.isEmpty {
            alerts = Array((newAlerts + alerts).prefix(12))
        }
    }

    func widgetSize(for widget: PerformanceWidgetKind) -> PerformanceWidgetSize {
        performanceWidgetSizes[widget] ?? .regular
    }

    func setWidgetSize(_ size: PerformanceWidgetSize, for widget: PerformanceWidgetKind) {
        performanceWidgetSizes[widget] = size
    }

    func removeWidget(_ widget: PerformanceWidgetKind) {
        visiblePerformanceWidgets.removeAll { $0 == widget }
    }

    func addWidget(_ widget: PerformanceWidgetKind) {
        guard !visiblePerformanceWidgets.contains(widget) else { return }
        visiblePerformanceWidgets.append(widget)
    }

    var hiddenPerformanceWidgets: [PerformanceWidgetKind] {
        PerformanceWidgetKind.allCases.filter { !visiblePerformanceWidgets.contains($0) }
    }

    private static func loadVisiblePerformanceWidgets() -> [PerformanceWidgetKind] {
        guard let saved = UserDefaults.standard.array(forKey: "visiblePerformanceWidgets") as? [String] else {
            return PerformanceWidgetKind.allCases
        }

        let widgets = saved.compactMap(PerformanceWidgetKind.init(rawValue:))
        return widgets.isEmpty ? PerformanceWidgetKind.allCases : widgets
    }

    private static func loadPerformanceWidgetSizes() -> [PerformanceWidgetKind: PerformanceWidgetSize] {
        guard let saved = UserDefaults.standard.dictionary(forKey: "performanceWidgetSizes") as? [String: String] else {
            return [:]
        }

        var sizes: [PerformanceWidgetKind: PerformanceWidgetSize] = [:]
        for (key, value) in saved {
            guard
                let widget = PerformanceWidgetKind(rawValue: key),
                let size = PerformanceWidgetSize(rawValue: value)
            else { continue }
            sizes[widget] = size
        }
        return sizes
    }
}
