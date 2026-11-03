import AppKit
import OSLog

// Local, bounded metadata only. Never collect window names, titles, or contents.
@MainActor
final class WindowEvidenceRecorder {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowSnap/window-evidence.jsonl")
    }

    private let logger = Logger(subsystem: "com.local.windowsnap", category: "Evidence")
    private var sequence = 0
    private var warned = false

    func record(stage: String, interaction: Int, currentInteraction: Int,
                target: PhysicalWindowKey?, watched: [PhysicalWindowKey],
                baseline: [PhysicalWindowKey: PhysicalWindowSnapshot],
                snapshots: [PhysicalWindowSnapshot]?, ax: [[String: Any]] = [], detail: String = "") {
        sequence += 1
        let current = snapshots.map { Dictionary($0.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }) }
        let rows: [[String: Any]] = watched.map { key in
            var row: [String: Any] = ["pid": key.pid, "window": key.number,
                                      "isTarget": key == target]
            if let original = baseline[key] { row["baselineFrame"] = rect(original.frame) }
            if let current {
                row["exists"] = current[key] != nil
                if let window = current[key] {
                    row["frame"] = rect(window.frame)
                    row["onscreen"] = window.isOnscreen
                    row["zIndex"] = window.zIndex
                    if let original = baseline[key] {
                        row["frameChanged"] = !PhysicalWindowEvidence.frameMatches(original.frame, window.frame)
                    }
                    if let target, target != key, let active = current[target] {
                        let overlap = active.frame.intersection(window.frame)
                        row["overlapArea"] = overlap.isNull ? 0 : overlap.width * overlap.height
                        row["targetInFront"] = active.zIndex < window.zIndex
                    }
                }
            }
            return row
        }
        let record: [String: Any] = [
            "sequence": sequence, "time": Date().timeIntervalSince1970,
            "uptime": ProcessInfo.processInfo.systemUptime,
            "version": AppBuild.label, "process": ProcessInfo.processInfo.processIdentifier,
            "interaction": interaction, "currentInteraction": currentInteraction,
            "stage": stage, "detail": detail, "cgAvailable": snapshots != nil,
            "windows": rows, "ax": ax
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            let url = Self.logURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size > 2 * 1024 * 1024 {
                let previous = url.deletingLastPathComponent().appendingPathComponent("window-evidence.previous.jsonl")
                if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
                try FileManager.default.moveItem(at: url, to: previous)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            logger.notice("Evidence stage=\(stage, privacy: .public) interaction=\(interaction) sequence=\(self.sequence)")
        } catch {
            if !warned {
                warned = true
                logger.error("Evidence file unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func rect(_ frame: CGRect) -> [Double] {
        [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
    }
}
