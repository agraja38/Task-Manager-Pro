import Foundation

enum TopSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case performance = "Performance"
    case network = "Network"
    case thermals = "Thermals"
    case settings = "Settings"

    var id: String { rawValue }
    var symbolName: String {
        switch self {
        case .processes: "list.bullet.rectangle.portrait"
        case .performance: "waveform.path.ecg.rectangle"
        case .network: "network"
        case .thermals: "thermometer.medium"
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

enum FanMenuTemperatureSource: String, CaseIterable, Identifiable {
    case cpuAverage = "CPU Avg"
    case gpuAverage = "GPU Avg"
    case palmRest = "Palm Rest"
    case trackpad = "Trackpad"

    var id: String { rawValue }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "Use System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
}

enum AppMode: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case advance = "Advance"

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
    case gpu = "GPU"
    case memory = "Memory"
    case name = "Name"
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
    let cachedFilesGB: Double
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

struct NetworkDetailsSnapshot: Hashable {
    let interfaces: [NetworkInterfaceSnapshot]
    let connections: [NetworkConnectionSnapshot]
    let dnsServers: [String]
    let searchDomains: [String]
    let defaultGateway: String
    let primaryInterface: String
    let wifiNetwork: String?
    let capturedAt: Date

    static let empty = NetworkDetailsSnapshot(
        interfaces: [],
        connections: [],
        dnsServers: [],
        searchDomains: [],
        defaultGateway: "Unavailable",
        primaryInterface: "Unavailable",
        wifiNetwork: nil,
        capturedAt: .distantPast
    )
}

struct NetworkInterfaceSnapshot: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let kind: String
    let status: String
    let mtu: Int
    let macAddress: String?
    let addresses: [String]
    let packetsIn: UInt64
    let packetsOut: UInt64
    let bytesIn: UInt64
    let bytesOut: UInt64
    let isPrimary: Bool
}

struct NetworkConnectionSnapshot: Identifiable, Hashable {
    var id: String { "\(pid)-\(protocolName)-\(localEndpoint)-\(remoteEndpoint)-\(state)" }
    let processName: String
    let pid: Int32
    let user: String
    let protocolName: String
    let localEndpoint: String
    let remoteEndpoint: String
    let state: String
}

struct ThermalDetailsSnapshot: Hashable {
    let cpuTemperatureC: Double?
    let gpuTemperatureC: Double?
    let palmRestTemperatureC: Double?
    let fanSpeedsRPM: [FanSpeedSnapshot]
    let hottestSensors: [ThermalSensorSnapshot]
    let thermalLevel: String
    let note: String
    let requiresPrivilege: Bool
    let capturedAt: Date

    static let empty = ThermalDetailsSnapshot(
        cpuTemperatureC: nil,
        gpuTemperatureC: nil,
        palmRestTemperatureC: nil,
        fanSpeedsRPM: [],
        hottestSensors: [],
        thermalLevel: "Unknown",
        note: "Detailed temperatures and fan speeds appear here when Task Manager Pro can read AppleSMC directly on this Mac.",
        requiresPrivilege: false,
        capturedAt: .distantPast
    )
}

struct ThermalSensorSnapshot: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let name: String
    let category: ThermalSensorCategory
    let valueC: Double
}

enum ThermalSensorCategory: String, CaseIterable, Identifiable {
    case cpu = "CPU"
    case gpu = "GPU"
    case power = "Power"
    case connectivity = "Connectivity"
    case input = "Input"
    case storage = "Storage"
    case other = "Other"

    var id: String { rawValue }

    var sortOrder: Int {
        switch self {
        case .cpu: 0
        case .gpu: 1
        case .power: 2
        case .connectivity: 3
        case .input: 4
        case .storage: 5
        case .other: 6
        }
    }
}

struct FanSpeedSnapshot: Identifiable, Hashable {
    var id: Int { index }
    let index: Int
    let name: String
    let rpm: Int
    let minRPM: Int
    let maxRPM: Int
}

struct FanPreset: Identifiable, Hashable, Codable {
    let id: UUID
    var name: String
    var minimumSpeedsRPM: [Int]
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
