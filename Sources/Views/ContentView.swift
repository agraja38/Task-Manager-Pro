import Charts
import Darwin
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            topNavigation
            Divider()
            detailView
            Divider()
            bottomBar
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch appState.selectedSection {
        case .processes:
            ProcessesView()
        case .performance:
            PerformanceView()
        case .settings:
            SettingsView()
        }
    }

    private var topNavigation: some View {
        HStack(spacing: 10) {
            ForEach(TopSection.allCases) { section in
                Button {
                    appState.selectedSection = section
                } label: {
                    Label(section.rawValue, systemImage: section.symbolName)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(appState.selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(appState.selectedSection == section ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                )
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Text("Created by Agraja")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

struct ProcessesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            header
            ProcessTable(processes: appState.filteredProcesses)
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
            }
        }
    }

    private var footer: some View {
        HStack {
            if !appState.latestError.isEmpty {
                Text(appState.latestError)
                    .foregroundStyle(appState.latestError.contains("blocked") ? .red : .secondary)
            }
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
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(processes, id: \.pid) { process in
                    ProcessRow(process: process)
                        .contextMenu {
                            Button("Quit") { appState.execute(.quit, for: process) }
                            Button("Terminate") { appState.execute(.terminate, for: process) }
                            Button("Force Quit") { appState.execute(.forceQuit, for: process) }
                        }
                }
            }
        }
    }
}

struct ProcessRow: View {
    @EnvironmentObject private var appState: AppState
    let process: ProcessSnapshot

