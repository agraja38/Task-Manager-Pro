import AppKit
import Foundation

@MainActor
final class UpdaterService: ObservableObject {
    enum UpdatePhase: String {
        case idle
        case checking
        case downloading
        case installing
        case finished
        case failed
    }

    @Published var phase: UpdatePhase = .idle
    @Published var progress: Double = 0
    @Published var statusText = "Up to date."
    @Published var latestVersion = "1.0.06"
    @Published var releaseNotes = ""
    @Published var currentVersion = "1.0.06"

    private let feedURL = URL(string: "https://raw.githubusercontent.com/agraja38/Task-Manager-Pro/main/docs/update.json")!

    func checkForUpdates() async {
        phase = .checking
        progress = 0.1
        statusText = "Checking for updates..."
        releaseNotes = ""

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
            try await downloadAndInstall(from: assetURL)
        } catch {
            phase = .failed
            progress = 0
            statusText = "Update check failed: \(error.localizedDescription)"
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

        phase = .installing
        progress = 0.9
        statusText = "Opening installer..."
        NSWorkspace.shared.open(localURL)
        progress = 1
        phase = .finished
        statusText = "Installer opened. Follow the macOS prompts to replace the app."
    }

    private func currentDownloadURL(from feed: UpdateFeed) -> String {
        #if arch(arm64)
        return feed.arm64AssetURL
        #else
        return feed.x86_64AssetURL
        #endif
    }
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
