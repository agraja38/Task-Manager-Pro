import Foundation
import Security

@_silgen_name("PulseAuthorizationExecuteWithPrivileges")
private func PulseThermalAuthorizationExecuteWithPrivileges(
    _ authorization: AuthorizationRef,
    _ pathToTool: UnsafePointer<CChar>,
    _ arguments: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> OSStatus

final class ThermalTelemetryService {
    private let defaultFlags = AuthorizationFlags(rawValue: 0)
    private let interactionAllowedFlags = AuthorizationFlags(rawValue: (1 << 0) | (1 << 1) | (1 << 4))
    private let destroyRightsFlags = AuthorizationFlags(rawValue: 1 << 3)
    private var cachedAuthorizationRef: AuthorizationRef?

    deinit {
        if let cachedAuthorizationRef {
            AuthorizationFree(cachedAuthorizationRef, destroyRightsFlags)
        }
    }

    func sample(currentThermalLevel: String) -> ThermalDetailsSnapshot {
        do {
            let output = try privilegedPowermetricsOutput()
            let parsed = parsePowermetrics(output, fallbackThermalLevel: currentThermalLevel)
            return parsed
        } catch let error as ThermalTelemetryError {
            return ThermalDetailsSnapshot(
                cpuTemperatureC: nil,
                gpuTemperatureC: nil,
                fanSpeedsRPM: [],
                hottestSensors: [],
                thermalLevel: currentThermalLevel,
                note: error.localizedDescription,
                requiresPrivilege: true,
                capturedAt: Date()
            )
        } catch {
            return ThermalDetailsSnapshot(
                cpuTemperatureC: nil,
                gpuTemperatureC: nil,
                fanSpeedsRPM: [],
                hottestSensors: [],
                thermalLevel: currentThermalLevel,
                note: "Detailed thermal telemetry is unavailable right now.",
                requiresPrivilege: true,
                capturedAt: Date()
            )
        }
    }

    private func privilegedPowermetricsOutput() throws -> String {
        let authorizationRef = try authorizeExecution()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("taskmanagerpro-thermal-\(UUID().uuidString).txt")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("taskmanagerpro-thermal-\(UUID().uuidString).err")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let command = "/usr/bin/powermetrics -n 1 --samplers smc >/bin/cat > /dev/null"
        _ = command
        let shellCommand = "/usr/bin/powermetrics -n 1 --samplers smc > '\(outputURL.path)' 2> '\(errorURL.path)'"
        let status = try executePrivilegedShellCommand(shellCommand, using: authorizationRef)
        guard status == errAuthorizationSuccess else {
            if status == errAuthorizationCanceled {
                throw ThermalTelemetryError.authorizationFailed("Thermal telemetry access was canceled.")
            }
            throw ThermalTelemetryError.authorizationFailed("macOS could not open privileged thermal telemetry. (Status \(status))")
        }

        let errorOutput = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        if !errorOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ThermalTelemetryError.commandFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThermalTelemetryError.commandFailed("powermetrics did not return any thermal data.")
        }
        return output
    }

    private func authorizeExecution() throws -> AuthorizationRef {
        let authorizationRef: AuthorizationRef
        if let existing = cachedAuthorizationRef {
            authorizationRef = existing
        } else {
            var createdAuthorization: AuthorizationRef?
            let createStatus = AuthorizationCreate(nil, nil, defaultFlags, &createdAuthorization)
            guard createStatus == errAuthorizationSuccess, let createdAuthorization else {
                throw ThermalTelemetryError.authorizationFailed("Thermal telemetry authorization failed. (Status \(createStatus))")
            }
            cachedAuthorizationRef = createdAuthorization
            authorizationRef = createdAuthorization
        }

        let status = kAuthorizationRightExecute.withCString { rightName in
            var executeRight = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &executeRight) { executeRightPointer in
                var rights = AuthorizationRights(count: 1, items: executeRightPointer)
                return AuthorizationCopyRights(authorizationRef, &rights, nil, interactionAllowedFlags, nil)
            }
        }

        guard status == errAuthorizationSuccess else {
            throw ThermalTelemetryError.authorizationFailed("Thermal telemetry authorization failed. (Status \(status))")
        }

        return authorizationRef
    }

    private func executePrivilegedShellCommand(_ shellCommand: String, using authorizationRef: AuthorizationRef) throws -> OSStatus {
        let toolCString = strdup("/bin/sh")
        defer { free(toolCString) }
        guard let toolCString else {
            throw ThermalTelemetryError.commandFailed("macOS could not prepare the shell path.")
        }

        let flagCString = strdup("-c")
        let commandCString = strdup(shellCommand)
        defer {
            free(flagCString)
            free(commandCString)
        }
        guard let flagCString, let commandCString else {
            throw ThermalTelemetryError.commandFailed("macOS could not prepare the thermal command.")
        }

        var arguments: [UnsafeMutablePointer<CChar>?] = [flagCString, commandCString, nil]
        return arguments.withUnsafeMutableBufferPointer { buffer in
            PulseThermalAuthorizationExecuteWithPrivileges(
                authorizationRef,
                toolCString,
                buffer.baseAddress
            )
        }
    }

    private func parsePowermetrics(_ output: String, fallbackThermalLevel: String) -> ThermalDetailsSnapshot {
        let lines = output.split(separator: "\n").map(String.init)
        var sensors: [ThermalSensorSnapshot] = []
        var fans: [FanSpeedSnapshot] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let sensor = parseSensor(from: trimmed) {
                sensors.append(sensor)
            }

            if let fan = parseFan(from: trimmed) {
                fans.append(fan)
            }
        }

        let cpuTemperature = preferredTemperature(from: sensors, matching: ["cpu", "die", "ecpu", "pcpu"])
        let gpuTemperature = preferredTemperature(from: sensors, matching: ["gpu"])
        let hottestSensors = sensors.sorted { $0.valueC > $1.valueC }.prefix(8).map { $0 }

        let note: String
        if sensors.isEmpty && fans.isEmpty {
            note = "macOS granted thermal access, but no detailed temperatures were returned by powermetrics on this hardware."
        } else {
            note = "Detailed thermals are sampled with privileged macOS telemetry for advanced mode."
        }

        return ThermalDetailsSnapshot(
            cpuTemperatureC: cpuTemperature,
            gpuTemperatureC: gpuTemperature,
            fanSpeedsRPM: fans.sorted { $0.name < $1.name },
            hottestSensors: Array(hottestSensors),
            thermalLevel: fallbackThermalLevel,
            note: note,
            requiresPrivilege: false,
            capturedAt: Date()
        )
    }

    private func parseSensor(from line: String) -> ThermalSensorSnapshot? {
        guard line.localizedCaseInsensitiveContains("temp") || line.localizedCaseInsensitiveContains("temperature") else {
            return nil
        }
        guard let range = line.range(of: #"(-?[0-9]+(?:\.[0-9]+)?)\s*C"#, options: .regularExpression) else {
            return nil
        }
        let valueText = String(line[range]).replacingOccurrences(of: "C", with: "").trimmingCharacters(in: .whitespaces)
        guard let value = Double(valueText) else { return nil }

        let name = line.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ") ?? "Sensor"
        return ThermalSensorSnapshot(name: name, valueC: value)
    }

    private func parseFan(from line: String) -> FanSpeedSnapshot? {
        guard line.localizedCaseInsensitiveContains("rpm") else {
            return nil
        }
        guard let range = line.range(of: #"([0-9]+)\s*rpm"#, options: .regularExpression) else {
            return nil
        }
        let valueText = String(line[range]).replacingOccurrences(of: "rpm", with: "").trimmingCharacters(in: .whitespaces)
        guard let rpm = Int(valueText) else { return nil }
        let name = line.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: " ") ?? "Fan"
        return FanSpeedSnapshot(name: name, rpm: rpm)
    }

    private func preferredTemperature(from sensors: [ThermalSensorSnapshot], matching keywords: [String]) -> Double? {
        sensors.first {
            let lower = $0.name.lowercased()
            return keywords.contains { lower.contains($0) }
        }?.valueC
    }
}

private enum ThermalTelemetryError: LocalizedError {
    case authorizationFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case let .authorizationFailed(message): return message
        case let .commandFailed(message): return message
        }
    }
}
