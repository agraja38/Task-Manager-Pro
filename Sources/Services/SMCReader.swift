import Foundation
import IOKit

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
    private static let cpuPriorityKeys = [
        "TCMz", "Te06", "Te0T", "TCMb", "Te05", "Te0S", "TCHP",
        "TfC0", "TfC1", "TfC2", "TfC3", "TfC4",
        "TC0P", "TC0F", "TC0D", "TC0H"
    ]
    private static let gpuPriorityKeys = [
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
        let cpuTemperature = preferredTemperature(in: sensors, priority: Self.cpuPriorityKeys) ?? hottestMatchingTemperature(in: sensors, prefixes: ["TC", "Tp", "Te", "Tf"])
        let gpuTemperature = preferredTemperature(in: sensors, priority: Self.gpuPriorityKeys) ?? hottestMatchingTemperature(in: sensors, prefixes: ["TG", "Tg"])
        let palmRestTemperature = preferredTemperature(in: sensors, priority: Self.palmRestPriorityKeys) ?? hottestMatchingTemperature(in: sensors, prefixes: ["TS", "Ta"])

        let note: String
        if sensors.isEmpty && fans.isEmpty {
            note = "This Mac did not expose readable SMC thermal sensors right now."
        } else {
            note = "Thermals are being read directly from AppleSMC, the same style of sensor path used by dedicated fan and thermal utilities."
        }

        return ThermalDetailsSnapshot(
            cpuTemperatureC: cpuTemperature,
            gpuTemperatureC: gpuTemperature,
            palmRestTemperatureC: palmRestTemperature,
            fanSpeedsRPM: fans,
            hottestSensors: Array(orderedSensors(sensors).prefix(12)),
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
            return ThermalSensorSnapshot(key: rawKey, name: displayName(for: rawKey), valueC: value)
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

    func setManualFanSpeeds(_ speedsByFanIndex: [Int: Int]) throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureOpen()

        let fans = try readFans()
        let fanByIndex = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, $0) })
        let requestedIndices = Set(speedsByFanIndex.keys)

        try setForcedFansMask(requestedIndices)

        for (index, requestedRPM) in speedsByFanIndex.sorted(by: { $0.key < $1.key }) {
            guard let fan = fanByIndex[index] else { continue }
            let clampedRPM = max(fan.minRPM, min(requestedRPM, fan.maxRPM))
            try setFanManualMode(index: index, manual: true)
            try setFanTarget(index: index, rpm: clampedRPM)
        }
    }

    func restoreAutomaticFanControl() throws {
        lock.lock()
        defer { lock.unlock() }
        try ensureOpen()

        let fanCount: Int
        if let cachedFanCount {
            fanCount = cachedFanCount
        } else {
            fanCount = try readFans().count
        }
        try setForcedFansMask([])
        for index in 0 ..< fanCount {
            try setFanManualMode(index: index, manual: false)
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

    private func writeData(_ bytes: [UInt8], for key: SMCKey) throws {
        var input = SMCParamStruct()
        input.key = key.code
        input.data8 = SMCParamStruct.Selector.writeKey.rawValue
        input.keyInfo.dataSize = key.info.size

        var paddedBytes = Array(bytes.prefix(Int(key.info.size)))
        if paddedBytes.count < Int(key.info.size) {
            paddedBytes.append(contentsOf: repeatElement(0, count: Int(key.info.size) - paddedBytes.count))
        }

        withUnsafeMutableBytes(of: &input.bytes) { rawBuffer in
            let destination = rawBuffer.bindMemory(to: UInt8.self)
            for (offset, byte) in paddedBytes.enumerated() {
                destination[offset] = byte
            }
        }

        _ = try callDriver(&input)
    }

    private func writeNumericValue(_ value: Int, to code: FourCharCode) throws {
        let info = try keyInfo(for: code)
        let key = SMCKey(code: code, info: info)

        switch info {
        case .fpe2:
            let scaled = max(0, Int(round(Double(value) * 4.0)))
            try writeData([
                UInt8((scaled >> 6) & 0xff),
                UInt8((scaled << 2) & 0xff)
            ], for: key)
        case .ui8:
            try writeData([UInt8(max(0, min(value, 255)))], for: key)
        case .ui16:
            let clamped = UInt16(max(0, min(value, Int(UInt16.max))))
            try writeData([UInt8((clamped >> 8) & 0xff), UInt8(clamped & 0xff)], for: key)
        case .ui32:
            let clamped = UInt32(max(0, value))
            try writeData([
                UInt8((clamped >> 24) & 0xff),
                UInt8((clamped >> 16) & 0xff),
                UInt8((clamped >> 8) & 0xff),
                UInt8(clamped & 0xff)
            ], for: key)
        default:
            throw SMCReaderError.unsupportedDataType(info.code.toString())
        }
    }

    private func setFanManualMode(index: Int, manual: Bool) throws {
        let modeCode = FourCharCode(fromString: "F\(index)Md")
        guard let _ = try? keyInfo(for: modeCode) else { return }
        try writeNumericValue(manual ? 1 : 0, to: modeCode)
    }

    private func setForcedFansMask(_ indices: Set<Int>) throws {
        let maskCode = FourCharCode(fromString: "FS! ")
        guard let info = try? keyInfo(for: maskCode) else { return }
        let key = SMCKey(code: maskCode, info: info)
        let maskValue = indices.reduce(0) { partialResult, index in
            partialResult | (1 << index)
        }

        switch info {
        case .ui8:
            try writeData([UInt8(maskValue & 0xff)], for: key)
        case .ui16:
            try writeData([UInt8((maskValue >> 8) & 0xff), UInt8(maskValue & 0xff)], for: key)
        case .ui32:
            try writeData([
                UInt8((maskValue >> 24) & 0xff),
                UInt8((maskValue >> 16) & 0xff),
                UInt8((maskValue >> 8) & 0xff),
                UInt8(maskValue & 0xff)
            ], for: key)
        default:
            break
        }
    }

    private func setFanTarget(index: Int, rpm: Int) throws {
        let targetCandidates = [
            FourCharCode(fromString: "F\(index)Tg"),
            FourCharCode(fromString: "F\(index)Mn")
        ]

        var wroteTarget = false
        for code in targetCandidates {
            if let _ = try? keyInfo(for: code) {
                try writeNumericValue(rpm, to: code)
                wroteTarget = true
            }
        }

        if !wroteTarget {
            throw SMCReaderError.keyNotFound("F\(index)Tg/F\(index)Mn")
        }
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

    private func orderedSensors(_ sensors: [ThermalSensorSnapshot]) -> [ThermalSensorSnapshot] {
        sensors.sorted { lhs, rhs in
            let lhsRank = sensorSortRank(lhs)
            let rhsRank = sensorSortRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.name != rhs.name {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.key < rhs.key
        }
    }

    private func sensorSortRank(_ sensor: ThermalSensorSnapshot) -> Int {
        if Self.cpuPriorityKeys.contains(sensor.key) || sensor.key.hasPrefix("TC") || sensor.key.hasPrefix("Te") || sensor.key.hasPrefix("Tp") || sensor.key.hasPrefix("Tf") {
            return 0
        }
        if Self.gpuPriorityKeys.contains(sensor.key) || sensor.key.hasPrefix("TG") || sensor.key.hasPrefix("Tg") {
            return 1
        }
        if Self.palmRestPriorityKeys.contains(sensor.key) || sensor.key.hasPrefix("TS") || sensor.key.hasPrefix("Ta") {
            return 2
        }
        if sensor.key.hasPrefix("TV") {
            return 3
        }
        if sensor.key.hasPrefix("TB") {
            return 4
        }
        return 5
    }

    private func displayName(for key: String) -> String {
        if let mapped = explicitSensorNames[key] {
            return mapped
        }

        if key.hasPrefix("TPD"), let label = indexedLabel(key, prefix: "TPD", base: "Performance Core") {
            return label
        }
        if key.hasPrefix("TRD"), let label = indexedLabel(key, prefix: "TRD", base: "Efficiency Core") {
            return label
        }
        if key.hasPrefix("TUD"), let label = indexedLabel(key, prefix: "TUD", base: "Unified Core") {
            return label
        }
        if key.hasPrefix("TD"), let label = indexedLabel(key, prefix: "TD", base: "CPU Die Sensor") {
            return label
        }

        switch key.prefix(2) {
        case "TV":
            return "Voltage Regulator \(key.dropFirst(2))"
        case "TG", "Tg":
            return "GPU Sensor \(key.dropFirst(2))"
        case "TC":
            return "CPU Sensor \(key.dropFirst(2))"
        case "Te":
            return "Efficiency Sensor \(key.dropFirst(2))"
        case "Tp":
            return "Performance Sensor \(key.dropFirst(2))"
        case "Ta":
            return "Surface Sensor \(key.dropFirst(2))"
        case "TS":
            return "Palm Rest Sensor \(key.dropFirst(2))"
        case "TB":
            return "Enclosure Sensor \(key.dropFirst(2))"
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

    private var explicitSensorNames: [String: String] {
        [
            "TCMz": "CPU Thermal Zone",
            "TCMb": "CPU Memory Buffer",
            "TCHP": "CPU Performance Cluster",
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
            "TG0P": "GPU Proximity",
            "TG0D": "GPU Diode",
            "TG0H": "GPU Heatsink",
            "TS0P": "Palm Rest",
            "TaLP": "Left Palm Rest",
            "TaRF": "Right Front Edge",
            "TaTP": "Top Case",
            "TaLT": "Left Trackpad Edge",
            "TaRT": "Right Trackpad Edge",
            "TaLW": "Left Wrist Rest",
            "TaRW": "Right Wrist Rest",
            "TB0T": "Base Enclosure",
            "TB1T": "Base Enclosure Rear",
            "TB2T": "Base Enclosure Mid",
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
}
