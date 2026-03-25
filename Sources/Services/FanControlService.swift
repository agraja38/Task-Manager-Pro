import Foundation

final class FanControlService {
    private let installedHelperURL = URL(fileURLWithPath: "/Library/Application Support/TaskManagerPro/TaskManagerProFanHelper")

    func applyFanTargets(_ speedsByFanIndex: [Int: Int]) -> (success: Bool, message: String) {
        runHelper(arguments: speedsByFanIndex.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" })
    }

    func restoreAutomaticControl(for fanIndices: [Int]) -> (success: Bool, message: String) {
        runHelper(arguments: ["--auto"] + fanIndices.sorted().map(String.init))
    }

    private func runHelper(arguments helperArguments: [String]) -> (success: Bool, message: String) {
        do {
            try ensureInstalledPrivilegedHelper()
            let resultURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("taskmanagerpro-fancontrol-\(UUID().uuidString)")
                .appendingPathExtension("json")
            defer { try? FileManager.default.removeItem(at: resultURL) }

            try launchInstalledHelper(arguments: helperArguments, resultURL: resultURL)
            return try waitForResult(at: resultURL)
        } catch let error as FanControlError {
            return (false, error.localizedDescription)
        } catch {
            return (false, "Fan control failed: \(error.localizedDescription)")
        }
    }

    private func ensureInstalledPrivilegedHelper() throws {
        guard let bundledHelperURL = Bundle.main.url(forResource: "TaskManagerProFanHelper", withExtension: nil) else {
            throw FanControlError.helperMissing
        }

        if FileManager.default.isExecutableFile(atPath: installedHelperURL.path) {
            return
        }

        let installDirectory = installedHelperURL.deletingLastPathComponent().path
        let escapedSource = shellSingleQuoted(bundledHelperURL.path)
        let escapedDestination = shellSingleQuoted(installedHelperURL.path)
        let escapedDirectory = shellSingleQuoted(installDirectory)
        let command = "mkdir -p \(escapedDirectory) && /usr/bin/install -m 4555 -o root -g wheel \(escapedSource) \(escapedDestination)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "do shell script \(applescriptQuoted(command)) with administrator privileges"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.localizedCaseInsensitiveContains("User canceled") {
                throw FanControlError.installCanceled
            }
            throw FanControlError.installFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard FileManager.default.isExecutableFile(atPath: installedHelperURL.path) else {
            throw FanControlError.installFailed("Task Manager Pro could not verify the installed fan control helper.")
        }
    }

    private func launchInstalledHelper(arguments helperArguments: [String], resultURL: URL) throws {
        let process = Process()
        process.executableURL = installedHelperURL
        process.arguments = [resultURL.path] + helperArguments
        try process.run()
    }

    private func waitForResult(at url: URL) throws -> (success: Bool, message: String) {
        let timeout = Date().addingTimeInterval(4.0)
        while Date() < timeout {
            if let data = try? Data(contentsOf: url),
               let result = try? JSONDecoder().decode(FanControlHelperResult.self, from: data) {
                return (result.success, result.message)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw FanControlError.executionFailed("Task Manager Pro did not get a response from the fan control helper.")
    }
}

private struct FanControlHelperResult: Decodable {
    let success: Bool
    let message: String
}

private enum FanControlError: LocalizedError {
    case helperMissing
    case installCanceled
    case installFailed(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "Task Manager Pro could not find its bundled fan control helper."
        case .installCanceled:
            return "Fan control setup was canceled."
        case let .installFailed(message):
            return message.isEmpty ? "Task Manager Pro could not install its privileged fan control helper." : "Task Manager Pro could not install its privileged fan control helper. \(message)"
        case let .executionFailed(message):
            return message
        }
    }
}

private func shellSingleQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

private func applescriptQuoted(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
