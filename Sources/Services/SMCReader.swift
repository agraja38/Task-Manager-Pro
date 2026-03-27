import Foundation
import IOKit
import Darwin

// Adapted from the public AppleSMC client struct layout documented in SMCKit
// (MIT) and the fan/temperature key usage patterns used by smcFanControl.

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct SMCDataType: Equatable {
    let code: FourCharCode
    let size: UInt32

    static let fds = SMCDataType(code: FourCharCode(fromStaticString: "{fds"), size: 16)
    static let flt = SMCDataType(code: FourCharCode(fromStaticString: "flt "), size: 4)
    static let fpe2 = SMCDataType(code: FourCharCode(fromStaticString: "fpe2"), size: 2)
    static let sp78 = SMCDataType(code: FourCharCode(fromStaticString: "sp78"), size: 2)
    static let ui8 = SMCDataType(code: FourCharCode(fromStaticString: "ui8 "), size: 1)
    static let ui16 = SMCDataType(code: FourCharCode(fromStaticString: "ui16"), size: 2)
    static let ui32 = SMCDataType(code: FourCharCode(fromStaticString: "ui32"), size: 4)
    static let si32 = SMCDataType(code: FourCharCode(fromStaticString: "si32"), size: 4)
}

private struct SMCKey {
    let code: FourCharCode
    let info: SMCDataType
}

private struct SMCParamStruct {
    enum Selector: UInt8 {
        case handleYPCEvent = 2
        case readKey = 5
        case writeKey = 6
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    enum Result: UInt8 {
        case success = 0
        case keyNotFound = 132
    }

    struct Version {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct KeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum SMCReaderError: LocalizedError {
    case driverNotFound
    case failedToOpen(kern_return_t)
    case keyNotFound(String)
    case invalidResponse(kern_return_t, UInt8)
    case unsupportedDataType(String)

    var errorDescription: String? {
        switch self {
        case .driverNotFound:
            return "AppleSMC is not available on this Mac."
        case let .failedToOpen(status):
            return "Task Manager Pro could not open AppleSMC. (Status \(status))"
        case let .keyNotFound(code):
            return "The sensor key \(code) is not available on this Mac."
        case let .invalidResponse(ioReturn, smcResult):
            return "AppleSMC returned an invalid response. (I/O \(ioReturn), SMC \(smcResult))"
        case let .unsupportedDataType(type):
            return "Task Manager Pro does not yet understand SMC data type \(type)."
        }
    }
}

extension UInt32 {
    fileprivate init(fromBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        let byte0 = UInt32(bytes.0) << 24
        let byte1 = UInt32(bytes.1) << 16
        let byte2 = UInt32(bytes.2) << 8
        let byte3 = UInt32(bytes.3)
        self = byte0 | byte1 | byte2 | byte3
    }
}

extension FourCharCode {
    fileprivate init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            let byte0 = UInt32(buffer[0]) << 24
            let byte1 = UInt32(buffer[1]) << 16
            let byte2 = UInt32(buffer[2]) << 8
            let byte3 = UInt32(buffer[3])
            return byte0 | byte1 | byte2 | byte3
        }
    }

    fileprivate init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    fileprivate func toString() -> String {
        String(UnicodeScalar((self >> 24) & 0xff)!) +
        String(UnicodeScalar((self >> 16) & 0xff)!) +
        String(UnicodeScalar((self >> 8) & 0xff)!) +
        String(UnicodeScalar(self & 0xff)!)
    }
}

private extension Double {
    init(fromSP78 bytes: (UInt8, UInt8)) {
        let raw = Int16(bitPattern: (UInt16(bytes.0) << 8) | UInt16(bytes.1))
        self = Double(raw) / 256.0
    }

    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = Double((Int(bytes.0) << 6) + (Int(bytes.1) >> 2))
    }
}

final class SMCReader {
    private struct CPUTopology {
        let totalCores: Int?
        let performanceCores: Int?
        let efficiencyCores: Int?
    }