    var body: some View {
        HStack(spacing: 16) {
            ProcessAppIconView(process: process)

            Text(process.name)
                .font(.headline)
                .lineLimit(1)

            Spacer(minLength: 16)

            MetricChip(title: "CPU", value: cpuValueText, tint: .orange)
            MetricChip(title: "Memory", value: String(format: "%.0f MB", process.memoryMB), tint: .blue)

            Menu {
                Button("Quit") { appState.execute(.quit, for: process) }
                Button("Terminate") { appState.execute(.terminate, for: process) }
                Button("Force Quit") { appState.execute(.forceQuit, for: process) }
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
                    .labelStyle(.titleAndIcon)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(backgroundFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appState.selectedPID == process.pid ? Color.accentColor.opacity(0.65) : Color.white.opacity(0.03), lineWidth: appState.selectedPID == process.pid ? 1.2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            appState.selectedPID = process.pid
        }
    }

    private var backgroundFill: Color {
        if appState.selectedPID == process.pid {
            return Color.accentColor.opacity(0.12)
        }
        if process.isHeavy {
            return Color.orange.opacity(0.10)
        }
        return Color.white.opacity(0.04)
    }

    private var cpuValueText: String {
        if process.cpuUsage < 1 {
            return String(format: "%.2f%%", process.cpuUsage)
        }
        return String(format: "%.1f%%", process.cpuUsage)
    }
}

struct MetricChip: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: 104, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ProcessAppIconView: View {
    let process: ProcessSnapshot

    private static var cache: [String: NSImage] = [:]

    var body: some View {
        Image(nsImage: icon)
            .resizable()
            .interpolation(.high)
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var icon: NSImage {
        let key = iconLookupPath
        if let cached = Self.cache[key] {
            return cached
        }

        let image = NSWorkspace.shared.icon(forFile: key)
        image.size = NSSize(width: 28, height: 28)
        Self.cache[key] = image
        return image
    }

    private var iconLookupPath: String {
        if let appRange = process.executablePath.range(of: ".app/") {
            return String(process.executablePath[..<appRange.lowerBound]) + ".app"
        }
        return process.executablePath.isEmpty ? "/Applications" : process.executablePath
    }
}

struct PerformanceView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { proxy in
            let availableHeight = max(proxy.size.height - 110, 560)
            let cardHeight = max(170, (availableHeight - 36) / 3)
            VStack(alignment: .leading, spacing: 18) {
                Text("Performance")
                    .font(.system(size: 28, weight: .bold))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    CPUChartCard(height: cardHeight)
                    MetricChartCard(title: "Memory", subtitle: String(format: "%.1f / %.1f GB", appState.currentMetrics.usedMemoryGB, appState.currentMetrics.totalMemoryGB), history: appState.memoryHistory, color: .blue, yLabel: "%", height: cardHeight)
                    MetricChartCard(title: "Disk", subtitle: String(format: "R %.1f MB/s  W %.1f MB/s", appState.currentMetrics.diskReadMBps, appState.currentMetrics.diskWriteMBps), history: appState.diskHistory, color: .green, yLabel: "MB/s", height: cardHeight)
                    MetricChartCard(title: "Network", subtitle: String(format: "In %.1f KB/s  Out %.1f KB/s", appState.currentMetrics.networkInKBps, appState.currentMetrics.networkOutKBps), history: appState.networkHistory, color: .cyan, yLabel: "KB/s", height: cardHeight)
                    MetricChartCard(title: "GPU", subtitle: appState.currentMetrics.gpuPercent == nil ? "Unavailable without private APIs" : String(format: "%.1f%%", appState.currentMetrics.gpuPercent ?? 0), history: appState.gpuHistory, color: .purple, yLabel: "%", height: cardHeight)
                    BatteryCard(height: cardHeight)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct CPUChartCard: View {
    @EnvironmentObject private var appState: AppState
    let height: CGFloat

    struct CoreSeries: Identifiable {
        let id: Int
        let label: String
        let history: [TimePoint]
        let color: Color
    }

    private var isPerCoreMode: Bool {
        appState.cpuGraphMode == .cores && !appState.perCoreCPUHistory.isEmpty
    }

    private var subtitle: String {
        if isPerCoreMode {
            return "\(appState.perCoreCPUHistory.count) cores • \(String(format: "%.1f%% overall", appState.currentMetrics.cpuPercent))"
        }
        return String(format: "%.1f%% active", appState.currentMetrics.cpuPercent)
    }

    private var coreSeries: [CoreSeries] {
        let palette: [Color] = [
            .orange, .red, .yellow, .pink, .mint, .cyan, .blue, .purple,
            .teal, .indigo, .green, .brown
        ]

        return appState.perCoreCPUHistory.enumerated().map { index, history in
            CoreSeries(
                id: index,
                label: "Core \(index + 1)",
                history: history,
                color: palette[index % palette.count]
            )
        }
    }

    private var perCoreColumns: [GridItem] {
        let count = coreSeries.count
        let columnCount: Int
        switch count {
        case 0 ... 4:
            columnCount = 2
        case 5 ... 8:
            columnCount = 3
        default:
            columnCount = 4
        }

        return Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CPU").font(.headline)
                    Spacer()
                    Text(appState.cpuGraphMode.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(subtitle)
                    .foregroundStyle(.secondary)

                if isPerCoreMode {
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: perCoreColumns, spacing: 8) {
                            ForEach(coreSeries) { series in
                                CoreMiniChartCard(series: series)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(height: max(110, height - 76), alignment: .top)
                } else {
                    Chart(appState.cpuHistory) { point in
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value("%", point.value)
                        )
                        .foregroundStyle(Color.orange.opacity(0.12))

                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("%", point.value)
                        )
                        .foregroundStyle(Color.orange)
                        .lineStyle(.init(lineWidth: 2))
                    }
                    .chartYScale(domain: 0 ... 100)
                    .frame(height: max(110, height - 76))
                }
            }
            .padding(.vertical, 8)
        }
        .contextMenu {
            Button {
                appState.cpuGraphMode = .overall
            } label: {
                Label("Show Overall Graph", systemImage: appState.cpuGraphMode == .overall ? "checkmark" : "waveform")
            }

            Button {
                appState.cpuGraphMode = .cores
            } label: {
                Label("Show CPU Cores Graph", systemImage: appState.cpuGraphMode == .cores ? "checkmark" : "square.grid.2x2")
            }
            .disabled(appState.perCoreCPUHistory.isEmpty)
        }
    }
}

struct CoreMiniChartCard: View {
    let series: CPUChartCard.CoreSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(series.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(currentValue)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(series.color)
            }

            Chart(series.history) { point in
                AreaMark(
                    x: .value("Time", point.timestamp),
                    y: .value("%", point.value)
                )
                .foregroundStyle(series.color.opacity(0.10))

                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("%", point.value)
                )
                .foregroundStyle(series.color)
                .lineStyle(.init(lineWidth: 1.3))
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 0 ... 100)
            .frame(height: 40)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(series.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var currentValue: String {
        String(format: "%.0f%%", series.history.last?.value ?? 0)
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
                        Text("Task Manager Pro keeps the interface focused on a fast app list and a live performance dashboard.")
                            .foregroundStyle(.secondary)

                        Toggle("Show app icon in Dock", isOn: $appState.showsDockIcon)

                        Picker("Menu Bar Monitor", selection: $appState.menuBarDisplayMode) {
                            ForEach(MenuBarDisplayMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Picker("Appearance", selection: $appState.appearanceMode) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
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
                        Text("Current version \(appState.updater.currentVersion)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            Button("Check for Updates Now") { appState.startUpdateFlow() }
                            if appState.updater.phase == .ready {
                                Button("Install Now") { appState.installAvailableUpdate() }
                            }
                            Text(appState.updater.updateSummaryText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
    }
}

struct MetricChartCard: View {
    let title: String
    let subtitle: String
    let history: [TimePoint]
    let color: Color
    let yLabel: String
    let height: CGFloat

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
                .frame(height: max(110, height - 76))
            }
            .padding(.vertical, 8)
        }
    }
}

struct BatteryCard: View {
    @EnvironmentObject private var appState: AppState
    let height: CGFloat

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
        .frame(maxHeight: height)
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
