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
        let output = Shell.run("/bin/ps", arguments: ["-axo", "pid=,ppid=,user=,%cpu=,rss=,state=,lstart=,command="])
        var provisional: [Int32: ProcessSnapshot] = [:]
        var childrenByParent: [Int32: [Int32]] = [:]

        for line in output.split(separator: "\n") {
            let fields = line.split(maxSplits: 11, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count >= 12 else { continue }
            guard
                let pid = Int32(fields[0]),
                let ppid = Int32(fields[1]),
                let cpu = Double(fields[3])
            else { continue }

            let user = String(fields[2])
            let memoryKB = Double(fields[4]) ?? 0
            let stateCode = String(fields[5])
            let dateString = [fields[6], fields[7], fields[8], fields[9], fields[10]].map(String.init).joined(separator: " ")
            let executablePath = String(fields[11])
            let app = appMetadataByPID[pid]
            let bundleID = app?.bundleIdentifier ?? ""
            let appName = app?.localizedName ?? URL(fileURLWithPath: executablePath).lastPathComponent
            let launchDate = dateFormatter.date(from: dateString)
            let status = statusLabel(for: stateCode, app: app)
            let memoryMB = memoryKB / 1024
            let energy = min(100, cpu * 0.65 + (memoryMB / 1024) * 24 + (app != nil ? 6 : 0))
            let critical = isCriticalProcess(pid: pid, name: appName, bundleID: bundleID, path: executablePath)
            let metadata = [
                "Executable": executablePath,
                "Bundle ID": bundleID.isEmpty ? "Not available" : bundleID,
                "Elapsed": elapsedString(from: launchDate),
                "Architecture": app?.architecture ?? architectureForExecutable(at: executablePath),
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

    private func architectureForExecutable(at path: String) -> String {
        let fileInfo = Shell.run("/usr/bin/file", arguments: [path], timeout: 2)
        if fileInfo.localizedCaseInsensitiveContains("x86_64") { return "Intel" }
        if fileInfo.localizedCaseInsensitiveContains("arm64") { return "Apple Silicon / Native" }
        return "Unknown"
    }
}