    private static let cpuPriorityKeys = [
        "TCMA",
        "TCMz", "Te06", "Te0T", "TCMb", "Te05", "Te0S", "TCHP",
        "TfC0", "TfC1", "TfC2", "TfC3", "TfC4",
        "TC0P", "TC0C", "TC0F", "TC0D", "TC0H"
    ]
    private static let gpuPriorityKeys = [
        "Tg0A", "TG0A", "TGAA",
        "Tg0Y", "Tg05", "Tg0S", "Tg0d", "Tg0X", "Tg0K", "Tg0L", "Tg04", "Tg0R",
        "TG0P", "TG0D", "TG0H"
    ]
    private static let palmRestPriorityKeys = [
        "TS0P", "TaLP", "TaRF", "TaTP", "TaLT", "TaRT", "TaLW", "TaRW"
    ]

    private let lock = NSLock()
    private var connection: io_connect_t = 0
    private var keyInfoCache: [FourCharCode: SMCDataType] = [:]
    private var cachedTemperatureKeys: [SMCKey]?
    private var cachedFanCount: Int?
    private lazy var cpuTopology = loadCPUTopology()

    deinit {
        close()
    }

    func sample(currentThermalLevel: String) -> ThermalDetailsSnapshot {
        lock.lock()
        defer { lock.unlock() }

        do {
            return try loadSnapshot(currentThermalLevel: currentThermalLevel)
        } catch {
            close()
            do {
                return try loadSnapshot(currentThermalLevel: currentThermalLevel)
            } catch {
                return ThermalDetailsSnapshot(
                    cpuTemperatureC: nil,
                    gpuTemperatureC: nil,
                    palmRestTemperatureC: nil,
                    fanSpeedsRPM: [],
                    hottestSensors: [],
                    thermalLevel: currentThermalLevel,
                    note: error.localizedDescription,
                    requiresPrivilege: false,
                    capturedAt: Date()
                )
            }
        }
    }

    private func loadSnapshot(currentThermalLevel: String) throws -> ThermalDetailsSnapshot {
        try ensureOpen()
        let sensors = try readTemperatureSensors()
        let fans = try readFans()
        let cpuTemperature = exactKeyTemperature(in: sensors, keys: ["TCMA"])
            ?? averageTemperature(in: sensors, prefixes: ["TRD", "TPD", "TUD", "TPC"])
            ?? preferredTemperature(in: sensors, priority: Self.cpuPriorityKeys)
            ?? hottestMatchingTemperature(in: sensors, prefixes: ["TC", "Tp", "Te", "Tf"])
        let gpuTemperature = exactNamedTemperature(in: sensors, names: ["GPU Cluster Average"]) ?? preferredTemperature(in: sensors, priority: Self.gpuPriorityKeys) ?? hottestMatchingTemperature(in: sensors, prefixes: ["TG", "Tg"])
        let palmRestTemperature = preferredTemperature(in: sensors, priority: Self.palmRestPriorityKeys) ?? hottestMatchingTemperature(in: sensors, prefixes: ["TS", "Ta"])

        let note: String
        if sensors.isEmpty && fans.isEmpty {
            note = "This Mac did not expose readable SMC thermal sensors right now."
        } else {
            note = ""
        }

        return ThermalDetailsSnapshot(
            cpuTemperatureC: cpuTemperature,
            gpuTemperatureC: gpuTemperature,
            palmRestTemperatureC: palmRestTemperature,
            fanSpeedsRPM: fans,
            hottestSensors: curatedSensors(from: sensors),
            thermalLevel: currentThermalLevel,
            note: note,
            requiresPrivilege: false,
            capturedAt: Date()
        )
    }

