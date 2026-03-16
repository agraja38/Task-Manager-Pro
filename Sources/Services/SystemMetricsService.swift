import Darwin
import Foundation
import IOKit.ps

final class SystemMetricsService {
    private struct CPUSnapshot {
        let overallPercent: Double
        let perCorePercent: [Double]
    }

    private var previousCPUInfo: processor_info_array_t?
    private var previousCPUInfoCount: mach_msg_type_number_t = 0
    private var previousNetworkTotals: (input: UInt64, output: UInt64)?
    private var previousDiskTotals: (read: Double, write: Double)?
    private var previousDiskTimestamp: Date?

    func sample(includeAdvancedTelemetry: Bool) -> PerformanceSnapshot {
        let cpu = currentCPUPercent()
        let memory = currentMemory()
        let network = currentNetwork()
        let disk = currentDisk()
        let battery = currentBattery()
        let thermal = currentThermalLevel()
        let gpuPercent = includeAdvancedTelemetry ? currentGPUPercent() : nil

        return PerformanceSnapshot(
            cpuPercent: cpu.overallPercent,
            perCoreCPUPercent: cpu.perCorePercent,
            memoryPercent: memory.percent,
            usedMemoryGB: memory.usedGB,
            totalMemoryGB: memory.totalGB,
            diskReadMBps: disk.read,
            diskWriteMBps: disk.write,
            networkInKBps: network.input,
            networkOutKBps: network.output,
            gpuPercent: gpuPercent,
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            thermalLevel: thermal,
            note: "GPU and temperature telemetry are limited on macOS without private APIs or elevated tools, so Task Manager Pro shows safe alternatives when direct readings are unavailable."
        )
    }

    func detailedNetworkSnapshot() -> NetworkDetailsSnapshot {
        let route = currentRouteInfo()
        let counters = currentInterfaceCounters()
        let dnsInfo = currentDNSInfo()
        let rawInterfaces = currentInterfaceDetails()
        let interfaces = rawInterfaces.map { interface -> NetworkInterfaceSnapshot in
            let counter = counters[interface.name]
            return NetworkInterfaceSnapshot(
                name: interface.name,
                kind: interface.kind,
                status: interface.status,
                mtu: interface.mtu,
                macAddress: interface.macAddress,
                addresses: interface.addresses,
                packetsIn: counter?.packetsIn ?? 0,
                packetsOut: counter?.packetsOut ?? 0,
                bytesIn: counter?.bytesIn ?? 0,
                bytesOut: counter?.bytesOut ?? 0,
                isPrimary: interface.name == route.interface
            )
        }
        .sorted { lhs, rhs in
            if lhs.isPrimary != rhs.isPrimary {
                return lhs.isPrimary
            }
            return lhs.name < rhs.name
        }

        return NetworkDetailsSnapshot(
            interfaces: interfaces,
            connections: currentConnections(),
            dnsServers: dnsInfo.servers,
            searchDomains: dnsInfo.searchDomains,
            defaultGateway: route.gateway,
            primaryInterface: route.interface,
            wifiNetwork: currentWiFiNetwork(interface: route.interface),
            capturedAt: Date()
        )
    }

