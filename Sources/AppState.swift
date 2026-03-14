import AppKit
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var sidebarSelection: SidebarSection? = .processes
    @Published var displayMode: DisplayMode = .advanced
    @Published var processFilter: ProcessFilter = .all
    @Published var sortKey: ProcessSortKey = .cpu
    @Published var searchText = ""
    @Published var treeViewEnabled = false
    @Published var selectedPID: Int32?
    @Published var processes: [ProcessSnapshot] = []
    @Published var startupItems: [StartupItem] = []
    @Published var alerts: [AlertItem] = []
    @Published var latestError = ""
    @Published var currentMetrics = PerformanceSnapshot(
        cpuPercent: 0,
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
    @Published var memoryHistory: [TimePoint] = []
    @Published var diskHistory: [TimePoint] = []
    @Published var networkHistory: [TimePoint] = []
    @Published var gpuHistory: [TimePoint] = []
    @Published var processHistory: [Int32: [TimePoint]] = [:]
    @Published var memoryProcessHistory: [Int32: [TimePoint]] = [:]

    @Published var cpuAlertThreshold = 85.0
    @Published var memoryAlertThreshold = 85.0
    @Published var updateSheetPresented = false

    let updater = UpdaterService()

    private let processService = ProcessMonitorService()
    private let metricsService = SystemMetricsService()
    private let startupService = StartupItemsService()
    private var timer: Timer?

    private init() {
        refreshAll()
        startTimers()
    }

    var filteredProcesses: [ProcessSnapshot] {
        let currentUser = NSUserName()
        let base = processes.filter { process in
            let matchesSearch = searchText.isEmpty ||
                process.name.localizedCaseInsensitiveContains(searchText) ||
                process.bundleIdentifier.localizedCaseInsensitiveContains(searchText) ||
                process.executablePath.localizedCaseInsensitiveContains(searchText)

            let matchesFilter: Bool
            switch processFilter {
            case .all: matchesFilter = true
            case .appsOnly: matchesFilter = process.isApp
            case .currentUser: matchesFilter = process.user == currentUser
            case .heavy: matchesFilter = process.isHeavy
            }

            return matchesSearch && matchesFilter
        }

        switch sortKey {
        case .cpu: return base.sorted { $0.cpuUsage > $1.cpuUsage }
        case .memory: return base.sorted { $0.memoryMB > $1.memoryMB }
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .pid: return base.sorted { $0.pid < $1.pid }
        case .energy: return base.sorted { $0.energyImpact > $1.energyImpact }
        }
    }

    var selectedProcess: ProcessSnapshot? {
        guard let selectedPID else { return filteredProcesses.first }
        return processes.first(where: { $0.pid == selectedPID }) ?? filteredProcesses.first
    }

    var childProcesses: [ProcessSnapshot] {
        guard let selected = selectedProcess else { return [] }
        return selected.childPIDs.compactMap { pid in processes.first(where: { $0.pid == pid }) }
    }

    func refreshAll() {
        let processService = self.processService
        let metricsService = self.metricsService
        let startupService = self.startupService

        Task.detached(priority: .userInitiated) {
            let processes = processService.fetchProcesses()
            let metrics = metricsService.sample()
            let startupItems = startupService.fetchStartupItems()

            await MainActor.run {
                self.processes = processes
                self.startupItems = startupItems
                self.currentMetrics = metrics
                self.appendHistory(snapshot: metrics, processes: processes)
                self.raiseAlertsIfNeeded(processes: processes, metrics: metrics)
                self.latestError = ""
                if self.selectedPID == nil {
                    self.selectedPID = self.filteredProcesses.first?.pid
                }

                let summary = String(format: "CPU %2.0f%%  MEM %2.0f%%", metrics.cpuPercent, metrics.memoryPercent)
                NotificationCenter.default.post(name: .pulseTaskMetricsDidUpdate, object: nil, userInfo: ["summary": summary])
            }
        }
    }

    func execute(_ action: ProcessAction, for process: ProcessSnapshot) {
        if process.isCritical {
            latestError = "PulseTask Manager blocked the action because \(process.name) looks critical to macOS."
            return
        }

        let alert = NSAlert()
        alert.messageText = "\(action.rawValue) \(process.name)?"
        alert.informativeText = process.isApp
            ? "PulseTask Manager will ask macOS to \(action.rawValue.lowercased()) this app."
            : "PulseTask Manager will send a Unix signal to PID \(process.pid)."
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

    func exportSnapshot(asJSON: Bool) {
        do {
            try ExportService.export(processes: filteredProcesses, metrics: currentMetrics, asJSON: asJSON)
            latestError = "Snapshot exported."
        } catch {
            latestError = "Export failed: \(error.localizedDescription)"
        }
    }

    func startUpdateFlow() {
        updateSheetPresented = true
        Task { await updater.checkForUpdates(force: true) }
    }

    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func appendHistory(snapshot: PerformanceSnapshot, processes: [ProcessSnapshot]) {
        let now = Date()
        cpuHistory = trimmed(cpuHistory + [TimePoint(timestamp: now, value: snapshot.cpuPercent)])
        memoryHistory = trimmed(memoryHistory + [TimePoint(timestamp: now, value: snapshot.memoryPercent)])
        diskHistory = trimmed(diskHistory + [TimePoint(timestamp: now, value: snapshot.diskReadMBps + snapshot.diskWriteMBps)])
        networkHistory = trimmed(networkHistory + [TimePoint(timestamp: now, value: snapshot.networkInKBps + snapshot.networkOutKBps)])
        gpuHistory = trimmed(gpuHistory + [TimePoint(timestamp: now, value: snapshot.gpuPercent ?? 0)])

        for process in processes.prefix(20) {
            processHistory[process.pid] = trimmed((processHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.cpuUsage)])
            memoryProcessHistory[process.pid] = trimmed((memoryProcessHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.memoryMB)])
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
}
