import AppKit
import Foundation

@MainActor
final class UpdaterService: ObservableObject {
    enum UpdatePhase: String {
        case idle
        case checking
        case ready
        case downloading
        case installing
        case finished
        case failed
    }

    @Published var phase: UpdatePhase = .idle
    @Published var progress: Double = 0
    @Published var statusText = "Up to date."
    @Published var latestVersion = "1.0.15"
    @Published var releaseNotes = ""
    @Published var currentVersion = "1.0.15"
    @Published var pendingAssetURL: String?
    @Published var pendingDownloadSizeBytes: Int64?

    private let feedURL = URL(string: "https://raw.githubusercontent.com/agraja38/Task-Manager-Pro/main/docs/update.json")!

    func checkForUpdates() async {
        phase = .checking
        progress = 0.1
        statusText = "Checking for updates..."
        releaseNotes = ""
        pendingAssetURL = nil
        pendingDownloadSizeBytes = nil

        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            let session = URLSession(configuration: configuration)
            let (data, response) = try await session.data(from: feedURL)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw NSError(domain: "TaskManagerPro", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "The update feed returned HTTP \(http.statusCode)."])
            }
            let feed = try JSONDecoder().decode(UpdateFeed.self, from: data)
            latestVersion = feed.version
            releaseNotes = feed.notes

            guard feed.version.compare(currentVersion, options: .numeric) == .orderedDescending else {
                phase = .finished
                progress = 1
                statusText = "You're already running the latest version."
                return
            }

            let assetURL = currentDownloadURL(from: feed)
            pendingAssetURL = assetURL
            pendingDownloadSizeBytes = try await fetchDownloadSize(from: assetURL)
            phase = .ready
            progress = 0
            statusText = "Version \(feed.version) is ready to install."
        } catch {
            phase = .failed
            progress = 0
            statusText = "Update check failed: \(error.localizedDescription)"
        }
    }

    func installPreparedUpdate() async {
        guard let assetURL = pendingAssetURL else { return }

        do {
            try await downloadAndInstall(from: assetURL)
        } catch {
            phase = .failed
            progress = 0
            statusText = "Install failed: \(error.localizedDescription)"
        }
    }

    private func downloadAndInstall(from assetURLString: String) async throws {
        guard let url = URL(string: assetURLString) else {
            throw NSError(domain: "TaskManagerPro", code: 10, userInfo: [NSLocalizedDescriptionKey: "The update feed returned an invalid download URL."])
        }

        phase = .downloading
        progress = 0.2
        statusText = "Downloading update..."

        let delegate = DownloadProgressDelegate { [weak self] progress in
            Task { @MainActor in
                self?.progress = 0.2 + (progress * 0.6)
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (localURL, _) = try await session.download(from: url)
        let namedURL = try prepareDownloadedDiskImage(from: localURL, sourceURL: url)
        let mountedImage = try mountDiskImage(at: namedURL)

        phase = .installing
        progress = 0.9
        statusText = "Installing update..."
        try launchBackgroundInstaller(from: mountedImage)
        progress = 1
        phase = .finished
        statusText = "Installing update and reopening Task Manager Pro..."
        NSApplication.shared.terminate(nil)
    }

    private func currentDownloadURL(from feed: UpdateFeed) -> String {
        #if arch(arm64)
        return feed.arm64AssetURL
        #else
        return feed.x86_64AssetURL
        #endif
    }

    private func fetchDownloadSize(from assetURLString: String) async throws -> Int64? {
        guard let url = URL(string: assetURLString) else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (data, response) = try await URLSession.shared.data(for: request)
        _ = data

        if let http = response as? HTTPURLResponse, !(200...399).contains(http.statusCode) {
            throw NSError(domain: "TaskManagerPro", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "The update download responded with HTTP \(http.statusCode)."])
        }

        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }

        if
            let http = response as? HTTPURLResponse,
            let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
            let bytes = Int64(contentLength)
        {
            return bytes
        }

        return nil
    }

    private func prepareDownloadedDiskImage(from temporaryURL: URL, sourceURL: URL) throws -> URL {
        let downloadsFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let fileName = sourceURL.lastPathComponent.isEmpty ? "TaskManagerPro-Update.dmg" : sourceURL.lastPathComponent
        let destinationURL = downloadsFolder.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }

    private func mountDiskImage(at diskImageURL: URL) throws -> MountedDiskImage {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["attach", "-nobrowse", "-plist", diskImageURL.path]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "TaskManagerPro", code: 11, userInfo: [NSLocalizedDescriptionKey: "macOS could not mount the downloaded update disk image."])
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard
            let dictionary = plist as? [String: Any],
            let systemEntities = dictionary["system-entities"] as? [[String: Any]],
            let mountPath = systemEntities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw NSError(domain: "TaskManagerPro", code: 12, userInfo: [NSLocalizedDescriptionKey: "The update disk image mounted, but Task Manager Pro could not locate its volume."])
        }

        return MountedDiskImage(diskImageURL: diskImageURL, mountPoint: URL(fileURLWithPath: mountPath))
    }

    private func launchBackgroundInstaller(from mountedImage: MountedDiskImage) throws {
        let sourceAppURL = mountedImage.mountPoint.appendingPathComponent("Task Manager Pro.app")
        guard FileManager.default.fileExists(atPath: sourceAppURL.path) else {
            throw NSError(domain: "TaskManagerPro", code: 13, userInfo: [NSLocalizedDescriptionKey: "The downloaded update does not contain Task Manager Pro.app."])
        }

        let currentAppURL = Bundle.main.bundleURL
        let targetAppURL = currentAppURL.pathExtension == "app"
            ? currentAppURL
            : URL(fileURLWithPath: "/Applications/Task Manager Pro.app")

        let scriptURL = try writeInstallerScript()
        let installer = Process()
        installer.executableURL = URL(fileURLWithPath: "/bin/zsh")
        installer.arguments = [
            scriptURL.path,
            sourceAppURL.path,
            targetAppURL.path,
            mountedImage.mountPoint.path,
            "\(ProcessInfo.processInfo.processIdentifier)"
        ]

        let nullHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/null"))
        installer.standardOutput = nullHandle
        installer.standardError = nullHandle
        installer.standardInput = nullHandle
        try installer.run()
    }

    private func writeInstallerScript() throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("taskmanagerpro-self-update-\(UUID().uuidString).sh")
        let script = """
        #!/bin/zsh
        set -euo pipefail

        SOURCE_APP="$1"
        TARGET_APP="$2"
        MOUNT_POINT="$3"
        PID_TO_WAIT="$4"

        while kill -0 "$PID_TO_WAIT" 2>/dev/null; do
          sleep 0.2
        done

        rm -rf "$TARGET_APP"
        /usr/bin/ditto "$SOURCE_APP" "$TARGET_APP"
        /usr/bin/xattr -cr "$TARGET_APP" 2>/dev/null || true
        /usr/bin/open "$TARGET_APP"
        /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    var updateSummaryText: String {
        guard phase == .ready else { return statusText }

        if let bytes = pendingDownloadSizeBytes {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useMB]
            formatter.countStyle = .file
            return "Version \(latestVersion) available • \(formatter.string(fromByteCount: bytes))"
        }

        return "Version \(latestVersion) available"
    }
}

private struct MountedDiskImage {
    let diskImageURL: URL
    let mountPoint: URL
}

final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: (Double) -> Void

    init(progressHandler: @escaping (Double) -> Void) {
        self.progressHandler = progressHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
