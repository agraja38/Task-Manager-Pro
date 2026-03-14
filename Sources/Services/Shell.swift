import Foundation

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, arguments: [String] = [], timeout: TimeInterval = 5) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            var outputData = Data()
            let outputHandle = outputPipe.fileHandleForReading
            outputHandle.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty {
                    outputData.append(chunk)
                }
            }

            try process.run()
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }
            outputHandle.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return ""
            }
            outputData.append(outputHandle.readDataToEndOfFile())
            return String(data: outputData, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