    private func ensureOpen() throws {
        if connection != 0 { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            throw SMCReaderError.driverNotFound
        }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            connection = 0
            throw SMCReaderError.failedToOpen(result)
        }
    }

    private func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
        keyInfoCache.removeAll()
        cachedTemperatureKeys = nil
        cachedFanCount = nil
    }

    private func exactNamedTemperature(in sensors: [ThermalSensorSnapshot], names: [String]) -> Double? {
        for name in names {
            if let value = sensors.first(where: { $0.name == name })?.valueC {
                return value
            }
        }
        return nil
    }

    private func exactKeyTemperature(in sensors: [ThermalSensorSnapshot], keys: [String]) -> Double? {
        for key in keys {
            if let value = sensors.first(where: { $0.key == key })?.valueC {
                return value
            }
        }
        return nil
    }

    private func averageTemperature(in sensors: [ThermalSensorSnapshot], prefixes: [String]) -> Double? {
        let matches = sensors
            .filter { sensor in
                prefixes.contains { sensor.key.hasPrefix($0) }
            }
            .map(\.valueC)

        guard !matches.isEmpty else { return nil }
        return matches.reduce(0, +) / Double(matches.count)
    }

    private func callDriver(_ inputStruct: inout SMCParamStruct, selector: SMCParamStruct.Selector = .handleYPCEvent) throws -> SMCParamStruct {
        var outputStruct = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(selector.rawValue),
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        switch (result, outputStruct.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.success.rawValue):
            return outputStruct
        case (kIOReturnSuccess, SMCParamStruct.Result.keyNotFound.rawValue):
            throw SMCReaderError.keyNotFound(inputStruct.key.toString())
        default:
            throw SMCReaderError.invalidResponse(result, outputStruct.result)
        }
    }

    private func keyInfo(for code: FourCharCode) throws -> SMCDataType {
        if let cached = keyInfoCache[code] {
            return cached
        }

        var input = SMCParamStruct()
        input.key = code
        input.data8 = SMCParamStruct.Selector.getKeyInfo.rawValue
        let output = try callDriver(&input)
        let info = SMCDataType(code: output.keyInfo.dataType, size: UInt32(output.keyInfo.dataSize))
        keyInfoCache[code] = info
        return info
    }

    private func keyCode(at index: Int) throws -> FourCharCode {
        var input = SMCParamStruct()
        input.data8 = SMCParamStruct.Selector.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        let output = try callDriver(&input)
        return output.key
    }

    private func readData(for key: SMCKey) throws -> SMCBytes {
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.info.size
        input.data8 = SMCParamStruct.Selector.readKey.rawValue
        let output = try callDriver(&input)
        return output.bytes
    }

    private func keyCount() throws -> Int {
        let key = SMCKey(code: FourCharCode(fromStaticString: "#KEY"), info: .ui32)
        let data = try readData(for: key)
        return Int(UInt32(fromBytes: (data.0, data.1, data.2, data.3)))
    }

    private func discoveredTemperatureKeys() throws -> [SMCKey] {
        if let cachedTemperatureKeys {
            return cachedTemperatureKeys
        }

        let count = try keyCount()
        var keys: [SMCKey] = []
        keys.reserveCapacity(128)

        for index in 0 ..< count {
            let code = try keyCode(at: index)
            let name = code.toString()
            guard name.hasPrefix("T") else { continue }

            let info = try keyInfo(for: code)
            if info == .flt || info == .sp78 || info == .ui8 || info == .ui16 || info == .ui32 || info == .si32 {
                keys.append(SMCKey(code: code, info: info))
            }
        }

        cachedTemperatureKeys = keys
        return keys
    }

    private func readTemperatureSensors() throws -> [ThermalSensorSnapshot] {
        try discoveredTemperatureKeys().compactMap { key in
            guard let value = try? decodeNumericValue(for: key), value > 0, value < 130 else {
                return nil
            }
            let rawKey = key.code.toString()
            let name = displayName(for: rawKey)
            return ThermalSensorSnapshot(key: rawKey, name: name, category: category(for: rawKey, name: name), valueC: value)
        }
    }

    private func readFans() throws -> [FanSpeedSnapshot] {
        let fanCount: Int
        if let cachedFanCount {
            fanCount = cachedFanCount
        } else {
            let countKey = SMCKey(code: FourCharCode(fromStaticString: "FNum"), info: .ui8)
            let data = try readData(for: countKey)
            fanCount = Int(data.0)
            cachedFanCount = fanCount
        }

        return (0 ..< fanCount).compactMap { fanIndex in
            let speedKey = FourCharCode(fromString: "F\(fanIndex)Ac")
            guard let info = try? keyInfo(for: speedKey) else { return nil }
            let key = SMCKey(code: speedKey, info: info)
            guard let rpmValue = try? decodeNumericValue(for: key) else { return nil }
            let rpm = max(0, Int(rpmValue.rounded()))
            let minRPM = readFanBound(index: fanIndex, suffix: "Mn") ?? 1200
            let maxRPM = readFanBound(index: fanIndex, suffix: "Mx") ?? max(rpm, minRPM)
            let name = readFanName(index: fanIndex) ?? "Fan \(fanIndex + 1)"
            return FanSpeedSnapshot(index: fanIndex, name: name, rpm: rpm, minRPM: minRPM, maxRPM: maxRPM)
        }
    }

    private func readFanName(index: Int) -> String? {
        let nameCode = FourCharCode(fromString: "F\(index)ID")
        guard let info = try? keyInfo(for: nameCode), info == .fds else {
            return nil
        }
        guard let data = try? readData(for: SMCKey(code: nameCode, info: info)) else {
            return nil
        }

        let raw = [data.4, data.5, data.6, data.7, data.8, data.9, data.10, data.11, data.12, data.13, data.14, data.15]
        let name = String(bytes: raw.filter { $0 > 32 }, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    private func readFanBound(index: Int, suffix: String) -> Int? {
        let keyCode = FourCharCode(fromString: "F\(index)\(suffix)")
        guard let info = try? keyInfo(for: keyCode) else { return nil }
        let key = SMCKey(code: keyCode, info: info)
        guard let value = try? decodeNumericValue(for: key) else { return nil }
        return max(0, Int(value.rounded()))
    }

    private func decodeNumericValue(for key: SMCKey) throws -> Double {
        let data = try readData(for: key)

        switch key.info {
        case .flt:
            var raw = UInt32(fromBytes: (data.0, data.1, data.2, data.3))
            raw = UInt32(bigEndian: raw)
            let value = Float(bitPattern: raw)
            return Double(value)
        case .sp78:
            return Double(fromSP78: (data.0, data.1))
        case .fpe2:
            return Double(fromFPE2: (data.0, data.1))
        case .ui8:
            return Double(data.0)
        case .ui16:
            return Double((UInt16(data.0) << 8) | UInt16(data.1))
        case .ui32:
            return Double(UInt32(fromBytes: (data.0, data.1, data.2, data.3)))
        case .si32:
            let value = Int32(bitPattern: UInt32(fromBytes: (data.0, data.1, data.2, data.3)))
            return Double(value)
        default:
            throw SMCReaderError.unsupportedDataType(key.info.code.toString())
        }
    }

    private func preferredTemperature(in sensors: [ThermalSensorSnapshot], priority: [String]) -> Double? {
        let candidates = sensors.filter { priority.contains($0.key) && $0.valueC >= 10 }
        return candidates.map(\.valueC).max()
    }

    private func hottestMatchingTemperature(in sensors: [ThermalSensorSnapshot], prefixes: [String]) -> Double? {
        sensors
            .filter { sensor in prefixes.contains { sensor.key.hasPrefix($0) } }
            .map(\.valueC)
            .max()
    }

    private func curatedSensors(from sensors: [ThermalSensorSnapshot]) -> [ThermalSensorSnapshot] {
        let exactByKey = Dictionary(uniqueKeysWithValues: sensors.map { ($0.key, $0) })
        var remainingByKey = exactByKey
        var curated: [ThermalSensorSnapshot] = []
        var seenNames = Set<String>()

        func appendExact(_ candidates: [String], as name: String) {
            for key in candidates {
                if let sensor = remainingByKey.removeValue(forKey: key) {
                    guard seenNames.insert(name).inserted else { return }
                    curated.append(ThermalSensorSnapshot(key: sensor.key, name: name, category: sensor.category, valueC: sensor.valueC))
                    return
                }
            }
        }

        func appendSeries(prefix: String, namePrefix: String, maxCount: Int? = nil) {
            let matches = remainingByKey.values
                .filter { sensor in
                    guard sensor.key.hasPrefix(prefix) else { return false }
                    let suffix = String(sensor.key.dropFirst(prefix.count))
                    return suffix.count == 1 && suffix.range(of: "^[0-9A-Fa-f]$", options: .regularExpression) != nil
                }
                .sorted { lhs, rhs in
                    numericSuffix(for: lhs.key, after: prefix) < numericSuffix(for: rhs.key, after: prefix)
                }

            for (index, sensor) in matches.enumerated() {
                if let maxCount, index >= maxCount { break }
                remainingByKey.removeValue(forKey: sensor.key)
                let name = "\(namePrefix) \(index + 1)"
                guard seenNames.insert(name).inserted else { continue }
                curated.append(ThermalSensorSnapshot(key: sensor.key, name: name, category: sensor.category, valueC: sensor.valueC))
            }
        }

        func appendRemaining(category: ThermalSensorCategory, preferredPrefixes: [String] = []) {
            let matches = remainingByKey.values
                .filter { $0.category == category }
                .sorted { lhs, rhs in
                    let lhsPrefixScore = preferredPrefixes.firstIndex(where: { lhs.key.hasPrefix($0) }) ?? preferredPrefixes.count
                    let rhsPrefixScore = preferredPrefixes.firstIndex(where: { rhs.key.hasPrefix($0) }) ?? preferredPrefixes.count
                    if lhsPrefixScore != rhsPrefixScore {
                        return lhsPrefixScore < rhsPrefixScore
                    }
                    if lhs.name != rhs.name {
                        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    }
                    return lhs.key < rhs.key
                }

            for sensor in matches {
                remainingByKey.removeValue(forKey: sensor.key)
                guard seenNames.insert(sensor.name).inserted else { continue }
                curated.append(sensor)
            }
        }

        appendExact(["TW0P"], as: "Airport Proximity")
        appendExact(["TB1T"], as: "Battery")
        appendExact(["TB2T"], as: "Battery Gas Gauge")
        appendExact(["TCMA"], as: "CPU Core Average")
        appendSeries(prefix: "TRD", namePrefix: "CPU Efficiency Core", maxCount: cpuTopology.efficiencyCores)
        appendSeries(prefix: "TPD", namePrefix: "CPU Performance Core", maxCount: cpuTopology.performanceCores)
        appendSeries(prefix: "TGC", namePrefix: "GPU Cluster")
        appendExact(["Tg0A", "TG0A", "TGAA"], as: "GPU Cluster Average")
        appendExact(["Tg0d", "TG0D"], as: "GPU Die")
        appendExact(["Tg0K"], as: "GPU Core")
        appendExact(["Tg0L"], as: "GPU Logic")
        appendExact(["Tg0S"], as: "GPU Shader Cluster")
        appendExact(["Tg0R"], as: "GPU Regulator")
        appendExact(["Tg0X"], as: "GPU Max")
        appendExact(["Tg0Y"], as: "GPU Cluster Peak")
        appendExact(["TG0P"], as: "GPU Proximity")
        appendExact(["TM0P"], as: "Power Manager Die Average")
        appendExact(["TV0P"], as: "Power Supply Proximity")
        appendExact(["TH0P"], as: "Thunderbolt Left Proximity")
        appendExact(["TH1P"], as: "Thunderbolt Right Proximity")
        appendExact(["TS0P", "TaLP", "TaLW", "TaRW"], as: "Palm Rest")
        appendExact(["TaPT", "TaLT", "TaRT", "TaTP"], as: "Trackpad")
        appendExact(["TaPA"], as: "Trackpad Actuator")
        appendExact(["Ts0S"], as: "APPLE SSD AP1024Z")
        appendRemaining(category: .gpu, preferredPrefixes: ["Tg", "TG", "TGC"])
        appendRemaining(category: .input, preferredPrefixes: ["TS", "Ta"])

        if !curated.isEmpty {
            return curated
        }

        return sensors.sorted { lhs, rhs in
            if lhs.category != rhs.category {
                return lhs.category.sortOrder < rhs.category.sortOrder
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.key < rhs.key
        }
    }

    private func category(for key: String, name: String) -> ThermalSensorCategory {
        if name.contains("CPU") || key.hasPrefix("TC") || key.hasPrefix("TP") || key.hasPrefix("TR") || key.hasPrefix("Te") || key.hasPrefix("Tf") {
            return .cpu
        }
        if name.contains("GPU") || key.hasPrefix("TG") || key.hasPrefix("Tg") {
            return .gpu
        }
        if name.contains("Battery") || name.contains("Power") || key.hasPrefix("TM") || key.hasPrefix("TV") || key.hasPrefix("TB") {
            return .power
        }
        if name.contains("Airport") || name.contains("Thunderbolt") || key.hasPrefix("TW") || key.hasPrefix("TH") {
            return .connectivity
        }
        if name.contains("Trackpad") || name.contains("Palm Rest") || key.hasPrefix("Ta") || key.hasPrefix("TS") {
            return .input
        }
        if name.contains("SSD") || key == "Ts0S" {
            return .storage
        }
        return .other
    }

    private func numericSuffix(for key: String, after prefix: String) -> Int {
        let suffix = String(key.dropFirst(prefix.count))
        if let value = Int(suffix, radix: 16) {
            return value
        }
        return Int.max
    }

    private func displayName(for key: String) -> String {
        if let mapped = explicitSensorNames[key] {
            return mapped
        }

        if key.hasPrefix("TPD"), let label = indexedCoreLabel(key, prefix: "TPD", base: "CPU Performance Core") {
            return label
        }
        if key.hasPrefix("TRD"), let label = indexedCoreLabel(key, prefix: "TRD", base: "CPU Efficiency Core") {
            return label
        }
        if key.hasPrefix("TUD"), let label = indexedCoreLabel(key, prefix: "TUD", base: "CPU Unified Core") {
            return label
        }
        if key.hasPrefix("TPC"), let label = indexedCoreLabel(key, prefix: "TPC", base: "CPU Core") {
            return label
        }
        if key.hasPrefix("TGC"), let label = indexedCoreLabel(key, prefix: "TGC", base: "GPU Cluster") {
            return label
        }
        if key.hasPrefix("TG"), let label = indexedClusterLabel(key, prefix: "TG", base: "GPU Cluster") {
            return label
        }
        if key.hasPrefix("TD"), let label = indexedLabel(key, prefix: "TD", base: "CPU Die Sensor") {
            return label
        }
        if key.hasPrefix("TB"), let label = indexedLabel(key, prefix: "TB", base: "Battery") {
            return label
        }
        if key.hasPrefix("TW"), let label = indexedLabel(key, prefix: "TW", base: "Airport Proximity") {
            return label
        }
        if key.hasPrefix("TH"), let label = indexedLabel(key, prefix: "TH", base: "Thunderbolt") {
            return label
        }
        if key.hasPrefix("TM"), let label = indexedLabel(key, prefix: "TM", base: "Power Manager") {
            return label
        }

        switch key.prefix(2) {
        case "TV":
            return "Power Supply \(key.dropFirst(2))"
        case "TG", "Tg":
            return "GPU Cluster \(key.dropFirst(2))"
        case "TC":
            return "CPU Core Average"
        case "Te":
            return "CPU Efficiency \(key.dropFirst(2))"
        case "Tp":
            return "CPU Performance \(key.dropFirst(2))"
        case "Ta":
            return "Trackpad \(key.dropFirst(2))"
        case "TS":
            return "Palm Rest \(key.dropFirst(2))"
        case "TB":
            return "Battery \(key.dropFirst(2))"
        default:
            return key
        }
    }

    private func indexedLabel(_ key: String, prefix: String, base: String) -> String? {
        let suffix = String(key.dropFirst(prefix.count))
        if suffix.isEmpty {
            return nil
        }
        return "\(base) \(suffix.uppercased())"
    }

    private func indexedCoreLabel(_ key: String, prefix: String, base: String) -> String? {
        let suffix = String(key.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return nil }
        if let number = Int(suffix, radix: 16) {
            return "\(base) \(number + 1)"
        }
        return "\(base) \(suffix.uppercased())"
    }

    private func indexedClusterLabel(_ key: String, prefix: String, base: String) -> String? {
        let suffix = String(key.dropFirst(prefix.count))
        guard !suffix.isEmpty else { return nil }
        if let number = Int(suffix.prefix(1), radix: 16) {
            return "\(base) \(number + 1)"
        }
        return "\(base) \(suffix.uppercased())"
    }

    private var explicitSensorNames: [String: String] {
        [
            "TCMz": "CPU Thermal Zone",
            "TCMA": "CPU Core Average",
            "TCMb": "CPU Memory Buffer",
            "TCHP": "CPU Performance Cluster",
            "TC0C": "CPU Core Sensor",
            "TC0P": "CPU Proximity",
            "TC0F": "CPU Die",
            "TC0D": "CPU Diode",
            "TC0H": "CPU Heatsink",
            "Te05": "Efficiency Cluster",
            "Te06": "Efficiency Cluster Peak",
            "Te0S": "Efficiency Cluster Sensor",
            "Te0T": "Efficiency Cluster Thermal",
            "TfC0": "CPU Core Group 0",
            "TfC1": "CPU Core Group 1",
            "TfC2": "CPU Core Group 2",
            "TfC3": "CPU Core Group 3",
            "TfC4": "CPU Core Group 4",
            "Tg05": "GPU Cluster",
            "Tg0S": "GPU Shader Cluster",
            "Tg0Y": "GPU Cluster Peak",
            "Tg0d": "GPU Die",
            "Tg0X": "GPU Max",
            "Tg0K": "GPU Core",
            "Tg0L": "GPU Logic",
            "Tg04": "GPU Rail",
            "Tg0R": "GPU Regulator",
            "Tg0A": "GPU Cluster Average",
            "TG0P": "GPU Proximity",
            "TG0D": "GPU Diode",
            "TG0H": "GPU Heatsink",
            "TS0P": "Palm Rest",
            "TaLP": "Left Palm Rest",
            "TaPT": "Trackpad",
            "TaPA": "Trackpad Actuator",
            "TaRF": "Right Front Edge",
            "TaTP": "Top Case",
            "TaLT": "Left Trackpad Edge",
            "TaRT": "Right Trackpad Edge",
            "TaLW": "Left Wrist Rest",
            "TaRW": "Right Wrist Rest",
            "TB0T": "Base Enclosure",
            "TB1T": "Battery",
            "TB2T": "Battery Gas Gauge",
            "TH0P": "Thunderbolt Left Proximity",
            "TH1P": "Thunderbolt Right Proximity",
            "TM0P": "Power Manager Die Average",
            "TVh0": "Voltage Regulator Hotspot 0",
            "TVh1": "Voltage Regulator Hotspot 1",
            "TVm0": "Voltage Regulator Module 0",
            "TVMR": "Memory Voltage Regulator",
            "TVMD": "Voltage Regulator Driver",
            "TVMX": "Voltage Regulator Peak",
            "TVMr": "Voltage Regulator Rail",
            "TVS0": "System Voltage Rail 0",
            "TVS1": "System Voltage Rail 1",
            "TVS2": "System Voltage Rail 2",
            "TVV0": "Video Voltage Rail",
            "TVXX": "Voltage Regulator Global Peak",
            "TVXh": "Voltage Regulator Hotspot Peak",
            "TVxx": "Voltage Regulator Max",
            "TVms": "Voltage Regulator Memory Sensor"
        ]
    }

    private func loadCPUTopology() -> CPUTopology {
        CPUTopology(
            totalCores: sysctlInt("hw.physicalcpu"),
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu"),
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu")
        )
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = name.withCString { key in
            sysctlbyname(key, &value, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return Int(value)
    }
}
