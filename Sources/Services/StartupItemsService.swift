import Foundation

final class StartupItemsService {
    func fetchStartupItems() -> [StartupItem] {
        let script = """
        tell application "System Events"
            set loginItems to every login item
            set itemLines to {}
            repeat with loginItem in loginItems
                try
                    set end of itemLines to (name of loginItem as text) & "|" & (path of loginItem as text) & "|" & (hidden of loginItem as text)
                on error
                    set end of itemLines to (name of loginItem as text) & "|Unavailable|false"
                end try
            end repeat
            return itemLines as string
        end tell
        """

        let output = Shell.run("/usr/bin/osascript", arguments: ["-e", script])
        let rows = output
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if rows.isEmpty {
            return [
                StartupItem(
                    name: "Login items unavailable",
                    path: "Grant Automation access to System Events or use Advanced mode to inspect background tasks another way.",
                    isHidden: false,
                    impact: "Unknown",
                    source: "Fallback"
                )
            ]
        }

        return rows.map { row in
            let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let name = fields.indices.contains(0) ? fields[0] : "Unknown"
            let path = fields.indices.contains(1) ? fields[1] : "Unavailable"
            let hidden = fields.indices.contains(2) ? fields[2].lowercased().contains("true") : false
            return StartupItem(name: name, path: path, isHidden: hidden, impact: impact(for: path), source: "Login Item")
        }
    }

    private func impact(for path: String) -> String {
        guard FileManager.default.fileExists(atPath: path) else { return "Unknown" }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.doubleValue ?? 0
        switch size {
        case ..<20_000_000: return "Low"
        case ..<150_000_000: return "Medium"
        default: return "High"
        }
    }
}
