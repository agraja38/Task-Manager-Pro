import Foundation
import IOKit

typealias HelperSMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

private struct HelperSMCDataType: Equatable {
    let code: FourCharCode
    let size: UInt32

    static let flt = HelperSMCDataType(code: FourCharCode(fromStaticString: "flt "), size: 4)
    static let fpe2 = HelperSMCDataType(code: FourCharCode(fromStaticString: "fpe2"), size: 2)
    static let ui8 = HelperSMCDataType(code: FourCharCode(fromStaticString: "ui8 "), size: 1)
    static let ui16 = HelperSMCDataType(code: FourCharCode(fromStaticString: "ui16"), size: 2)
    static let ui32 = HelperSMCDataType(code: FourCharCode(fromStaticString: "ui32"), size: 4)
}

private struct HelperSMCKey {
    let code: FourCharCode
    let info: HelperSMCDataType
}

private struct HelperSMCParamStruct {
    enum Selector: UInt8 {
        case handleYPCEvent = 2
        case readKey = 5
        case writeKey = 6
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
    var bytes: HelperSMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

private enum HelperError: LocalizedError {
    case invalidArguments
    case driverNotFound
    case failedToOpen(kern_return_t)
    case invalidResponse(kern_return_t, UInt8)
    case keyNotFound(String)
    case unsupportedDataType(String)
    case fanDidNotSpinUp(Int)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "Missing fan control arguments."
        case .driverNotFound:
            return "AppleSMC is not available on this Mac."
        case let .failedToOpen(status):
            return "Could not open AppleSMC. (Status \(status))"
        case let .invalidResponse(ioReturn, smcResult):
            return "AppleSMC returned an invalid response. (I/O \(ioReturn), SMC \(smcResult))"
        case let .keyNotFound(key):
            return "Required fan key \(key) is not available on this Mac."
        case let .unsupportedDataType(type):
            return "Unsupported SMC data type \(type)."
        case let .fanDidNotSpinUp(index):
            return "Fan \(index + 1) did not spin up from 0 RPM."
        }
    }
}

private extension UInt32 {
    init(fromBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        self = (UInt32(bytes.0) << 24) | (UInt32(bytes.1) << 16) | (UInt32(bytes.2) << 8) | UInt32(bytes.3)
    }
}

private extension FourCharCode {
    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            (UInt32(buffer[0]) << 24) | (UInt32(buffer[1]) << 16) | (UInt32(buffer[2]) << 8) | UInt32(buffer[3])
        }
    }

    init(fromString str: String) {
        precondition(str.count == 4)
        self = str.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func toString() -> String {
        String(UnicodeScalar((self >> 24) & 0xff)!) +
        String(UnicodeScalar((self >> 16) & 0xff)!) +
        String(UnicodeScalar((self >> 8) & 0xff)!) +
        String(UnicodeScalar(self & 0xff)!)
    }
}

private extension Double {
    init(fromFPE2 bytes: (UInt8, UInt8)) {
        self = Double((Int(bytes.0) << 6) + (Int(bytes.1) >> 2))
    }
}

private final class FanControllerSMC {
    private var connection: io_connect_t = 0
    private var keyInfoCache: [FourCharCode: HelperSMCDataType] = [:]

    deinit {
        if connection != 0 {
            IOServiceClose(connection)
        }
    }

    func applyTargets(_ targets: [Int: Int]) throws {
        try ensureOpen()
        for (index, requestedRPM) in targets.sorted(by: { $0.key < $1.key }) {
            let boundedRPM = try clampedRPM(requestedRPM, fanIndex: index)
            try enableManualModeIfAvailable(fanIndex: index)
            Thread.sleep(forTimeInterval: 0.1)
            let currentRPM = actualRPM(for: index)
            if currentRPM == 0 && boundedRPM > 0 {
                try forceSpinUpStoppedFan(to: boundedRPM, fanIndex: index)
            } else {
                try writeTargetSpeed(boundedRPM, fanIndex: index)
            }
        }
    }

    func restoreAutomaticMode(for fanIndices: [Int]) throws {
        try ensureOpen()
        for index in fanIndices.sorted() {
            try disableManualModeIfAvailable(fanIndex: index)
        }
    }

    private func ensureOpen() throws {
        if connection != 0 { return }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw HelperError.driverNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else {
            connection = 0
            throw HelperError.failedToOpen(result)
        }
    }

    private func callDriver(_ inputStruct: inout HelperSMCParamStruct) throws -> HelperSMCParamStruct {
        var outputStruct = HelperSMCParamStruct()
        let inputSize = MemoryLayout<HelperSMCParamStruct>.stride
        var outputSize = MemoryLayout<HelperSMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(HelperSMCParamStruct.Selector.handleYPCEvent.rawValue),
            &inputStruct,
            inputSize,
            &outputStruct,
            &outputSize
        )

