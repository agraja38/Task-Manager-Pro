import AppKit
import Darwin
import Foundation

final class ProcessMonitorService {
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    func fetchProcesses(appMetadataByPID: [Int32: RunningAppMetadata]) -> [ProcessSnapshot] {
        let metadataByPID = fetchProcessMetadata()
        let liveStatsByPID = fetchLiveActivityStats()
        var provisional: [Int32: ProcessSnapshot] = [:]
        var childrenByParent: [Int32: [Int32]] = [:]

        for (pid, metadata) in metadataByPID {
            let live = liveStatsByPID[pid]
            let ppid = metadata.ppid
            let cpu = live?.cpuUsage ?? 0
            let user = live?.user ?? metadata.user
            let memoryMB = live?.memoryMB ?? metadata.memoryMB
            let stateCode = live?.stateCode ?? metadata.stateCode
            let app = appMetadataByPID[pid]
            let executablePath = (app?.executablePath.isEmpty == false ? app?.executablePath : nil) ?? metadata.executablePath
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = preferredName(app: app, executablePath: executablePath)
            let launchDate = metadata.launchDate
            let status = statusLabel(for: stateCode, app: app)
            let energy = min(100, cpu * 0.65 + (memoryMB / 1024) * 24 + (app != nil ? 6 : 0))
            let critical = isCriticalProcess(pid: pid, name: appName, bundleID: bundleID, path: executablePath)
            let metadata = [
                "Executable": executablePath,
                "Bundle ID": bundleID.isEmpty ? "Not available" : bundleID,
                "Elapsed": elapsedString(from: launchDate),
                "Architecture": app?.architecture ?? "Unknown",
                "Launch Type": app?.isRegularApp == true ? "Regular app" : "Background or daemon"
            ]

            provisional[pid] = ProcessSnapshot(
                id: pid,
                pid: pid,
                ppid: ppid,
                name: appName,
                executablePath: executablePath,
                bundleIdentifier: bundleID,
                user: user,
                stateCode: stateCode,
                status: status,
                cpuUsage: cpu,
                memoryMB: memoryMB,
                energyImpact: energy,
                launchDate: launchDate,
                elapsedTime: elapsedString(from: launchDate),
                isApp: app != nil,
                isFrontmost: app?.isActive ?? false,
                isCritical: critical,
                childPIDs: [],
                metadata: metadata
            )

            childrenByParent[ppid, default: []].append(pid)
        }

        for (pid, process) in provisional {
            provisional[pid] = ProcessSnapshot(
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
                memoryMB: process.memoryMB,
                energyImpact: process.energyImpact,
                launchDate: process.launchDate,
                elapsedTime: process.elapsedTime,
                isApp: process.isApp,
                isFrontmost: process.isFrontmost,
                isCritical: process.isCritical,
                childPIDs: childrenByParent[pid, default: []].sorted(),
                metadata: process.metadata
            )
        }

        return provisional.values.sorted { $0.cpuUsage > $1.cpuUsage }
    }

    private func fetchProcessMetadata() -> [Int32: ProcessMetadata] {
        let output = Shell.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,user=,rss=,state=,lstart=,comm="], timeout: 10)
        var results: [Int32: ProcessMetadata] = [:]

        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 10, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count >= 11 else { continue }
            guard
                let pid = Int32(fields[0]),
                let ppid = Int32(fields[1])
            else { continue }

            let user = String(fields[2])
            let memoryMB = (Double(fields[3]) ?? 0) / 1024
            let stateCode = String(fields[4])
            let dateString = [fields[5], fields[6], fields[7], fields[8], fields[9]].map(String.init).joined(separator: " ")
            let executablePath = String(fields[10])

            results[pid] = ProcessMetadata(
                pid: pid,
                ppid: ppid,
                user: user,
                memoryMB: memoryMB,
                stateCode: stateCode,
                launchDate: dateFormatter.date(from: dateString),
                executablePath: executablePath
            )
        }

