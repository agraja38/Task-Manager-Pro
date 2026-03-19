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
    @Published var processes: [ProcessSnapshot] = []
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
    @Published var networkInHistory: [TimePoint] = []
    @Published var networkOutHistory: [TimePoint] = []
    @Published var gpuHistory: [TimePoint] = []
    @Published var processHistory: [Int32: [TimePoint]] = [:]
    @Published var memoryProcessHistory: [Int32: [TimePoint]] = [:]
    @Published var currentNetworkDetails = NetworkDetailsSnapshot.empty

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
    @Published var showsAdvancedTelemetryWidgets: Bool = UserDefaults.standard.object(forKey: "showsAdvancedTelemetryWidgets") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showsAdvancedTelemetryWidgets, forKey: "showsAdvancedTelemetryWidgets")
            if !showsAdvancedTelemetryWidgets && sortKey == .gpu {
                sortKey = .cpu
            }
            if !showsAdvancedTelemetryWidgets && selectedSection == .network {
                selectedSection = .performance
            }
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
        case .gpu: return base.sorted { ($0.gpuUsage ?? 0) > ($1.gpuUsage ?? 0) }
        case .memory: return base.sorted { $0.memoryMB > $1.memoryMB }
        case .name: return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func refreshAll() {
        let appMetadataByPID = runningAppMetadataByPID()
        let processService = self.processService
        let metricsService = self.metricsService
        let shouldCaptureNetworkDetails = self.showsAdvancedTelemetryWidgets && self.selectedSection == .network

        Task.detached(priority: .userInitiated) {
            let rawProcesses = processService.fetchProcesses(appMetadataByPID: appMetadataByPID)
            let metrics = metricsService.sample(includeAdvancedTelemetry: true)
            let networkDetails = shouldCaptureNetworkDetails ? metricsService.detailedNetworkSnapshot() : nil

            await MainActor.run {
                let processes = self.applyGPUUsageEstimates(to: rawProcesses, overallGPUPercent: metrics.gpuPercent)
                self.processes = processes
                self.currentMetrics = metrics
                if let networkDetails {
                    self.currentNetworkDetails = networkDetails
                }
                self.appendHistory(snapshot: metrics, processes: processes)
                if processes.isEmpty {
                    self.latestError = "Task Manager Pro could not load the process list. Try refreshing again."
                } else if self.latestError.contains("could not load") {
                    self.latestError = ""
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

    func handleSystemWake() {
        metricsService.resetSamplingBaselines()
        timer?.invalidate()
        startTimers()
        refreshAll()
    }

    func handleSystemSleep() {
        timer?.invalidate()
        metricsService.resetSamplingBaselines()
    }

    private func startTimers() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    private func runningAppMetadataByPID() -> [Int32: RunningAppMetadata] {
        var metadataByPID: [Int32: RunningAppMetadata] = [:]

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }

            let candidate = RunningAppMetadata(
                pid: pid,
                localizedName: app.localizedName ?? "",
                bundleIdentifier: app.bundleIdentifier ?? "",
                executablePath: app.executableURL?.path ?? "",
                isActive: app.isActive,
                isFinishedLaunching: app.isFinishedLaunching,
                isRegularApp: app.activationPolicy == .regular,
                architecture: app.executableArchitecture == CPU_TYPE_X86_64 ? "Intel" : "Apple Silicon / Native"
            )

            if let existing = metadataByPID[pid] {
                metadataByPID[pid] = preferredMetadata(existing, candidate)
            } else {
                metadataByPID[pid] = candidate
            }
        }

        return metadataByPID
    }

    private func preferredMetadata(_ lhs: RunningAppMetadata, _ rhs: RunningAppMetadata) -> RunningAppMetadata {
        let lhsScore = metadataQualityScore(lhs)
        let rhsScore = metadataQualityScore(rhs)

        if rhsScore > lhsScore {
            return rhs
        }

        if lhsScore > rhsScore {
            return lhs
        }

        if rhs.isActive && !lhs.isActive {
            return rhs
        }

        if rhs.isRegularApp && !lhs.isRegularApp {
            return rhs
        }

        return lhs
    }

    private func metadataQualityScore(_ metadata: RunningAppMetadata) -> Int {
        var score = 0
        if !metadata.localizedName.isEmpty { score += 4 }
        if !metadata.bundleIdentifier.isEmpty { score += 3 }
        if !metadata.executablePath.isEmpty { score += 2 }
        if metadata.isFinishedLaunching { score += 1 }
        if metadata.isRegularApp { score += 1 }
        return score
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
        networkInHistory = trimmed(networkInHistory + [TimePoint(timestamp: now, value: snapshot.networkInKBps)])
        networkOutHistory = trimmed(networkOutHistory + [TimePoint(timestamp: now, value: snapshot.networkOutKBps)])
        gpuHistory = trimmed(gpuHistory + [TimePoint(timestamp: now, value: snapshot.gpuPercent ?? 0)])

        for process in processes.prefix(20) {
            processHistory[process.pid] = trimmed((processHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.cpuUsage)])
            memoryProcessHistory[process.pid] = trimmed((memoryProcessHistory[process.pid] ?? []) + [TimePoint(timestamp: now, value: process.memoryMB)])
        }
    }

    private func applyGPUUsageEstimates(to processes: [ProcessSnapshot], overallGPUPercent: Double?) -> [ProcessSnapshot] {
        guard let overallGPUPercent, overallGPUPercent > 0 else {
            return processes.map { process in
                ProcessSnapshot(
                    id: process.id,
                    pid: process.pid,
                    ppid: process.ppid,
                    name: process.name,
                    executablePath: process.executablePath,
                    bundleIdentifier: process.bundleIdentifier,
                    user: process.user,
                    stateCode: process.stateCode,
                    status: process.status,
                    cpuUsage: process.cpuUsage,
                    gpuUsage: nil,
                    memoryMB: process.memoryMB,
                    energyImpact: process.energyImpact,
                    launchDate: process.launchDate,
                    elapsedTime: process.elapsedTime,
                    isApp: process.isApp,
                    isFrontmost: process.isFrontmost,
                    isCritical: process.isCritical,
                    childPIDs: process.childPIDs,
                    metadata: process.metadata
                )
            }
        }

        let candidates = processes.filter { $0.isApp }
        let totalWeight = candidates.reduce(0.0) { partial, process in
            partial + gpuWeight(for: process)
        }

        guard totalWeight > 0 else {
            return processes
        }

        let estimatedGPUByPID = Dictionary(uniqueKeysWithValues: candidates.map { process in
            (process.pid, overallGPUPercent * gpuWeight(for: process) / totalWeight)
        })

        return processes.map { process in
            ProcessSnapshot(
                id: process.id,
                pid: process.pid,
                ppid: process.ppid,
                name: process.name,
                executablePath: process.executablePath,
                bundleIdentifier: process.bundleIdentifier,
                user: process.user,
                stateCode: process.stateCode,
                status: process.status,
                cpuUsage: process.cpuUsage,
                gpuUsage: estimatedGPUByPID[process.pid],
                memoryMB: process.memoryMB,
                energyImpact: process.energyImpact,
                launchDate: process.launchDate,
                elapsedTime: process.elapsedTime,
                isApp: process.isApp,
                isFrontmost: process.isFrontmost,
                isCritical: process.isCritical,
                childPIDs: process.childPIDs,
                metadata: process.metadata
            )
        }
    }

    private func gpuWeight(for process: ProcessSnapshot) -> Double {
        let cpuWeight = max(process.cpuUsage, process.isFrontmost ? 4 : 0.15)
        let memoryWeight = min(process.memoryMB / 1024, 2.5) * 0.35
        return cpuWeight + memoryWeight
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

}
