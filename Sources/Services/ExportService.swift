import AppKit
import Foundation

enum ExportService {
    static func export(processes: [ProcessSnapshot], metrics: PerformanceSnapshot, asJSON: Bool) throws {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "pulsetask-snapshot." + (asJSON ? "json" : "csv")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if asJSON {
            let payload: [String: Any] = [
                "exportedAt": ISO8601DateFormatter().string(from: Date()),
                "metrics": [
                    "cpuPercent": metrics.cpuPercent,
                    "memoryPercent": metrics.memoryPercent,
                    "usedMemoryGB": metrics.usedMemoryGB,
                    "totalMemoryGB": metrics.totalMemoryGB,
                    "diskReadMBps": metrics.diskReadMBps,
                    "diskWriteMBps": metrics.diskWriteMBps,
                    "networkInKBps": metrics.networkInKBps,
                    "networkOutKBps": metrics.networkOutKBps,
                    "thermalLevel": metrics.thermalLevel,
                    "batteryPercent": metrics.batteryPercent as Any
                ],
                "processes": processes.map {
                    [
                        "name": $0.name,
                        "pid": $0.pid,
                        "cpuUsage": $0.cpuUsage,
                        "memoryMB": $0.memoryMB,
                        "energyImpact": $0.energyImpact,
                        "status": $0.status,
                        "user": $0.user,
                        "path": $0.executablePath
                    ]
                }
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            return
        }

        var csv = "name,pid,cpu_percent,memory_mb,energy_impact,status,user,path\n"
        for process in processes {
            let row = [
                escaped(process.name),
                "\(process.pid)",
                String(format: "%.1f", process.cpuUsage),
                String(format: "%.1f", process.memoryMB),
                String(format: "%.1f", process.energyImpact),
                escaped(process.status),
                escaped(process.user),
                escaped(process.executablePath)
            ].joined(separator: ",")
            csv.append(row + "\n")
        }
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func escaped(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