        switch (result, outputStruct.result) {
        case (kIOReturnSuccess, HelperSMCParamStruct.Result.success.rawValue):
            return outputStruct
        case (kIOReturnSuccess, HelperSMCParamStruct.Result.keyNotFound.rawValue):
            throw HelperError.keyNotFound(inputStruct.key.toString())
        default:
            throw HelperError.invalidResponse(result, outputStruct.result)
        }
    }

    private func keyInfo(for code: FourCharCode) throws -> HelperSMCDataType {
        if let cached = keyInfoCache[code] {
            return cached
        }

        var input = HelperSMCParamStruct()
        input.key = code
        input.data8 = HelperSMCParamStruct.Selector.getKeyInfo.rawValue
        let output = try callDriver(&input)
        let info = HelperSMCDataType(code: output.keyInfo.dataType, size: UInt32(output.keyInfo.dataSize))
        keyInfoCache[code] = info
        return info
    }

    private func maybeKeyInfo(for code: FourCharCode) -> HelperSMCDataType? {
        try? keyInfo(for: code)
    }

    private func readData(for key: HelperSMCKey) throws -> HelperSMCBytes {
        var input = HelperSMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.info.size
        input.data8 = HelperSMCParamStruct.Selector.readKey.rawValue
        let output = try callDriver(&input)
        return output.bytes
    }

    private func writeData(_ bytes: [UInt8], for key: HelperSMCKey) throws {
        var input = HelperSMCParamStruct()
        input.key = key.code
        input.data8 = HelperSMCParamStruct.Selector.writeKey.rawValue
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

    private func readNumericValue(for code: FourCharCode) throws -> Double {
        let info = try keyInfo(for: code)
        let data = try readData(for: HelperSMCKey(code: code, info: info))

        switch info {
        case .fpe2:
            return Double(fromFPE2: (data.0, data.1))
        case .flt:
            var raw = UInt32(fromBytes: (data.0, data.1, data.2, data.3))
            raw = UInt32(bigEndian: raw)
            return Double(Float(bitPattern: raw))
        case .ui8:
            return Double(data.0)
        case .ui16:
            return Double((UInt16(data.0) << 8) | UInt16(data.1))
        case .ui32:
            return Double(UInt32(fromBytes: (data.0, data.1, data.2, data.3)))
        default:
            throw HelperError.unsupportedDataType(info.code.toString())
        }
    }

    private func writeNumericValue(_ value: Int, to code: FourCharCode) throws {
        let info = try keyInfo(for: code)
        let key = HelperSMCKey(code: code, info: info)

        switch info {
        case .fpe2:
            let scaled = max(0, Int(round(Double(value) * 4.0)))
            try writeData([UInt8((scaled >> 6) & 0xff), UInt8((scaled << 2) & 0xff)], for: key)
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
            throw HelperError.unsupportedDataType(info.code.toString())
        }
    }

    private func writeTargetSpeed(_ rpm: Int, fanIndex: Int) throws {
        let targetCode = FourCharCode(fromString: "F\(fanIndex)Tg")
        if let info = maybeKeyInfo(for: targetCode) {
            let key = HelperSMCKey(code: targetCode, info: info)
            switch info {
            case .flt:
                var value = Float(rpm)
                let bytes = withUnsafeBytes(of: &value) { Array($0) }
                try writeData(bytes, for: key)
            case .fpe2, .ui8, .ui16, .ui32:
                try writeNumericValue(rpm, to: targetCode)
            default:
                throw HelperError.unsupportedDataType(info.code.toString())
            }
            return
        }

        try writeNumericValue(rpm, to: FourCharCode(fromString: "F\(fanIndex)Mn"))
    }

    private func forceSpinUpStoppedFan(to rpm: Int, fanIndex: Int) throws {
        let maxRPM = Int((try? readNumericValue(for: FourCharCode(fromString: "F\(fanIndex)Mx"))) ?? Double(rpm))
        let spinUpRPM = max(rpm, maxRPM)

        try writeTargetSpeed(spinUpRPM, fanIndex: fanIndex)
        try? writeNumericValue(spinUpRPM, to: FourCharCode(fromString: "F\(fanIndex)Mn"))

        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.12)
            if actualRPM(for: fanIndex) > 0 {
                try writeTargetSpeed(rpm, fanIndex: fanIndex)
                return
            }
            try writeTargetSpeed(spinUpRPM, fanIndex: fanIndex)
            try enableManualModeIfAvailable(fanIndex: fanIndex)
        }

        throw HelperError.fanDidNotSpinUp(fanIndex)
    }

    private func actualRPM(for fanIndex: Int) -> Int {
        Int((try? readNumericValue(for: FourCharCode(fromString: "F\(fanIndex)Ac"))) ?? 0)
    }

    private func enableManualModeIfAvailable(fanIndex: Int) throws {
        let modeCode = FourCharCode(fromString: "F\(fanIndex)Md")
        if maybeKeyInfo(for: modeCode) != nil {
            try writeNumericValue(1, to: modeCode)
        }

        let maskCode = FourCharCode(fromStaticString: "FS! ")
        if let info = maybeKeyInfo(for: maskCode) {
            let currentMask = try readData(for: HelperSMCKey(code: maskCode, info: info))
            let currentValue = (UInt16(currentMask.0) << 8) | UInt16(currentMask.1)
            let updatedValue = currentValue | UInt16(1 << fanIndex)
            try writeData([UInt8((updatedValue >> 8) & 0xff), UInt8(updatedValue & 0xff)], for: HelperSMCKey(code: maskCode, info: info))
        }
    }

    private func disableManualModeIfAvailable(fanIndex: Int) throws {
        let modeCode = FourCharCode(fromString: "F\(fanIndex)Md")
        if maybeKeyInfo(for: modeCode) != nil {
            try writeNumericValue(0, to: modeCode)
        }

        let maskCode = FourCharCode(fromStaticString: "FS! ")
        if let info = maybeKeyInfo(for: maskCode) {
            let currentMask = try readData(for: HelperSMCKey(code: maskCode, info: info))
            let currentValue = (UInt16(currentMask.0) << 8) | UInt16(currentMask.1)
            let updatedValue = currentValue & ~UInt16(1 << fanIndex)
            try writeData([UInt8((updatedValue >> 8) & 0xff), UInt8(updatedValue & 0xff)], for: HelperSMCKey(code: maskCode, info: info))
        }
    }

    private func clampedRPM(_ requested: Int, fanIndex: Int) throws -> Int {
        let minimum = Int((try? readNumericValue(for: FourCharCode(fromString: "F\(fanIndex)Mn"))) ?? 1200.0)
        let maximum = Int((try? readNumericValue(for: FourCharCode(fromString: "F\(fanIndex)Mx"))) ?? Double(max(requested, minimum)))
        let safe = Int((try? readNumericValue(for: FourCharCode(fromString: "F\(fanIndex)Sf"))) ?? Double(minimum))
        let lowerBound = max(minimum, 0)
        let upperBound = max(maximum, safe, lowerBound)
        return max(lowerBound, min(requested, upperBound))
    }
}

