import Darwin
import Foundation
import IOKit.ps

final class SystemMetricsService {
    private var previousCPUInfo: processor_info_array_t?
    private var previousCPUInfoCount: mach_msg_type_number_t = 0
    private var previousNetworkTotals: (input: UInt64, output: UInt64)?
    private var previousDiskTotals: (read: Double, write: Double)?
    private var previousDiskTimestamp: Date?

    func sample() -> PerformanceSnapshot {
        let cpuPercent = currentCPUPercent()
        let memory = currentMemory()
        let network = currentNetwork()
        let disk = currentDisk()
        let battery = currentBattery()
        let thermal = currentThermalLevel()

        return PerformanceSnapshot(
            cpuPercent: cpuPercent,
            memoryPercent: memory.percent,
            usedMemoryGB: memory.usedGB,
            totalMemoryGB: memory.totalGB,
            diskReadMBps: disk.read,
            diskWriteMBps: disk.write,
            networkInKBps: network.input,
            networkOutKBps: network.output,
            gpuPercent: nil,
            batteryPercent: battery.percent,
            isCharging: battery.isCharging,
            thermalLevel: thermal,
            note: "GPU and temperature telemetry are limited on macOS without private APIs or elevated tools, so Task Manager Pro shows safe alternatives when direct readings are unavailable."
        )
    }

    private func currentCPUPercent() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &cpuInfoCount)
        guard result == KERN_SUCCESS, let cpuInfo else { return 0 }

        defer {
            if let previousCPUInfo {
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: previousCPUInfo), vm_size_t(previousCPUInfoCount))
            }
            previousCPUInfo = cpuInfo
            previousCPUInfoCount = cpuInfoCount
        }

        guard let previousCPUInfo else { return 0 }

        var totalInUse: UInt32 = 0
        var totalTicks: UInt32 = 0

        for cpu in 0 ..< Int(numCPUs) {
            let base = cpu * Int(CPU_STATE_MAX)

            let user = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)] - previousCPUInfo[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)] - previousCPUInfo[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)] - previousCPUInfo[base + Int(CPU_STATE_NICE)])
            let idle = UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)] - previousCPUInfo[base + Int(CPU_STATE_IDLE)])

            totalInUse += user + system + nice
            totalTicks += user + system + nice + idle
        }

        guard totalTicks > 0 else { return 0 }
        return (Double(totalInUse) / Double(totalTicks)) * 100
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
        let output = Shell.run("/usr/sbin/netstat", arguments: ["-ibn"])
        var inBytes: UInt64 = 0
        var outBytes: UInt64 = 0

        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10 else { continue }
            let name = String(fields[0])
            guard name != "lo0" else { continue }
            inBytes += UInt64(fields[6]) ?? 0
            outBytes += UInt64(fields[9]) ?? 0
        }

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
}
