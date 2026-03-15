import Foundation

enum TopSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case performance = "Performance"
    case settings = "Settings"

    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .processes: "list.bullet.rectangle.portrait"
        case .performance: "waveform.path.ecg.rectangle"
        case .settings: "gearshape"
        }
    }
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case compact = "Compact"
    case twoLine = "Two-Line"
    case off = "Off"

    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "Use System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum CPUGraphMode: String, CaseIterable, Identifiable {
    case overall = "Overall"
    case cores = "CPU Cores"

    var id: String { rawValue }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case appsOnly = "Apps Only"
    var id: String { rawValue }
}

enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case memory = "Memory"
    case name = "Name"
    case energy = "Energy"
    var id: String { rawValue }
}

enum ProcessAction: String, CaseIterable, Identifiable {
    case quit = "Quit"
    case terminate = "Terminate"
    case forceQuit = "Force Quit"
    var id: String { rawValue }
}

struct ProcessSnapshot: Identifiable, Hashable {
    let id: Int32
    let pid: Int32
    let ppid: Int32
    let name: String
    let executablePath: String
    let bundleIdentifier: String
    let user: String
    let stateCode: String
    let status: String
    let cpuUsage: Double
    let gpuUsage: Double?
    let memoryMB: Double
    let energyImpact: Double
    let launchDate: Date?
    let elapsedTime: String
    let isApp: Bool
    let isFrontmost: Bool
    let isCritical: Bool
    let childPIDs: [Int32]
    let metadata: [String: String]

    var isHeavy: Bool {
        cpuUsage >= 40 || memoryMB >= 1024 || energyImpact >= 55
    }
}

struct RunningAppMetadata: Hashable {
    let pid: Int32
    let localizedName: String
    let bundleIdentifier: String
    let executablePath: String
    let isActive: Bool
    let isFinishedLaunching: Bool
    let isRegularApp: Bool
    let architecture: String
}

struct TimePoint: Identifiable, Hashable {
    let id = UUID()
    let timestamp: Date
    let value: Double
}

struct PerformanceSnapshot {
    let cpuPercent: Double
    let perCoreCPUPercent: [Double]
    let memoryPercent: Double
    let usedMemoryGB: Double
    let totalMemoryGB: Double
    let diskReadMBps: Double
    let diskWriteMBps: Double
    let networkInKBps: Double
    let networkOutKBps: Double
    let gpuPercent: Double?
    let batteryPercent: Double?
    let isCharging: Bool?
    let thermalLevel: String
    let note: String
}

struct UpdateFeed: Decodable {
    let version: String
    let build: Int
    let notes: String
    let arm64AssetURL: String
    let x86_64AssetURL: String
}

extension Notification.Name {
    static let pulseTaskMetricsDidUpdate = Notification.Name("pulseTaskMetricsDidUpdate")
    static let pulseTaskMenuBarPreferencesDidChange = Notification.Name("pulseTaskMenuBarPreferencesDidChange")
    static let pulseTaskPresentationPreferencesDidChange = Notification.Name("pulseTaskPresentationPreferencesDidChange")
}