private struct FanControlResult: Codable {
    let success: Bool
    let message: String
}

private enum FanControlCommand {
    case manual([Int: Int])
    case auto([Int])
}

private func parseTargets(from arguments: [String]) throws -> [Int: Int] {
    guard !arguments.isEmpty else { throw HelperError.invalidArguments }
    var targets: [Int: Int] = [:]
    for argument in arguments {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let index = Int(parts[0]), let rpm = Int(parts[1]) else {
            throw HelperError.invalidArguments
        }
        targets[index] = rpm
    }
    return targets
}

private func parseCommand(from arguments: [String]) throws -> FanControlCommand {
    guard !arguments.isEmpty else { throw HelperError.invalidArguments }
    if arguments.first == "--auto" {
        let fanIndices = Array(arguments.dropFirst()).compactMap(Int.init)
        guard !fanIndices.isEmpty else { throw HelperError.invalidArguments }
        return .auto(fanIndices)
    }
    return .manual(try parseTargets(from: arguments))
}

private func writeResult(_ result: FanControlResult, to url: URL) throws {
    let data = try JSONEncoder().encode(result)
    try data.write(to: url, options: .atomic)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let resultPath = arguments.first else {
    fputs("Missing result file path.\n", stderr)
    exit(2)
}

let resultURL = URL(fileURLWithPath: resultPath)
do {
    let command = try parseCommand(from: Array(arguments.dropFirst()))
    let controller = FanControllerSMC()
    switch command {
    case let .manual(targets):
        try controller.applyTargets(targets)
        try writeResult(FanControlResult(success: true, message: "Applied fan speeds."), to: resultURL)
    case let .auto(indices):
        try controller.restoreAutomaticMode(for: indices)
        try writeResult(FanControlResult(success: true, message: "Restored automatic fan control."), to: resultURL)
    }
    exit(0)
} catch {
    try? writeResult(FanControlResult(success: false, message: error.localizedDescription), to: resultURL)
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