    private func currentCPUPercent() -> CPUSnapshot {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let cpuInfo else {
            return CPUSnapshot(overallPercent: 0, perCorePercent: [])
        }

        defer {
            if let previousCPUInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), vm_size_t(previousCPUInfoCount))
            }
            previousCPUInfo = cpuInfo
            previousCPUInfoCount = cpuInfoCount
        }

        guard let previousCPUInfo else {
            return CPUSnapshot(
                overallPercent: 0,
                perCorePercent: Array(repeating: 0, count: Int(numCPUs))
            )
        }

        var totalInUse: UInt32 = 0
        var totalTicks: UInt32 = 0
        var perCorePercent: [Double] = []

        for cpu in 0 ..< Int(numCPUs) {
            let base = cpu * Int(CPU_STATE_MAX)

            let user = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)] - previousCPUInfo[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)] - previousCPUInfo[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)] - previousCPUInfo[base + Int(CPU_STATE_NICE)])
            let idle = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)] - previousCPUInfo[base + Int(CPU_STATE_IDLE)])

            totalInUse += user + system + nice
            totalTicks += user + system + nice + idle

            let coreTicks = user + system + nice + idle
            let percent = coreTicks > 0 ? (Double(user + system + nice) / Double(coreTicks)) * 100 : 0
            perCorePercent.append(percent)
        }

        guard totalTicks > 0 else {
            return CPUSnapshot(overallPercent: 0, perCorePercent: perCorePercent)
        }
        return CPUSnapshot(
            overallPercent: (Double(totalInUse) / Double(totalTicks)) * 100,
            perCorePercent: perCorePercent
        )
    }

    private func currentMemory() -> (percent: Double, usedGB: Double, totalGB: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }

        guard result == KERN_SUCCESS else { return (0, 0, 0) }

        let pageSize = Double(vm_kernel_page_size)
        let usedBytes = Double(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count) * pageSize
        let totalBytes = Double(Self.sysctlUInt64(name: "hw.memsize"))

        guard totalBytes > 0 else { return (0, 0, 0) }
        return (
            (usedBytes / totalBytes) * 100,
            usedBytes / 1_073_741_824,
            totalBytes / 1_073_741_824
        )
    }

    private func currentNetwork() -> (input: Double, output: Double) {
        let counters = currentInterfaceCounters()
        let inBytes = counters.values.reduce(UInt64(0)) { $0 + $1.bytesIn }
        let outBytes = counters.values.reduce(UInt64(0)) { $0 + $1.bytesOut }

        defer { previousNetworkTotals = (inBytes, outBytes) }
        guard let previous = previousNetworkTotals else { return (0, 0) }

        return (
            max(0, Double(inBytes - previous.input) / 1024 / 2),
            max(0, Double(outBytes - previous.output) / 1024 / 2)
        )
    }

    private func currentDisk() -> (read: Double, write: Double) {
        let output = Shell.run("/usr/sbin/iostat", arguments: ["-Id", "disk0"])
        let lines = output.split(separator: "\n")
        guard let last = lines.last else { return (0, 0) }
        let fields = last.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 6 else { return (0, 0) }

        let readTotal = Double(fields[2]) ?? 0
        let writeTotal = Double(fields[3]) ?? 0
        let now = Date()

        defer {
            previousDiskTotals = (readTotal, writeTotal)
            previousDiskTimestamp = now
        }

        guard
            let previous = previousDiskTotals,
            let previousTime = previousDiskTimestamp
        else {
            return (0, 0)
        }

        let delta = max(now.timeIntervalSince(previousTime), 1)
        return (
            max(0, readTotal - previous.read) / delta,
            max(0, writeTotal - previous.write) / delta
        )
    }

    private func currentBattery() -> (percent: Double?, isCharging: Bool?) {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef],
            let source = sources.first,
            let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any]
        else {
            return (nil, nil)
        }

        let current = description[kIOPSCurrentCapacityKey] as? Double
        let max = description[kIOPSMaxCapacityKey] as? Double
        let state = description[kIOPSPowerSourceStateKey] as? String
        let charging = state == kIOPSACPowerValue

        guard let current, let max, max > 0 else { return (nil, charging) }
        return ((current / max) * 100, charging)
    }

    private func currentGPUPercent() -> Double? {
        let acceleratorOutput = Shell.run("/usr/sbin/ioreg", arguments: ["-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"])
        if let percent = parseGPUPercent(from: acceleratorOutput) {
            return percent
        }

        let agxOutput = Shell.run("/usr/sbin/ioreg", arguments: ["-r", "-d", "2", "-w", "0", "-c", "AGXAccelerator"])
        return parseGPUPercent(from: agxOutput)
    }

    private func parseGPUPercent(from output: String) -> Double? {
        let patterns = [
            #""Device Utilization %"\s*=\s*([0-9]+(?:\.[0-9]+)?)"#,
            #""Renderer Utilization %"\s*=\s*([0-9]+(?:\.[0-9]+)?)"#,
            #""GPU UT Engagement centi-%".*?([0-9]+(?:\.[0-9]+)?)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(output.startIndex..., in: output)
            guard
                let match = regex.firstMatch(in: output, options: [], range: nsRange),
                let valueRange = Range(match.range(at: 1), in: output),
                let value = Double(output[valueRange])
            else {
                continue
            }
            return min(max(value, 0), 100)
        }

        return nil
    }

    private func currentThermalLevel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private static func sysctlUInt64(name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname(name, &value, &size, nil, 0)
        return value
    }

    private func currentInterfaceCounters() -> [String: NetworkInterfaceCounter] {
        let output = Shell.run("/usr/sbin/netstat", arguments: ["-ibn"])
        var counters: [String: NetworkInterfaceCounter] = [:]

        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10 else { continue }
            let name = String(fields[0])
            guard name != "lo0", String(fields[2]).hasPrefix("<Link#") else { continue }

            counters[name] = NetworkInterfaceCounter(
                packetsIn: UInt64(fields[4]) ?? 0,
                packetsOut: UInt64(fields[7]) ?? 0,
                bytesIn: UInt64(fields[6]) ?? 0,
                bytesOut: UInt64(fields[9]) ?? 0
            )
        }

        return counters
    }

    private func currentInterfaceDetails() -> [RawNetworkInterface] {
        let output = Shell.run("/sbin/ifconfig", arguments: ["-a"], timeout: 10)
        var interfaces: [RawNetworkInterface] = []
        var currentName = ""
        var currentMTU = 0
        var currentStatus = "Unknown"
        var currentMAC: String?
        var currentAddresses: [String] = []

        func flushCurrent() {
            guard !currentName.isEmpty else { return }
            interfaces.append(
                RawNetworkInterface(
                    name: currentName,
                    kind: interfaceKind(for: currentName),
                    status: currentStatus,
                    mtu: currentMTU,
                    macAddress: currentMAC,
                    addresses: currentAddresses
                )
            )
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if !line.hasPrefix("\t"), !line.hasPrefix(" ") {
                flushCurrent()
                currentAddresses = []
                currentMAC = nil
                currentStatus = "Unknown"
                currentMTU = 0

                let name = line.split(separator: ":").first.map(String.init) ?? ""
                currentName = name
                if let mtuRange = line.range(of: " mtu ") {
                    currentMTU = Int(line[mtuRange.upperBound...].split(whereSeparator: \.isWhitespace).first ?? "") ?? 0
                }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("status:") {
                currentStatus = trimmed.replacingOccurrences(of: "status:", with: "").trimmingCharacters(in: .whitespaces).capitalized
            } else if trimmed.hasPrefix("ether ") {
                currentMAC = trimmed.replacingOccurrences(of: "ether ", with: "")
            } else if trimmed.hasPrefix("inet ") {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count > 1 {
                    currentAddresses.append(String(parts[1]))
                }
            } else if trimmed.hasPrefix("inet6 ") {
                let parts = trimmed.split(whereSeparator: \.isWhitespace)
                if parts.count > 1 {
                    currentAddresses.append(String(parts[1]))
                }
            }
        }

        flushCurrent()
        return interfaces.filter { !$0.addresses.isEmpty || $0.status == "Active" || $0.name.hasPrefix("en") || $0.name.hasPrefix("awdl") }
    }

    private func currentConnections() -> [NetworkConnectionSnapshot] {
        let output = Shell.run("/usr/sbin/lsof", arguments: ["-nP", "-i"], timeout: 10)
        var connections: [NetworkConnectionSnapshot] = []

        for line in output.split(separator: "\n").dropFirst() {
            let pattern = #"^(\S+)\s+(\d+)\s+(\S+)\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(\S+)\s+(.*)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let string = String(line)
            let range = NSRange(string.startIndex..., in: string)
            guard
                let match = regex.firstMatch(in: string, range: range),
                let commandRange = Range(match.range(at: 1), in: string),
                let pidRange = Range(match.range(at: 2), in: string),
                let userRange = Range(match.range(at: 3), in: string),
                let protocolRange = Range(match.range(at: 4), in: string),
                let endpointRange = Range(match.range(at: 5), in: string)
            else {
                continue
            }

            let command = String(string[commandRange]).replacingOccurrences(of: "\\x20", with: " ")
            let pid = Int32(String(string[pidRange])) ?? 0
            let user = String(string[userRange])
            let proto = String(string[protocolRange])
            let endpointText = String(string[endpointRange])

            let state: String
            let endpointPortion: String
            if let stateStart = endpointText.range(of: " (") {
                endpointPortion = String(endpointText[..<stateStart.lowerBound])
                state = endpointText[stateStart.upperBound...].dropLast().description
            } else {
                endpointPortion = endpointText
                state = proto == "TCP" ? "Connected" : "Datagram"
            }

            let parts = endpointPortion.components(separatedBy: "->")
            let localEndpoint = parts.first?.trimmingCharacters(in: .whitespaces) ?? endpointPortion
            let remoteEndpoint = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "Listening"

            connections.append(
                NetworkConnectionSnapshot(
                    processName: command,
                    pid: pid,
                    user: user,
                    protocolName: proto,
                    localEndpoint: localEndpoint,
                    remoteEndpoint: remoteEndpoint,
                    state: state
                )
            )
        }

        return connections
            .sorted {
                if $0.state != $1.state {
                    return $0.state < $1.state
                }
                return $0.processName < $1.processName
            }
            .prefix(200)
            .map { $0 }
    }

    private func currentDNSInfo() -> (servers: [String], searchDomains: [String]) {
        let output = Shell.run("/usr/sbin/scutil", arguments: ["--dns"], timeout: 10)
        var servers: [String] = []
        var searchDomains: [String] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("nameserver[") {
                if let value = trimmed.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !servers.contains(value) {
                    servers.append(value)
                }
            } else if trimmed.hasPrefix("search domain[") {
                if let value = trimmed.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), !searchDomains.contains(value) {
                    searchDomains.append(value)
                }
            }
        }

        return (servers, searchDomains)
    }

    private func currentRouteInfo() -> (gateway: String, interface: String) {
        let output = Shell.run("/sbin/route", arguments: ["-n", "get", "default"], timeout: 10)
        var gateway = "Unavailable"
        var interface = "Unavailable"

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.replacingOccurrences(of: "gateway:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }

        return (gateway, interface)
    }

    private func currentWiFiNetwork(interface: String) -> String? {
        guard interface.hasPrefix("en") else { return nil }
        let output = Shell.run("/usr/sbin/networksetup", arguments: ["-getairportnetwork", interface], timeout: 5)
        guard output.contains("Current Wi-Fi Network") else { return nil }
        return output.split(separator: ":").last?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func interfaceKind(for name: String) -> String {
        if name == "lo0" { return "Loopback" }
        if name.hasPrefix("en") { return "Ethernet / Wi-Fi" }
        if name.hasPrefix("awdl") { return "Apple Wireless Direct Link" }
        if name.hasPrefix("utun") { return "Tunnel / VPN" }
        if name.hasPrefix("bridge") { return "Bridge" }
        if name.hasPrefix("ap") { return "Access Point" }
        return "Interface"
    }
}

private struct NetworkInterfaceCounter {
    let packetsIn: UInt64
    let packetsOut: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64
}

private struct RawNetworkInterface {
    let name: String
    let kind: String
    let status: String
    let mtu: Int
    let macAddress: String?
    let addresses: [String]
}
