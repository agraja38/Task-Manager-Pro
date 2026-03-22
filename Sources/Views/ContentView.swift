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
            Spacer(minLength: 0)
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
        case .network:
            NetworkView()
        case .thermals:
            ThermalsView()
        case .settings:
            SettingsView()
        }
    }

    private var topNavigation: some View {
        HStack(spacing: 10) {
            ForEach(visibleSections) { section in
                Button {
                    appState.selectedSection = section
                } label: {
                    Label(section.rawValue, systemImage: section.symbolName)
                        .font(.headline)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .frame(minWidth: 130)
                        .frame(maxWidth: .infinity)
                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(appState.selectedSection == section ? Color.accentColor.opacity(0.16) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(appState.selectedSection == section ? Color.accentColor.opacity(0.6) : Color.white.opacity(0.06), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var visibleSections: [TopSection] {
        if appState.showsAdvancedTelemetryWidgets {
            return TopSection.allCases
        }
        return TopSection.allCases.filter { $0 != .network && $0 != .thermals }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Text("Created by Agraja")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }
}

struct ProcessesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            header
            ProcessTable(processes: appState.filteredProcesses)
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
                HStack(spacing: 12) {
                    MetricBadge(title: "CPU", value: String(format: "%.0f%%", appState.currentMetrics.cpuPercent), color: .orange, prominence: .large)
                    MetricBadge(title: "Memory", value: String(format: "%.0f%%", appState.currentMetrics.memoryPercent), color: .blue, prominence: .large)
                    if appState.showsAdvancedTelemetryWidgets {
                        MetricBadge(title: "GPU", value: gpuSummary, color: .purple, prominence: .large)
                        MetricBadge(title: "Cache", value: cacheSummary, color: .mint, prominence: .large)
                    }
                    MetricBadge(title: "Network", value: networkSummary, color: .cyan, prominence: .large)
                }
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
                    ForEach(sortOptions) { key in
                        Text(key.rawValue).tag(key)
                    }
                }
                .frame(width: 140)

                if appState.showsAdvancedTelemetryWidgets {
                    Button(appState.isClearingMemory ? "Clearing Cache..." : "Clear Cache") {
                        appState.clearCache()
                    }
                    .disabled(appState.isClearingMemory)
                }
            }
        }
    }

    private var sortOptions: [ProcessSortKey] {
        appState.showsAdvancedTelemetryWidgets ? ProcessSortKey.allCases : ProcessSortKey.allCases.filter { $0 != .gpu }
    }

    private var networkSummary: String {
        let totalKB = appState.currentMetrics.networkInKBps + appState.currentMetrics.networkOutKBps
        if totalKB >= 1024 {
            return String(format: "%.1f MB/s", totalKB / 1024)
        }
        return String(format: "%.0f KB/s", totalKB)
    }

    private var gpuSummary: String {
        guard let gpuPercent = appState.currentMetrics.gpuPercent else {
            return "--"
        }
        return String(format: "%.0f%%", gpuPercent)
    }

    private var cacheSummary: String {
        String(format: "%.1f GB", appState.currentMetrics.cachedFilesGB)
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
            if appState.showsAdvancedTelemetryWidgets {
                MetricChip(title: "GPU", value: gpuValueText, tint: .purple)
            }
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
                .stroke(borderColor, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var backgroundFill: Color {
        if process.isHeavy {
            return Color.orange.opacity(0.10)
        }
        return Color.primary.opacity(0.035)
    }

    private var cpuValueText: String {
        if process.cpuUsage < 1 {
            return String(format: "%.2f%%", process.cpuUsage)
        }
        return String(format: "%.1f%%", process.cpuUsage)
    }

    private var gpuValueText: String {
        guard let gpuUsage = process.gpuUsage else {
            return "--"
        }
        if gpuUsage < 1 {
            return String(format: "%.2f%%", gpuUsage)
        }
        return String(format: "%.1f%%", gpuUsage)
    }

    private var borderColor: Color {
        return Color(nsColor: .separatorColor).opacity(0.55)
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
            let advancedCardHeight = max(170, (availableHeight - 36) / 3)
            let normalCPUHeight = max(230, min(availableHeight * 0.48, 290))
            let normalSecondaryHeight = max(118, min(136, (availableHeight - normalCPUHeight - 36) / 2))
            let normalNetworkHeight = max(108, normalSecondaryHeight - 14)
            Group {
                if appState.showsAdvancedTelemetryWidgets {
                    ScrollView {
                        content(
                            advancedCardHeight: advancedCardHeight,
                            normalCPUHeight: normalCPUHeight,
                            normalSecondaryHeight: normalSecondaryHeight,
                            normalNetworkHeight: normalNetworkHeight
                        )
                    }
                } else {
                    content(
                        advancedCardHeight: advancedCardHeight,
                        normalCPUHeight: normalCPUHeight,
                        normalSecondaryHeight: normalSecondaryHeight,
                        normalNetworkHeight: normalNetworkHeight
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func content(advancedCardHeight: CGFloat, normalCPUHeight: CGFloat, normalSecondaryHeight: CGFloat, normalNetworkHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Performance")
                .font(.system(size: 28, weight: .bold))

            if appState.showsAdvancedTelemetryWidgets {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                    CPUChartCard(height: advancedCardHeight, allowsCoreScrolling: true)
                    MetricChartCard(title: "Memory", subtitle: String(format: "%.1f / %.1f GB", appState.currentMetrics.usedMemoryGB, appState.currentMetrics.totalMemoryGB), history: appState.memoryHistory, color: .blue, yLabel: "%", height: advancedCardHeight)
                    CacheFilesCard(height: advancedCardHeight)
                    MetricChartCard(title: "Disk", subtitle: String(format: "R %.1f MB/s  W %.1f MB/s", appState.currentMetrics.diskReadMBps, appState.currentMetrics.diskWriteMBps), history: appState.diskHistory, color: .green, yLabel: "MB/s", height: advancedCardHeight)
                    MetricChartCard(title: "Network", subtitle: String(format: "In %.1f KB/s  Out %.1f KB/s", appState.currentMetrics.networkInKBps, appState.currentMetrics.networkOutKBps), history: appState.networkHistory, color: .cyan, yLabel: "KB/s", height: advancedCardHeight)
                    MetricChartCard(title: "GPU", subtitle: appState.currentMetrics.gpuPercent == nil ? "Unavailable without private APIs" : String(format: "%.1f%%", appState.currentMetrics.gpuPercent ?? 0), history: appState.gpuHistory, color: .purple, yLabel: "%", height: advancedCardHeight)
                }
            } else {
                Grid(horizontalSpacing: 18, verticalSpacing: 18) {
                    GridRow {
                        CPUChartCard(height: normalCPUHeight, allowsCoreScrolling: false)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        MetricChartCard(title: "Memory", subtitle: String(format: "%.1f / %.1f GB", appState.currentMetrics.usedMemoryGB, appState.currentMetrics.totalMemoryGB), history: appState.memoryHistory, color: .blue, yLabel: "%", height: normalSecondaryHeight)
                        MetricChartCard(title: "Disk", subtitle: String(format: "R %.1f MB/s  W %.1f MB/s", appState.currentMetrics.diskReadMBps, appState.currentMetrics.diskWriteMBps), history: appState.diskHistory, color: .green, yLabel: "MB/s", height: normalSecondaryHeight)
                    }
                    GridRow {
                        MetricChartCard(title: "Network", subtitle: String(format: "In %.1f KB/s  Out %.1f KB/s", appState.currentMetrics.networkInKBps, appState.currentMetrics.networkOutKBps), history: appState.networkHistory, color: .cyan, yLabel: "KB/s", height: normalNetworkHeight)
                            .gridCellColumns(2)
                    }
                }
            }
        }
        .padding(20)
    }
}

struct NetworkView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Network")
                    .font(.system(size: 28, weight: .bold))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    MetricBadge(title: "Download", value: rateString(appState.currentMetrics.networkInKBps), color: .cyan, prominence: .large)
                    MetricBadge(title: "Upload", value: rateString(appState.currentMetrics.networkOutKBps), color: .blue, prominence: .large)
                    MetricBadge(title: "Connections", value: "\(appState.currentNetworkDetails.connections.count)", color: .green, prominence: .large)
                    MetricBadge(title: "Interfaces", value: "\(appState.currentNetworkDetails.interfaces.count)", color: .orange, prominence: .large)
                }

                GroupBox("Throughput") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Live network throughput")
                            .font(.headline)
                        Chart {
                            ForEach(appState.networkInHistory) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Download", point.value)
                                )
                                .foregroundStyle(.cyan)
                            }

                            ForEach(appState.networkOutHistory) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Upload", point.value)
                                )
                                .foregroundStyle(.blue)
                            }
                        }
                        .frame(height: 190)

                        HStack(spacing: 18) {
                            networkLegend(color: .cyan, label: "Download")
                            networkLegend(color: .blue, label: "Upload")
                            Spacer()
                            Text(appState.currentNetworkDetails.capturedAt, style: .time)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Routing & DNS") {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: "Default Gateway", value: appState.currentNetworkDetails.defaultGateway)
                        DetailRow(label: "Primary Interface", value: appState.currentNetworkDetails.primaryInterface)
                        DetailRow(label: "Wi-Fi Network", value: appState.currentNetworkDetails.wifiNetwork ?? "Unavailable")
                        DetailRow(label: "DNS Servers", value: joined(appState.currentNetworkDetails.dnsServers))
                        DetailRow(label: "Search Domains", value: joined(appState.currentNetworkDetails.searchDomains))
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Interfaces") {
                    VStack(spacing: 10) {
                        ForEach(appState.currentNetworkDetails.interfaces) { interface in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(interface.name)
                                        .font(.headline)
                                    Text(interface.kind)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.05), in: Capsule())
                                    if interface.isPrimary {
                                        Text("Primary")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.cyan)
                                    }
                                    Spacer()
                                    Text(interface.status)
                                        .foregroundStyle(interface.status == "Active" ? .green : .secondary)
                                }

                                HStack(spacing: 16) {
                                    networkMiniStat(title: "MTU", value: "\(interface.mtu)")
                                    networkMiniStat(title: "Down", value: byteString(interface.bytesIn))
                                    networkMiniStat(title: "Up", value: byteString(interface.bytesOut))
                                    networkMiniStat(title: "In Packets", value: "\(interface.packetsIn)")
                                    networkMiniStat(title: "Out Packets", value: "\(interface.packetsOut)")
                                }

                                if let macAddress = interface.macAddress, !macAddress.isEmpty {
                                    DetailRow(label: "MAC", value: macAddress)
                                }
                                DetailRow(label: "Addresses", value: joined(interface.addresses))
                            }
                            .padding(12)
                            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Active Connections") {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Proto").frame(width: 55, alignment: .leading)
                            Text("State").frame(width: 95, alignment: .leading)
                            Text("Local").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Remote").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                        ForEach(appState.currentNetworkDetails.connections) { connection in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(connection.processName)
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                    Text("PID \(connection.pid) • \(connection.user)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                Text(connection.protocolName)
                                    .frame(width: 55, alignment: .leading)

                                Text(connection.state)
                                    .frame(width: 95, alignment: .leading)

                                Text(connection.localEndpoint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)

                                Text(connection.remoteEndpoint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .padding(.vertical, 6)

                            if connection.id != appState.currentNetworkDetails.connections.last?.id {
                                Divider()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
    }

    private func rateString(_ kbps: Double) -> String {
        if kbps >= 1024 {
            return String(format: "%.2f MB/s", kbps / 1024)
        }
        return String(format: "%.0f KB/s", kbps)
    }

    private func byteString(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "Unavailable" : values.joined(separator: ", ")
    }

    @ViewBuilder
    private func networkLegend(color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func networkMiniStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
        }
    }
}