        return results
    }

    private func fetchLiveActivityStats() -> [Int32: LiveActivityStat] {
        let output = Shell.run("/usr/bin/top", arguments: ["-l", "1", "-o", "cpu", "-stats", "pid,command,cpu,mem,state,user"], timeout: 10)
        var results: [Int32: LiveActivityStat] = [:]

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let firstToken = trimmed.split(separator: " ").first, Int32(firstToken) != nil else { continue }

            let fields = trimmed.split(maxSplits: 5, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count >= 6, let pid = Int32(fields[0]) else { continue }

            results[pid] = LiveActivityStat(
                cpuUsage: Double(fields[2].replacingOccurrences(of: "%", with: "")) ?? 0,
                memoryMB: parseMemoryToMB(String(fields[3])),
                stateCode: String(fields[4]),
                user: String(fields[5])
            )
        }

        return results
    }

    func perform(_ action: ProcessAction, on process: ProcessSnapshot) throws {
        guard !process.isCritical else {
            throw NSError(domain: "TaskManagerPro", code: 1, userInfo: [NSLocalizedDescriptionKey: "Task Manager Pro blocked the action because this looks like a critical macOS process."])
        }

        if action == .quit, let app = NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier == process.pid }) {
            if !app.terminate() {
                throw NSError(domain: "TaskManagerPro", code: 2, userInfo: [NSLocalizedDescriptionKey: "The app refused to quit normally."])
            }
            return
        }

        let signal: Int32 = action == .forceQuit ? SIGKILL : SIGTERM
        if kill(process.pid, signal) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "macOS denied the request to stop PID \(process.pid)."])
        }
    }

    private func statusLabel(for state: String, app: RunningAppMetadata?) -> String {
        if app?.isActive == true { return "Frontmost" }
        if app?.isFinishedLaunching == false { return "Launching" }

        switch state.first {
        case "R": return "Running"
        case "S": return "Sleeping"
        case "I": return "Idle"
        case "T": return "Stopped"
        case "U": return "Uninterruptible"
        case "Z": return "Zombie"
        default: return "Running"
        }
    }

    private func elapsedString(from date: Date?) -> String {
        guard let date else { return "Unknown" }
        let interval = Int(Date().timeIntervalSince(date))
        let hours = interval / 3600
        let minutes = (interval % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    private func isCriticalProcess(pid: Int32, name: String, bundleID: String, path: String) -> Bool {
        if pid == 1 || pid < 100 { return true }

        let criticalNames = ["launchd", "kernel_task", "WindowServer", "loginwindow", "sysmond", "runningboardd"]
        if criticalNames.contains(name) { return true }

        let criticalBundleIDs = ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver"]
        if criticalBundleIDs.contains(bundleID) { return true }

        return path.hasPrefix("/System/Library") || path.hasPrefix("/usr/libexec")
    }

    private func parseMemoryToMB(_ value: String) -> Double {
        let cleaned = value.uppercased()
        if cleaned.hasSuffix("G"), let number = Double(cleaned.dropLast()) { return number * 1024 }
        if cleaned.hasSuffix("M"), let number = Double(cleaned.dropLast()) { return number }
        if cleaned.hasSuffix("K"), let number = Double(cleaned.dropLast()) { return number / 1024 }
        if cleaned.hasSuffix("B"), let number = Double(cleaned.dropLast()) { return number / 1_048_576 }
        return Double(cleaned) ?? 0
    }

    private func preferredName(app: RunningAppMetadata?, executablePath: String) -> String {
        if let appName = app?.localizedName, !appName.isEmpty {
            return appName
        }

        let candidate = executablePath.split(separator: "/").last.map(String.init) ?? executablePath
        return candidate.isEmpty ? "Unknown Process" : candidate
    }
}

private struct ProcessMetadata {
    let pid: Int32
    let ppid: Int32
    let user: String
    let memoryMB: Double
    let stateCode: String
    let launchDate: Date?
    let executablePath: String
}

private struct LiveActivityStat {
    let cpuUsage: Double
    let memoryMB: Double
    let stateCode: String
    let user: String
}
