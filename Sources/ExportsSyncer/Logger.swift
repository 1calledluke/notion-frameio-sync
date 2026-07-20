import Foundation

struct LogEntry {
    let date: Date
    let message: String
}

/// Thread-safe logger: writes to a rolling file and keeps the last 200 entries
/// in memory for display in the menu's activity list.
final class Logger: @unchecked Sendable {
    static let shared = Logger()

    private let queue = DispatchQueue(label: "com.ivp.exports-syncer.log")
    private(set) var recent: [LogEntry] = []
    private var fileHandle: FileHandle?
    private let maxRecent = 200

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ExportsSyncer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("activity.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    func write(_ message: String) {
        let entry = LogEntry(date: Date(), message: message)
        queue.async {
            let line = "[\(Self.ts(entry.date))] \(message)\n"
            self.fileHandle?.write(line.data(using: .utf8) ?? Data())
            DispatchQueue.main.async {
                self.recent.append(entry)
                if self.recent.count > self.maxRecent {
                    self.recent.removeFirst(self.recent.count - self.maxRecent)
                }
                NotificationCenter.default.post(name: .logUpdated, object: nil)
            }
        }
    }

    private static func ts(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

extension Notification.Name {
    static let logUpdated = Notification.Name("com.ivp.exports-syncer.logUpdated")
}

func Log(_ message: String) { Logger.shared.write(message) }