struct ThermalsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var spinsFan = false

    private var combinedFanRPM: Int {
        appState.currentThermalDetails.fanSpeedsRPM.reduce(0) { $0 + $1.rpm }
    }

    private var fanIsRunning: Bool {
        combinedFanRPM > 0
    }

    private var topThermalColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)
    }

    private var sensorColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 250, maximum: 360), spacing: 12, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Thermals")
                    .font(.system(size: 28, weight: .bold))

                LazyVGrid(columns: topThermalColumns, spacing: 14) {
                    fanMetricCard
                    MetricBadge(title: "CPU Temp", value: temperatureString(appState.currentThermalDetails.cpuTemperatureC), color: .red, prominence: .large)
                    MetricBadge(title: "GPU Temp", value: temperatureString(appState.currentThermalDetails.gpuTemperatureC), color: .orange, prominence: .large)
                    MetricBadge(title: "Palm Rest", value: temperatureString(appState.currentThermalDetails.palmRestTemperatureC), color: .pink, prominence: .large)
                }

                GroupBox("Overview") {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailRow(label: "Thermal State", value: appState.currentThermalDetails.thermalLevel)
                        DetailRow(label: "Sensor Source", value: appState.currentThermalDetails.hottestSensors.isEmpty && appState.currentThermalDetails.fanSpeedsRPM.isEmpty ? "Unavailable" : "AppleSMC")
                        DetailRow(label: "Last Sample", value: appState.currentThermalDetails.capturedAt == .distantPast ? "Not sampled yet" : DateFormatter.localizedString(from: appState.currentThermalDetails.capturedAt, dateStyle: .none, timeStyle: .medium))
                    }
                    .padding(.vertical, 8)
                }

                GroupBox("Temperatures") {
                    VStack(spacing: 10) {
                        if appState.currentThermalDetails.hottestSensors.isEmpty {
                            Text("Task Manager Pro could not find readable AppleSMC temperature sensors on this Mac right now.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            LazyVGrid(columns: sensorColumns, spacing: 12) {
                                ForEach(appState.currentThermalDetails.hottestSensors) { sensor in
                                    HStack(spacing: 10) {
                                        Text(sensor.name)
                                            .font(.subheadline.weight(.semibold))
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Text(String(format: "%.1f C", sensor.valueC))
                                            .font(.subheadline.monospacedDigit().weight(.bold))
                                            .foregroundStyle(.red)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                                    )
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }

            }
            .padding(20)
        }
        .onAppear {
            updateFanAnimationState()
        }
        .onChange(of: combinedFanRPM) { _ in
            updateFanAnimationState()
        }
    }

    private func temperatureString(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f C", value)
    }

    @ViewBuilder
    private var fanMetricCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(fanIsRunning ? Color.cyan : Color.secondary)
                    .rotationEffect(.degrees(spinsFan ? 360 : 0))
                    .animation(
                        fanIsRunning
                        ? .linear(duration: fanAnimationDuration).repeatForever(autoreverses: false)
                        : .easeOut(duration: 0.25),
                        value: spinsFan
                    )
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan Speed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if appState.currentThermalDetails.fanSpeedsRPM.count <= 1 {
                        Text(fanSpeedValue)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(fanSpeedSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(appState.currentThermalDetails.fanSpeedsRPM.prefix(2)) { fan in
                                HStack(spacing: 6) {
                                    Text(fan.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer(minLength: 6)
                                    Text("\(fan.rpm) rpm")
                                        .font(.subheadline.monospacedDigit().weight(.bold))
                                }
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var fanSpeedValue: String {
        if appState.currentThermalDetails.fanSpeedsRPM.isEmpty {
            return "--"
        }
        return "\(combinedFanRPM) rpm"
    }

    private var fanSpeedSubtitle: String {
        let fanCount = appState.currentThermalDetails.fanSpeedsRPM.count
        guard fanCount > 0 else { return "No fan telemetry" }
        return fanCount == 1 ? "1 fan active" : "\(fanCount) fans active"
    }

    private var fanAnimationDuration: Double {
        let normalizedRPM = max(600, min(combinedFanRPM / max(1, appState.currentThermalDetails.fanSpeedsRPM.count), 5000))
        let progress = Double(normalizedRPM - 600) / 4400.0
        return 1.1 - (0.7 * progress)
    }

    private func updateFanAnimationState() {
        if fanIsRunning {
            spinsFan = true
        } else {
            spinsFan = false
        }
    }
}

struct CPUChartCard: View {
    @EnvironmentObject private var appState: AppState
    let height: CGFloat
    let allowsCoreScrolling: Bool

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
        return appState.perCoreCPUHistory.enumerated().map { index, history in
            CoreSeries(
                id: index,
                label: "Core \(index + 1)",
                history: history,
                color: .red
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
        case 9 ... 12:
            columnCount = 4
        case 13 ... 16:
            columnCount = 5
        default:
            columnCount = 6
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
                    Group {
                        if allowsCoreScrolling {
                            ScrollView(.vertical, showsIndicators: true) {
                                coreGrid
                            }
                        } else {
                            coreGrid
                        }
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

    private var coreGrid: some View {
        LazyVGrid(columns: perCoreColumns, spacing: 8) {
            ForEach(coreSeries) { series in
                CoreMiniChartCard(series: series, compact: !allowsCoreScrolling)
            }
        }
        .padding(.trailing, allowsCoreScrolling ? 4 : 0)
    }
}

struct CoreMiniChartCard: View {
    let series: CPUChartCard.CoreSeries
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack {
                Text(series.label)
                    .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(currentValue)
                    .font((compact ? Font.caption2 : Font.caption2).monospacedDigit())
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
            .frame(height: compact ? 28 : 40)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 6)
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

                GroupBox("Mode") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $appState.appMode) {
                            ForEach(AppMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Pick the experience that matches how deep you want Task Manager Pro to go.")
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Basic: CPU, memory, disk, and network monitoring for everyday use.")
                            Text("Advance: GPU and cache insights, the Network tab, the Thermals tab, and power-user controls like fan presets.")
                        }
                        .foregroundStyle(.secondary)
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

                GroupBox("Memory Cleanup") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ask macOS to clear reclaimable cache and refresh the RAM and cached-files readings. This helps free cache where macOS allows it, but it does not force-close apps or instantly empty every memory bucket.")
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button(appState.isClearingMemory ? "Clearing Cache..." : "Clear Cache") {
                                appState.clearCache()
                            }
                            .disabled(appState.isClearingMemory)

                            Text("May require administrator approval.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(20)
        }
    }
}

struct CacheFilesCard: View {
    @EnvironmentObject private var appState: AppState
    let height: CGFloat

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Cached Files").font(.headline)
                    Spacer()
                    Button(appState.isClearingMemory ? "Clearing..." : "Clear Cache") {
                        appState.clearCache()
                    }
                    .disabled(appState.isClearingMemory)
                    .buttonStyle(.borderless)
                }

                Text(String(format: "%.1f GB reclaimable cache", appState.currentMetrics.cachedFilesGB))
                    .foregroundStyle(.secondary)

                Chart(appState.cacheHistory) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        y: .value("GB", point.value)
                    )
                    .foregroundStyle(Color.mint.opacity(0.12))

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("GB", point.value)
                    )
                    .foregroundStyle(Color.mint)
                    .lineStyle(.init(lineWidth: 2))
                }
                .frame(height: max(110, height - 76))
            }
            .padding(.vertical, 8)
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

struct MetricBadge: View {
    enum Prominence {
        case standard
        case large
    }

    let title: String
    let value: String
    let color: Color
    var prominence: Prominence = .standard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font((prominence == .large ? Font.caption : Font.caption).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font((prominence == .large ? Font.title3 : Font.headline).monospacedDigit().weight(.bold))
                .foregroundStyle(color)
        }
        .frame(minWidth: prominence == .large ? 108 : nil, alignment: .leading)
        .padding(.horizontal, prominence == .large ? 14 : 12)
        .padding(.vertical, prominence == .large ? 10 : 8)
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
