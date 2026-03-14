import Charts
import Darwin
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $appState.sidebarSelection) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Mode", selection: $appState.displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Button("Refresh") { appState.refreshAll() }
                Button("Export CSV") { appState.exportSnapshot(asJSON: false) }
                Button("Export JSON") { appState.exportSnapshot(asJSON: true) }
                Button("Check Updates") { appState.startUpdateFlow() }
            }
        }
        .sheet(isPresented: $appState.updateSheetPresented) {
            UpdateSheetView()
                .environmentObject(appState)
                .frame(width: 460, height: 260)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.sidebarSelection ?? .processes {
        case .processes:
            ProcessesView()
        case .performance:
            PerformanceView()
        case .startupApps:
            StartupAppsView()
        case .details:
            DetailsView()
        case .settings:
            SettingsView()
        }
    }
}

struct ProcessesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            header
            if appState.treeViewEnabled {
                ProcessTreeList(processes: appState.filteredProcesses)
            } else {
                ProcessTable(processes: appState.filteredProcesses)
            }
            footer
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Processes")
                        .font(.system(size: 28, weight: .bold))
                    Text("A native macOS process manager with safe app controls and live resource visibility.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                MetricBadge(title: "CPU", value: String(format: "%.0f%%", appState.currentMetrics.cpuPercent), color: .orange)
                MetricBadge(title: "Memory", value: String(format: "%.0f%%", appState.currentMetrics.memoryPercent), color: .blue)
                MetricBadge(title: "Thermal", value: appState.currentMetrics.thermalLevel, color: .pink)
            }

            HStack {
                TextField("Search by name, bundle ID, or path", text: $appState.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Filter", selection: $appState.processFilter) {
                    ForEach(ProcessFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .frame(width: 150)

                Picker("Sort", selection: $appState.sortKey) {
                    ForEach(ProcessSortKey.allCases) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                .frame(width: 140)

                Toggle("Tree", isOn: $appState.treeViewEnabled)
                    .toggleStyle(.switch)
                    .frame(width: 80)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(appState.latestError.isEmpty ? "Ready." : appState.latestError)
                .foregroundStyle(appState.latestError.contains("blocked") ? .red : .secondary)
            Spacer()
            Text("\(appState.filteredProcesses.count) visible processes")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}

struct ProcessTable: View {
    @EnvironmentObject private var appState: AppState
    let processes: [ProcessSnapshot]

    var body: some View {
        List(selection: $appState.selectedPID) {
            ForEach(processes, id: \.pid) { process in
                ProcessRow(process: process)
                    .tag(process.pid)
                    .listRowBackground(process.isHeavy ? Color.orange.opacity(0.13) : Color.clear)
                    .contextMenu {
                        Button("Quit") { appState.execute(.quit, for: process) }
                        Button("Terminate") { appState.execute(.terminate, for: process) }
                        Button("Force Quit") { appState.execute(.forceQuit, for: process) }
                    }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct ProcessTreeList: View {
    @EnvironmentObject private var appState: AppState
    let processes: [ProcessSnapshot]

    private var rootProcesses: [ProcessSnapshot] {
        let ids = Set(processes.map(\.pid))
        return processes.filter { !ids.contains($0.ppid) }.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    var body: some View {
        List(selection: $appState.selectedPID) {
            ForEach(rootProcesses, id: \.pid) { root in
                ProcessBranch(process: root, allProcesses: processes)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct ProcessBranch: View {
    @EnvironmentObject private var appState: AppState
    let process: ProcessSnapshot
    let allProcesses: [ProcessSnapshot]

    private var children: [ProcessSnapshot] {
        allProcesses.filter { $0.ppid == process.pid }.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    var body: some View {
        DisclosureGroup {
            ForEach(children, id: \.pid) { child in
                ProcessBranch(process: child, allProcesses: allProcesses)
            }
        } label: {
            ProcessRow(process: process)
                .tag(process.pid)
                .contentShape(Rectangle())
                .onTapGesture { appState.selectedPID = process.pid }
        }
    }
}

struct ProcessRow: View {
    @EnvironmentObject private var appState: AppState
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: process.isApp ? "app.fill" : "terminal")
                .foregroundStyle(process.isHeavy ? .orange : .accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.headline)
                Text(process.bundleIdentifier.isEmpty ? process.executablePath : process.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 3) {
                GridRow {
                    Text("PID")
                    Text("\(process.pid)")
                }
                GridRow {
                    Text("CPU")
                    Text(String(format: "%.1f%%", process.cpuUsage))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            if appState.displayMode == .advanced {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow {
                        Text("Memory")
                        Text(String(format: "%.0f MB", process.memoryMB))
                    }
                    GridRow {
                        Text("Energy")
                        Text(String(format: "%.0f", process.energyImpact))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(process.status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(process.status == "Zombie" ? .red : .secondary)
                .frame(width: 110, alignment: .leading)

            Menu {
                Button("Quit") { appState.execute(.quit, for: process) }
                Button("Terminate") { appState.execute(.terminate, for: process) }
                Button("Force Quit") { appState.execute(.forceQuit, for: process) }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

struct PerformanceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Performance")
                    .font(.system(size: 28, weight: .bold))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    MetricChartCard(title: "CPU", subtitle: String(format: "%.1f%% active", appState.currentMetrics.cpuPercent), history: appState.cpuHistory, color: .orange, yLabel: "%")
                    MetricChartCard(title: "Memory", subtitle: String(format: "%.1f / %.1f GB", appState.currentMetrics.usedMemoryGB, appState.currentMetrics.totalMemoryGB), history: appState.memoryHistory, color: .blue, yLabel: "%")
                    MetricChartCard(title: "Disk", subtitle: String(format: "R %.1f MB/s  W %.1f MB/s", appState.currentMetrics.diskReadMBps, appState.currentMetrics.diskWriteMBps), history: appState.diskHistory, color: .green, yLabel: "MB/s")
                    MetricChartCard(title: "Network", subtitle: String(format: "In %.1f KB/s  Out %.1f KB/s", appState.currentMetrics.networkInKBps, appState.currentMetrics.networkOutKBps), history: appState.networkHistory, color: .cyan, yLabel: "KB/s")
                    MetricChartCard(title: "GPU", subtitle: appState.currentMetrics.gpuPercent == nil ? "Unavailable without private APIs" : String(format: "%.1f%%", appState.currentMetrics.gpuPercent ?? 0), history: appState.gpuHistory, color: .purple, yLabel: "%")
                    BatteryCard()
                }

                if !appState.alerts.isEmpty {
                    GroupBox("Alerts") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(appState.alerts) { alert in
                                HStack(alignment: .top) {
                                    Text(alert.level.uppercased())
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(alert.level == "Critical" ? .red : .orange)
                                        .frame(width: 70, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(alert.title).font(.headline)
                                        Text(alert.message).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(alert.timestamp, style: .time)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .padding(20)
        }
    }
}

struct StartupAppsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Startup Apps")
                .font(.system(size: 28, weight: .bold))
            Text("Login items are shown with a best-effort startup impact estimate. Some background tasks need Automation permission or private APIs to inspect fully.")
                .foregroundStyle(.secondary)

            List(appState.startupItems) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(item.name).font(.headline)
                        Spacer()
                        Text(item.impact)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(item.impact == "High" ? .orange : .secondary)
                    }
                    Text(item.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Text(item.source)
                        if item.isHidden { Text("Hidden at login") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(20)
    }
}

struct DetailsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            if let process = appState.selectedProcess {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(process.name)
                                .font(.system(size: 28, weight: .bold))
                            Text("PID \(process.pid) • \(process.user)")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Quit") { appState.execute(.quit, for: process) }
                        Button("Terminate") { appState.execute(.terminate, for: process) }
                        Button("Force Quit") { appState.execute(.forceQuit, for: process) }
                    }

                    GroupBox("Metadata") {
                        VStack(alignment: .leading, spacing: 10) {
                            DetailRow(label: "Executable Path", value: process.executablePath)
                            DetailRow(label: "Bundle ID", value: process.bundleIdentifier.isEmpty ? "Not available" : process.bundleIdentifier)
                            DetailRow(label: "Launch Time", value: process.launchDate?.formatted(date: .abbreviated, time: .standard) ?? "Unknown")
                            DetailRow(label: "Elapsed", value: process.elapsedTime)
                            DetailRow(label: "Status", value: process.status)
                            DetailRow(label: "Energy Impact", value: String(format: "%.1f", process.energyImpact))
                        }
                        .padding(.vertical, 8)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        MetricChartCard(title: "Historical CPU", subtitle: "Recent process activity", history: appState.processHistory[process.pid] ?? [], color: .orange, yLabel: "%")
                        MetricChartCard(title: "Historical Memory", subtitle: "Resident memory over time", history: appState.memoryProcessHistory[process.pid] ?? [], color: .blue, yLabel: "MB")
                    }

                    GroupBox("Child Processes") {
                        if appState.childProcesses.isEmpty {
                            Text("No child processes detected.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(appState.childProcesses, id: \.pid) { child in
                                HStack {
                                    Text(child.name)
                                    Spacer()
                                    Text("PID \(child.pid)")
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No process selected")
                        .font(.title2.weight(.semibold))
                    Text("Select a process from the Processes tab to inspect details.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold))

                GroupBox("Experience") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Default mode", selection: $appState.displayMode) {
                            ForEach(DisplayMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        Toggle("Enable process tree by default", isOn: $appState.treeViewEnabled)
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Alerts") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("CPU threshold")
                            Slider(value: $appState.cpuAlertThreshold, in: 50 ... 100, step: 1)
                            Text("\(Int(appState.cpuAlertThreshold))%")
                                .frame(width: 44)
                        }
                        HStack {
                            Text("Memory threshold")
                            Slider(value: $appState.memoryAlertThreshold, in: 50 ... 100, step: 1)
                            Text("\(Int(appState.memoryAlertThreshold))%")
                                .frame(width: 44)
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Updater") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Task Manager Pro includes a built-in updater that checks a GitHub-hosted JSON feed, downloads the latest build, and shows progress while downloading and opening the installer.")
                            .foregroundStyle(.secondary)
                        Button("Check for Updates Now") { appState.startUpdateFlow() }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("macOS Access Notes") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Some metrics are intentionally restricted by macOS. GPU usage, package energy impact, temperatures, and certain startup/background items may need private APIs, root tools, or user-granted permissions.")
                        Text("Task Manager Pro stays on the safe side: it uses public APIs first, warns before destructive actions, and falls back to best-effort alternatives when direct telemetry is unavailable.")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
    }
}

struct UpdateSheetView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Software Update")
                .font(.system(size: 24, weight: .bold))
            Text(appState.updater.statusText)
                .foregroundStyle(.secondary)
            ProgressView(value: appState.updater.progress)
                .progressViewStyle(.linear)
            Text("Latest version: \(appState.updater.latestVersion)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !appState.updater.releaseNotes.isEmpty {
                GroupBox("Release Notes") {
                    Text(appState.updater.releaseNotes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button("Close") { appState.updateSheetPresented = false }
            }
        }
        .padding(20)
    }
}

struct MetricChartCard: View {
    let title: String
    let subtitle: String
    let history: [TimePoint]
    let color: Color
    let yLabel: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                Text(subtitle).foregroundStyle(.secondary)
                Chart(history) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(color.opacity(0.12))

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value(yLabel, point.value)
                    )
                    .foregroundStyle(color)
                    .lineStyle(.init(lineWidth: 2))
                }
                .frame(height: 170)
            }
            .padding(.vertical, 8)
        }
    }
}

struct BatteryCard: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Battery & System").font(.headline)
                Text(appState.currentMetrics.note)
                    .foregroundStyle(.secondary)
                Divider()
                DetailRow(label: "Battery", value: appState.currentMetrics.batteryPercent.map { String(format: "%.0f%%", $0) } ?? "Unavailable")
                DetailRow(label: "Charging", value: appState.currentMetrics.isCharging == nil ? "Unknown" : (appState.currentMetrics.isCharging == true ? "Yes" : "No"))
                DetailRow(label: "Thermal State", value: appState.currentMetrics.thermalLevel)
                DetailRow(label: "Architecture", value: isRunningTranslated() ? "Running under Rosetta" : "Native \(machineArchitecture())")
            }
            .padding(.vertical, 8)
        }
    }

    private func machineArchitecture() -> String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    private func isRunningTranslated() -> Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0)
        return result == 0 && translated == 1
    }
}

struct MetricBadge: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}
